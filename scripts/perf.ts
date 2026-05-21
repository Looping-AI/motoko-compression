#!/usr/bin/env bun
/**
 * Performance measurement script for motoko-compression.
 *
 * Usage:
 *   bun run scripts/perf.ts component=<name>
 *
 * Available components: huffman, deflate, gzip, lzss
 *
 * The script:
 *   1. Validates that every registered function exists in its source file.
 *   2. Injects `Perf.mark()` calls (and the matching import) into the target
 *      source files, tagging each call with "component:func".
 *   3. Builds a perf-instrumented WASM from example/compress.mo.
 *   4. Runs a generate_data(1) → compress_data() workload on PocketIC.
 *   5. Captures [perf] lines emitted by the canister via Debug.print.
 *   6. Prints a table to stdout and writes a JSON report to scripts/output/.
 *   7. Reverts every source change — even on error or Ctrl+C.
 */

import { $ } from "bun";
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { join, relative, dirname, resolve } from "node:path";

// ── Registry ───────────────────────────────────────────────────────────────────

type PatchTarget = { file: string; funcs: string[] };

/**
 * Maps each component name to the source files and public functions to instrument.
 * Only the first occurrence of each function name in a file is patched (findIndex).
 */
const REGISTRY: Record<string, PatchTarget[]> = {
  huffman: [
    {
      file: "src/Huffman/Common.mo",
      funcs: ["reverseCodeBits", "restoreHuffmanCodes"],
    },
    {
      file: "src/Huffman/Encoder.mo",
      funcs: [
        "fromBitwidths",
        "fromFrequencies",
        "build",
        "encode",
        "lookup",
        "maxSymbol",
        "calcMaxBitwidth",
        "calcBitwidths",
        "package",
      ],
    },
    {
      file: "src/Huffman/Decoder.mo",
      funcs: ["fromBitwidths", "setMapping", "build", "decode"],
    },
  ],
  deflate: [
    { file: "src/Deflate/Encoder.mo", funcs: ["encode", "finish"] },
    { file: "src/Deflate/Decoder.mo", funcs: ["decode"] },
  ],
  gzip: [
    { file: "src/Gzip/Encoder.mo", funcs: ["encode", "finish"] },
    { file: "src/Gzip/Decoder.mo", funcs: ["decode"] },
  ],
  lzss: [
    {
      // Module-level convenience wrappers and top-level decode function.
      file: "src/LZSS/Decoder.mo",
      funcs: ["decodeEntry", "decodeIter", "decode"],
    },
    {
      // Encoder: module-level encode wrapper + every class method and private helper.
      file: "src/LZSS/Encoder/lib.mo",
      funcs: [
        "levelToWindowSize",
        "encodeAsLiterals",
        "encodeByte",
        "encode",
        "flush",
        "clear",
      ],
    },
    {
      // PrefixTable: the 65 536-bucket hash table — primary suspect.
      file: "src/LZSS/Encoder/PrefixTable/lib.mo",
      funcs: ["insert", "clear"],
    },
  ],
  bitbuffer: [
    {
      file: "src/internal/BitBuffer.mo",
      // Instrument every meaningful method (public + key private helpers).
      // Read-side (getBit/getBits/getByte/getBytes/bytes) is included even
      // though the encode workload doesn't exercise it — unused tags simply
      // produce zero marks, costing nothing.
      //
      // `getPos` is the private tuple-returning helper suspected of per-bit
      // heap allocations; `ensureCapacity` exposes reallocation churn.
      funcs: [
        "ensureCapacity",
        "bitSize",
        "byteSize",
        "addBit",
        "addBits",
        "addByte",
        "addBytes",
        "reserve",
        "getBit",
        "getBits",
        "getByte",
        "getBytes",
        "byteAlign",
        "dropBits",
        "clear",
        "bytes",
      ],
    },
  ],
  circularbuffer: [
    {
      file: "src/internal/CircularBuffer.mo",
      funcs: [
        "capacity",
        "size",
        "isFull",
        "push",
        "clear",
        "get",
        "popFront",
        "values",
      ],
    },
  ],
  utils: [
    {
      file: "src/internal/utils.mo",
      funcs: ["natToLeBytes", "leBytesToNat"],
    },
  ],
  bitreader: [
    {
      file: "src/internal/BitReader.mo",
      funcs: [
        "peekBit",
        "readBit",
        "peekBits",
        "readBits",
        "skipBits",
        "peekByte",
        "readByte",
        "readBytes",
        "bitSize",
        "byteSize",
        "byteAlign",
        "getPosition",
        "clearRead",
        "clear",
        "addBytes",
      ],
    },
  ],
  crc32: [
    {
      file: "src/internal/CRC32.mo",
      funcs: ["checksum", "updateByte", "update", "finish", "reset"],
    },
  ],
};

/**
 * Workload size in bytes per component. Low-level primitive components use a
 * tiny payload because their methods fire many times per byte; high-level
 * components stay at 1 MiB to keep the run representative.
 */
const PAYLOAD_BYTES: Record<string, number> = {
  huffman: 100 * 1024,
  deflate: 100 * 1024,
  gzip: 100 * 1024,
  lzss: 10 * 1024,
  bitbuffer: 10 * 1024, // 10 KiB — fine-grained primitive
  circularbuffer: 10 * 1024, // 10 KiB — fine-grained primitive
  utils: 10 * 1024, // 10 KiB — fine-grained primitive
  bitreader: 10 * 1024, // 10 KiB — fine-grained primitive
  crc32: 10 * 1024, // 10 KiB — fine-grained primitive
};

// ── CLI ────────────────────────────────────────────────────────────────────────

const componentArg = process.argv.find((a) => a.startsWith("component="));
if (!componentArg) {
  console.error("Usage: bun run scripts/perf.ts component=<name>");
  console.error(`Available: ${Object.keys(REGISTRY).join(", ")}`);
  process.exit(1);
}

const component = componentArg.split("=")[1];
if (!REGISTRY[component]) {
  console.error(
    `Unknown component "${component}". Available: ${Object.keys(REGISTRY).join(", ")}`,
  );
  process.exit(1);
}

const targets = REGISTRY[component];
const ROOT = process.cwd();
const PERF_MO = resolve(ROOT, "src", "internal", "Perf.mo");
const BUILDS_DIR = resolve(ROOT, "scripts", "builds");
const OUTPUT_DIR = resolve(ROOT, "scripts", "output");

// ── Source patching ────────────────────────────────────────────────────────────

type PatchRecord = { file: string; original: string };
const patchRecords: PatchRecord[] = [];

/**
 * Locate the line index of `func <name>(` (or `func <name><`) and the line
 * index where the function's opening brace `{` appears.
 * Scans up to 6 lines forward from the declaration to handle multi-line signatures.
 * Returns null when the function is not found.
 */
function findFuncBrace(
  lines: string[],
  funcName: string,
): { funcIdx: number; braceIdx: number } | null {
  const funcRe = new RegExp(`\\bfunc\\s+${funcName}\\s*[(<]`);
  const funcIdx = lines.findIndex((l) => funcRe.test(l));
  if (funcIdx === -1) return null;

  for (let i = funcIdx; i < Math.min(funcIdx + 6, lines.length); i++) {
    if (lines[i].includes("{")) return { funcIdx, braceIdx: i };
  }
  return null;
}

/**
 * Returns true if the function declaration (from `funcIdx` through `braceIdx`)
 * has a unit return type — either no return-type annotation, or `: ()`.
 *
 * Only functions that return unit are safe to instrument with an `:end` mark
 * placed immediately before the closing brace; non-unit functions rely on
 * explicit `return` sites found by `findReturnSites`.
 */
function funcReturnsUnit(
  lines: string[],
  funcIdx: number,
  braceIdx: number,
): boolean {
  // Join the declaration lines and strip the trailing `{`.
  const sig = lines
    .slice(funcIdx, braceIdx + 1)
    .join(" ")
    .replace(/\{[^{]*$/, "")
    .trimEnd();

  // If there is no `: <type>` annotation after the closing `)` of the param
  // list, the return type defaults to unit.
  // Pattern: after the signature's last `)`, look for `: <type>`.
  // We use a conservative check: split on ") :" and take the last token.
  const colonIdx = sig.lastIndexOf(") :");
  if (colonIdx === -1) return true; // No annotation → unit.

  const returnType = sig.slice(colonIdx + 3).trim(); // after ") :"
  return returnType === "()" || returnType === "";
}

/**
 * Walk from `openBraceLineIdx` forward, tracking brace depth (string/comment-aware).
 * Returns the line index of the `}` that closes the opening brace on that line.
 */
function findFuncClosingBrace(
  lines: string[],
  openBraceLineIdx: number,
): number {
  let depth = 0;
  let inString = false;
  let inLineComment = false;
  let inBlockComment = false;

  for (let lineIdx = openBraceLineIdx; lineIdx < lines.length; lineIdx++) {
    const line = lines[lineIdx];
    inLineComment = false;

    for (let i = 0; i < line.length; i++) {
      const ch = line[i];
      const next = i + 1 < line.length ? line[i + 1] : "";

      if (inLineComment) break;
      if (inBlockComment) {
        if (ch === "*" && next === "/") {
          inBlockComment = false;
          i++;
        }
        continue;
      }
      if (inString) {
        if (ch === "\\") {
          i++;
          continue;
        }
        if (ch === '"') inString = false;
        continue;
      }
      if (ch === '"') {
        inString = true;
        continue;
      }
      if (ch === "/" && next === "/") {
        inLineComment = true;
        break;
      }
      if (ch === "/" && next === "*") {
        inBlockComment = true;
        i++;
        continue;
      }

      if (ch === "{") {
        depth++;
        continue;
      }
      if (ch === "}") {
        depth--;
        if (depth === 0) return lineIdx;
      }
    }
  }

  throw new Error(
    `findFuncClosingBrace: no matching closing brace from line ${openBraceLineIdx}`,
  );
}

// ── Return-site detection ──────────────────────────────────────────────────────

type ReturnSite =
  | { kind: "standalone"; lineIdx: number }
  | {
      kind: "inline_if";
      lineIdx: number;
      indent: string;
      condition: string;
      returnExpr: string;
    }
  | { kind: "unhandled"; lineIdx: number };

/**
 * Classify a line known to contain an outer-function `return` statement.
 *
 * - `standalone`: `return` is the first non-space token → insert end mark before.
 * - `inline_if`:  `if (cond) return expr;` all on one line → rewrite into block.
 * - `unhandled`:  any other pattern → skip and count.
 */
function classifyReturnSite(lineIdx: number, line: string): ReturnSite {
  const indent = line.match(/^(\s*)/)?.[1] ?? "";

  // `return ...` as the first non-space token.
  if (/^\s*return\b/.test(line)) {
    return { kind: "standalone", lineIdx };
  }

  // `if (condition) return expr;` on a single line.
  const ifMatch = /^(\s*)if\s*\(/.exec(line);
  if (ifMatch) {
    const openParenIdx = ifMatch[0].length - 1; // index of `(` in the original line
    let parenDepth = 0;
    let condEnd = -1;
    for (let i = openParenIdx; i < line.length; i++) {
      if (line[i] === "(") parenDepth++;
      else if (line[i] === ")") {
        parenDepth--;
        if (parenDepth === 0) {
          condEnd = i;
          break;
        }
      }
    }
    if (condEnd !== -1) {
      const condition = line.slice(openParenIdx + 1, condEnd);
      const afterCond = line.slice(condEnd + 1).trim();
      if (/^return\b/.test(afterCond)) {
        const returnExpr = afterCond
          .slice("return".length)
          .trimStart()
          .replace(/;\s*$/, "");
        return { kind: "inline_if", lineIdx, indent, condition, returnExpr };
      }
    }
  }

  return { kind: "unhandled", lineIdx };
}

/**
 * Find every outer-function `return` statement in the function body
 * [openBraceLineIdx, closingBraceLineIdx).
 *
 * Uses a scope stack to skip `return` statements that belong to nested `func`
 * literals (e.g. comparator closures in Huffman/Encoder.mo).
 */
function findReturnSites(
  lines: string[],
  openBraceLineIdx: number,
  closingBraceLineIdx: number,
): ReturnSite[] {
  const sites: ReturnSite[] = [];

  // 'func' = nested function literal body; 'block' = any other {…} scope.
  const scopeStack: Array<"func" | "block"> = [];
  let funcNestDepth = 0;
  let seenFunctionOpenBrace = false; // have we consumed the outer function's own `{`?
  let lookingForFuncBrace = false; // set after `func` keyword; cleared at the next `{`

  let inString = false;
  let inLineComment = false;
  let inBlockComment = false;

  for (
    let lineIdx = openBraceLineIdx;
    lineIdx < closingBraceLineIdx;
    lineIdx++
  ) {
    const line = lines[lineIdx];
    inLineComment = false;

    for (let i = 0; i < line.length; i++) {
      const ch = line[i];
      const next = i + 1 < line.length ? line[i + 1] : "";

      if (inLineComment) break;
      if (inBlockComment) {
        if (ch === "*" && next === "/") {
          inBlockComment = false;
          i++;
        }
        continue;
      }
      if (inString) {
        if (ch === "\\") {
          i++;
          continue;
        }
        if (ch === '"') inString = false;
        continue;
      }
      if (ch === '"') {
        inString = true;
        continue;
      }
      if (ch === "/" && next === "/") {
        inLineComment = true;
        break;
      }
      if (ch === "/" && next === "*") {
        inBlockComment = true;
        i++;
        continue;
      }

      if (ch === "{") {
        if (!seenFunctionOpenBrace) {
          // Outer function's own opening brace — don't push onto scope stack.
          seenFunctionOpenBrace = true;
          lookingForFuncBrace = false; // the `func` keyword was the outer declaration
          continue;
        }
        const kind = lookingForFuncBrace ? "func" : "block";
        scopeStack.push(kind);
        if (kind === "func") funcNestDepth++;
        lookingForFuncBrace = false;
        continue;
      }

      if (ch === "}") {
        if (scopeStack.length > 0) {
          const popped = scopeStack.pop()!;
          if (popped === "func") funcNestDepth--;
        }
        continue;
      }

      // Detect `func` keyword → the next `{` is a nested function body.
      if (ch === "f" && line.slice(i, i + 4) === "func") {
        const charBefore = i === 0 ? "\n" : line[i - 1];
        const charAfter = line[i + 4] ?? "\n";
        if (/\W/.test(charBefore) && /\W/.test(charAfter)) {
          lookingForFuncBrace = true;
          i += 3; // advance past 'unc' (loop `i++` handles 'f' → 'u')
          continue;
        }
      }

      // `func name(args): Type = expr` — expression-body func has no `{`.
      // Clear the flag if we see `=` that is not `==`, `!=`, `<=`, `>=`, or `=>`.
      if (ch === "=" && next !== "=" && next !== ">" && lookingForFuncBrace) {
        const prev = i > 0 ? line[i - 1] : "\n";
        if (prev !== "!" && prev !== "<" && prev !== ">") {
          lookingForFuncBrace = false;
        }
        continue;
      }

      // Detect `return` keyword when NOT inside a nested func scope.
      if (
        funcNestDepth === 0 &&
        seenFunctionOpenBrace &&
        ch === "r" &&
        line.slice(i, i + 6) === "return"
      ) {
        const charBefore = i === 0 ? "\n" : line[i - 1];
        const charAfter = line[i + 6] ?? "\n";
        if (/\W/.test(charBefore) && /\W/.test(charAfter)) {
          sites.push(classifyReturnSite(lineIdx, line));
          break; // at most one return site per line
        }
      }
    }
  }

  return sites;
}

/** Abort early if any registered function cannot be found in its source file. */
function validateTargets(): void {
  for (const { file, funcs } of targets) {
    const lines = readFileSync(resolve(ROOT, file), "utf8").split("\n");
    for (const func of funcs) {
      if (!findFuncBrace(lines, func)) {
        console.error(`  ✗ Function "${func}" not found in ${file}`);
        process.exit(1);
      }
    }
  }
}

// Counts return sites that couldn't be automatically instrumented.
let unhandledReturnCount = 0;

type PatchOp =
  | { kind: "insert"; afterLine: number; text: string }
  | { kind: "replace"; lineIdx: number; newLines: string[] };

/** Patch every registered source file in-memory, recording originals for revert. */
function patchSources(): void {
  for (const { file, funcs } of targets) {
    const absFile = resolve(ROOT, file);
    const original = readFileSync(absFile, "utf8");
    patchRecords.push({ file: absFile, original });

    const lines = original.split("\n");
    const ops: PatchOp[] = [];

    for (const func of funcs) {
      const found = findFuncBrace(lines, func)!;
      const openBraceLineIdx = found.braceIdx;
      const closingBraceLineIdx = findFuncClosingBrace(lines, openBraceLineIdx);

      const declIndent = lines[found.funcIdx].match(/^(\s*)/)?.[1] ?? "";
      const bodyIndent = declIndent + "  ";
      const startMark = `${bodyIndent}Perf.mark("${component}:${func}:start"); // [PERF]`;
      const endMarkBody = `Perf.mark("${component}:${func}:end"); // [PERF]`;

      // :start immediately after the opening brace.
      ops.push({
        kind: "insert",
        afterLine: openBraceLineIdx,
        text: startMark,
      });

      // :end immediately before the closing brace — ONLY for unit-returning
      // functions (non-unit functions return via their last expression; inserting
      // a mark there would change the function's return type to ()).
      if (funcReturnsUnit(lines, found.funcIdx, openBraceLineIdx)) {
        ops.push({
          kind: "insert",
          afterLine: closingBraceLineIdx - 1,
          text: `${bodyIndent}${endMarkBody}`,
        });
      }

      // :end at every early-return exit path.
      const returnSites = findReturnSites(
        lines,
        openBraceLineIdx,
        closingBraceLineIdx,
      );
      for (const site of returnSites) {
        if (site.kind === "standalone") {
          // Insert end mark before the `return` line, matching its own indentation.
          const returnIndent = lines[site.lineIdx].match(/^(\s*)/)?.[1] ?? "";
          ops.push({
            kind: "insert",
            afterLine: site.lineIdx - 1,
            text: `${returnIndent}${endMarkBody}`,
          });
        } else if (site.kind === "inline_if") {
          // Rewrite `if (cond) return expr;` into a block containing the end mark.
          ops.push({
            kind: "replace",
            lineIdx: site.lineIdx,
            newLines: [
              `${site.indent}if (${site.condition}) {`,
              `${site.indent}  ${endMarkBody}`,
              `${site.indent}  return${site.returnExpr.length > 0 ? " " + site.returnExpr : ""};`,
              `${site.indent}};`,
            ],
          });
        } else {
          unhandledReturnCount++;
        }
      }
    }

    // Apply ops in descending line order so each splice doesn't shift later indices.
    ops.sort((a, b) => {
      const aLine = a.kind === "insert" ? a.afterLine : a.lineIdx;
      const bLine = b.kind === "insert" ? b.afterLine : b.lineIdx;
      return bLine - aLine;
    });
    for (const op of ops) {
      if (op.kind === "insert") {
        lines.splice(op.afterLine + 1, 0, op.text);
      } else {
        lines.splice(op.lineIdx, 1, ...op.newLines);
      }
    }

    // Inject the Perf import after the last existing `import` line.
    const relPath = relative(dirname(absFile), PERF_MO).replace(/\.mo$/, "");
    let lastImportIdx = 0;
    for (let i = 0; i < lines.length; i++) {
      if (/^\s*import\s/.test(lines[i])) lastImportIdx = i;
    }
    lines.splice(
      lastImportIdx + 1,
      0,
      `import Perf "${relPath}"; // [PERF_IMPORT]`,
    );

    // Warn if :start and :end mark counts differ for any function.
    const patchedSrc = lines.join("\n");
    for (const func of funcs) {
      const esc = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      const nStart = (
        patchedSrc.match(
          new RegExp(esc(`"${component}:${func}:start"`), "g"),
        ) ?? []
      ).length;
      const nEnd = (
        patchedSrc.match(new RegExp(esc(`"${component}:${func}:end"`), "g")) ??
        []
      ).length;
      if (nStart !== nEnd) {
        console.warn(
          `  ⚠ ${func}: ${nStart} :start mark(s) but ${nEnd} :end mark(s)` +
            ` — some return paths may be uninstrumented`,
        );
      }
    }

    writeFileSync(absFile, lines.join("\n"));
  }
}

/** Remove every line tagged `// [PERF]` or `// [PERF_IMPORT]`, restoring originals. */
function revertSources(): void {
  if (patchRecords.length === 0) return;
  for (const { file, original } of patchRecords) {
    writeFileSync(file, original);
  }
  patchRecords.length = 0;
}

// Revert on Ctrl+C (SIGINT does not trigger "exit" automatically in all runtimes).
process.on("SIGINT", () => {
  revertSources();
  process.exit(130);
});
// Safety net: also revert on normal exits.
process.on("exit", revertSources);

// ── Build environment ──────────────────────────────────────────────────────────
async function getBuildEnvironment() {
  const mocPath = (await $`mops toolchain bin moc`.text()).trim();
  const sources = (await $`mops sources`.text()).trim();
  mkdirSync(BUILDS_DIR, { recursive: true });
  return {
    mocPath,
    sourcesArgs: sources.split(/\s+/).filter((a) => a.length > 0),
  };
}

async function captureLines(
  stream: ReadableStream<Uint8Array>,
  forwardTo: NodeJS.WriteStream,
  onLine: (line: string) => void,
): Promise<void> {
  const decoder = new TextDecoder();
  let pending = "";

  for await (const chunk of stream) {
    forwardTo.write(Buffer.from(chunk));
    pending += decoder.decode(chunk, { stream: true });

    const lines = pending.split(/\r?\n/);
    pending = lines.pop() ?? "";
    for (const line of lines) onLine(line);
  }

  pending += decoder.decode();
  if (pending.length > 0) onLine(pending);
}

// ── Report types and helpers ───────────────────────────────────────────────────

type Mark = { tag: string; instrs: number; mem: number; heap: number };

type TimelineEntry = {
  index: number;
  tag: string;
  instrs: number;
  mem: number;
  heap: number;
};

type IntervalStat = {
  avg: number;
  min: number;
  max: number;
} | null;

type IntervalStats = {
  calls: number;
  inclusive: { instrs: IntervalStat; mem: IntervalStat; heap: IntervalStat };
  exclusive: { instrs: IntervalStat; mem: IntervalStat; heap: IntervalStat };
};

type Report = {
  component: string;
  timestamp: string;
  total_marks: number;
  unpaired_starts: number;
  unhandled_returns: number;
  timeline: TimelineEntry[];
  intervals: Record<string, IntervalStats>;
};

/** Sample up to `points` evenly-spaced `:start` marks by index (always includes first and last). */
function computeTimeline(marks: Mark[], points = 11): TimelineEntry[] {
  const startMarks = marks.filter((m) => m.tag.endsWith(":start"));
  const N = startMarks.length;
  if (N === 0) return [];
  const indices = new Set<number>();
  for (let i = 0; i < points; i++) {
    indices.add(Math.floor((i * (N - 1)) / (points - 1)));
  }
  return [...indices]
    .sort((a, b) => a - b)
    .map((idx) => ({ index: idx, ...startMarks[idx] }));
}

/**
 * Match `:start` and `:end` marks into intervals and compute per-function
 * inclusive and exclusive (self-time) statistics using a call-stack.
 *
 * IC.performanceCounter(1) resets at ICP message boundaries. A drop in the
 * global `instrs` counter signals a reset; any open stack frames at that point
 * are discarded as unpaired.
 */
function computeIntervals(marks: Mark[]): {
  intervals: Record<string, IntervalStats>;
  unpaired_starts: number;
  unpaired_by_func: Record<string, number>;
} {
  type StackFrame = {
    func: string;
    startMark: Mark;
    // Running sum of direct children's inclusive cost within this invocation.
    childrenIncl: { instrs: number; mem: number; heap: number };
  };

  type CompletedInterval = {
    inclusive: { instrs: number; mem: number; heap: number };
    exclusive: { instrs: number; mem: number; heap: number };
  };

  const stack: StackFrame[] = [];
  const completed = new Map<string, CompletedInterval[]>();
  const unpaired_by_func: Record<string, number> = {};
  let unpaired_starts = 0;

  const countUnpaired = (func: string, n = 1) => {
    unpaired_starts += n;
    unpaired_by_func[func] = (unpaired_by_func[func] ?? 0) + n;
  };

  for (let i = 0; i < marks.length; i++) {
    const mark = marks[i];

    // Detect message-boundary reset: IC counter dropped.
    if (i > 0 && mark.instrs < marks[i - 1].instrs) {
      for (const frame of stack) countUnpaired(frame.func);
      stack.length = 0;
    }

    const lastColon = mark.tag.lastIndexOf(":");
    if (lastColon === -1) continue; // legacy tag without direction — ignore
    const direction = mark.tag.slice(lastColon + 1);
    const func = mark.tag.slice(0, lastColon);

    if (direction === "start") {
      stack.push({
        func,
        startMark: mark,
        childrenIncl: { instrs: 0, mem: 0, heap: 0 },
      });
    } else if (direction === "end") {
      // Find the nearest matching :start on the stack (LIFO per function).
      let foundIdx = -1;
      for (let j = stack.length - 1; j >= 0; j--) {
        if (stack[j].func === func) {
          foundIdx = j;
          break;
        }
      }
      if (foundIdx === -1) continue; // orphaned :end — skip

      // Frames above `foundIdx` are unpaired (can happen with unhandled returns).
      if (foundIdx < stack.length - 1) {
        for (let k = foundIdx + 1; k < stack.length; k++)
          countUnpaired(stack[k].func);
        stack.splice(foundIdx + 1);
      }

      const frame = stack.pop()!;
      const incl = {
        instrs: mark.instrs - frame.startMark.instrs,
        mem: mark.mem - frame.startMark.mem,
        heap: mark.heap - frame.startMark.heap,
      };
      const excl = {
        instrs: incl.instrs - frame.childrenIncl.instrs,
        mem: incl.mem - frame.childrenIncl.mem,
        heap: incl.heap - frame.childrenIncl.heap,
      };

      // Propagate this interval's inclusive cost to the parent frame.
      if (stack.length > 0) {
        const parent = stack[stack.length - 1];
        parent.childrenIncl.instrs += incl.instrs;
        parent.childrenIncl.mem += incl.mem;
        parent.childrenIncl.heap += incl.heap;
      }

      const list = completed.get(func) ?? [];
      list.push({ inclusive: incl, exclusive: excl });
      completed.set(func, list);
    }
  }

  for (const frame of stack) countUnpaired(frame.func); // frames still open at end of marks

  // Build per-function stats.
  const makeStat = (vals: number[]): IntervalStat => {
    if (vals.length === 0) return null;
    const sum = vals.reduce((a, b) => a + b, 0);
    return {
      avg: Math.round(sum / vals.length),
      min: Math.min(...vals),
      max: Math.max(...vals),
    };
  };

  const result: Record<string, IntervalStats> = {};
  for (const [func, ivs] of completed) {
    result[func] = {
      calls: ivs.length,
      inclusive: {
        instrs: makeStat(ivs.map((iv) => iv.inclusive.instrs)),
        mem: makeStat(ivs.map((iv) => iv.inclusive.mem)),
        heap: makeStat(ivs.map((iv) => iv.inclusive.heap)),
      },
      exclusive: {
        instrs: makeStat(ivs.map((iv) => iv.exclusive.instrs)),
        mem: makeStat(ivs.map((iv) => iv.exclusive.mem)),
        heap: makeStat(ivs.map((iv) => iv.exclusive.heap)),
      },
    };
  }

  return { intervals: result, unpaired_starts, unpaired_by_func };
}

/** Write one compact JSON object per line (JSON Lines format). */
function writeJsonl(marks: Mark[], path: string): void {
  writeFileSync(path, marks.map((m) => JSON.stringify(m)).join("\n") + "\n");
}

// ── Main ────────────────────────────────────────────────────────────────────────

async function main() {
  // Step 1 — validate before touching any files.
  console.log(`\nValidating ${component} targets...`);
  validateTargets();
  console.log("  ✓ All methods found");

  // Step 2 — patch sources.
  console.log("Patching sources...");
  patchSources();
  console.log("  ✓ Sources patched");

  try {
    // Step 3 — build the patched WASM.
    console.log("Building perf canister...");
    const { mocPath, sourcesArgs } = await getBuildEnvironment();
    const outputFile = join(BUILDS_DIR, `${component}-perf.wasm`);
    const entryFile = resolve(ROOT, "example", "compress.mo");
    const compileArgs = [mocPath, ...sourcesArgs, "-o", outputFile, entryFile];
    await $`${compileArgs}`.env({ ...process.env });

    // Gzip the WASM in-place.
    const tmpFile = `${outputFile}.tmp`;
    await $`gzip -c ${outputFile} > ${tmpFile}`.env({ ...process.env });
    await $`mv ${tmpFile} ${outputFile}`.env({ ...process.env });
    console.log(`  ✓ scripts/builds/${component}-perf.wasm (gzip-compressed)`);

    // Step 4 — run the PocketIC workload in a subprocess so its output can be
    //          captured natively. Bun's pipe API captures the child's fds at
    //          the OS level; no JS write() monkey-patching is needed.
    console.log("Starting PocketIC (subprocess)...");
    const runnerScript = resolve(ROOT, "scripts", "_perf_run.ts");
    const payloadBytes = PAYLOAD_BYTES[component] ?? 1024 * 1024;
    console.log(
      `  Workload size: ${payloadBytes.toLocaleString("en-US")} bytes`,
    );
    const perfLines: string[] = [];
    const inner = Bun.spawn({
      cmd: [
        process.execPath,
        runnerScript,
        component,
        outputFile,
        String(payloadBytes),
      ],
      stdout: "pipe",
      stderr: "pipe",
      env: { ...process.env },
      cwd: ROOT,
    });

    const collectLine = (line: string) => {
      if (line.includes("[perf]")) perfLines.push(line.trim());
    };
    const streamReaders = Promise.all([
      captureLines(inner.stdout, process.stdout, collectLine),
      captureLines(inner.stderr, process.stderr, collectLine),
    ]);

    const exitCode = await inner.exited;
    await streamReaders;
    if (exitCode !== 0) {
      throw new Error(`PocketIC workload exited with code ${exitCode}`);
    }
    console.log("  ✓ Workload complete");

    // Step 5 — parse captured [perf] lines. Motoko's debug_show formats
    // large Nat values with underscores (e.g. 209_722_514), so strip them
    // before converting to JavaScript numbers.
    const markRe =
      /\[perf\]\s+(\S+)\s+instrs=([\d_]+)\s+mem=([\d_]+)\s+heap=([\d_]+)/;
    const parseNat = (value: string) => parseInt(value.replaceAll("_", ""), 10);
    const marks: Mark[] = perfLines
      .map((l) => {
        const m = markRe.exec(l);
        return m
          ? {
              tag: m[1],
              instrs: parseNat(m[2]),
              mem: parseNat(m[3]),
              heap: parseNat(m[4]),
            }
          : null;
      })
      .filter((x): x is Mark => x !== null);

    // Step 6 — print the table.
    if (marks.length === 0) {
      if (perfLines.length === 0) {
        console.warn(
          "\nNo [perf] lines captured. " +
            "Did the workload trigger the instrumented methods?",
        );
      } else {
        console.warn("\nCaptured [perf] lines, but none matched the parser:");
        for (const line of perfLines) console.warn(`  ${line}`);
      }
    } else {
      const HR = "─".repeat(72);
      console.log(`\n${HR}`);
      console.log(` Perf report — component: ${component}`);
      console.log(HR);
      console.log(
        ` ${"tag".padEnd(36)} ${"instrs".padStart(15)} ${"mem (KiB)".padStart(10)} ${"heap (KiB)".padStart(11)}`,
      );
      console.log(HR);
      for (const { tag, instrs, mem, heap } of marks) {
        console.log(
          ` ${tag.padEnd(36)} ${instrs.toLocaleString("en-US").padStart(15)} ` +
            `${(mem / 1024).toFixed(0).padStart(10)} ` +
            `${(heap / 1024).toFixed(0).padStart(11)}`,
        );
      }
      console.log(HR);
    }

    // Step 7 — write .jsonl (raw marks) and .json (computed report).
    mkdirSync(OUTPUT_DIR, { recursive: true });
    const timestamp = new Date().toISOString();
    const base = join(
      OUTPUT_DIR,
      `perf-${component}-${timestamp.replace(/[:.]/g, "-")}`,
    );

    writeJsonl(marks, `${base}.jsonl`);

    const { intervals, unpaired_starts, unpaired_by_func } =
      computeIntervals(marks);
    if (unpaired_starts > 0) {
      console.log(
        `  ⚠ ${unpaired_starts} unpaired :start mark(s) (uninstrumented return paths or message boundaries)`,
      );
      const entries = Object.entries(unpaired_by_func).sort(
        (a, b) => b[1] - a[1],
      );
      for (const [func, n] of entries) {
        console.log(
          `      ${func.padEnd(36)} ${n.toLocaleString("en-US").padStart(8)}`,
        );
      }
    }
    if (unhandledReturnCount > 0) {
      console.log(
        `  ⚠ ${unhandledReturnCount} return site(s) not automatically instrumented`,
      );
    }

    const report: Report = {
      component,
      timestamp,
      total_marks: marks.length,
      unpaired_starts,
      unhandled_returns: unhandledReturnCount,
      timeline: computeTimeline(marks),
      intervals,
    };
    writeFileSync(`${base}.json`, JSON.stringify(report, null, 2));

    console.log(`\nRaw marks : ${relative(ROOT, `${base}.jsonl`)}`);
    console.log(`Report    : ${relative(ROOT, `${base}.json`)}`);
  } finally {
    console.log("\nReverting sources...");
    revertSources();
    console.log("  ✓ Sources reverted");
  }
}

main().catch((err) => {
  console.error("\nFatal error:", err);
  process.exit(1);
});
