#!/usr/bin/env bun
/**
 * Performance measurement script for motoko-compression.
 *
 * Usage:
 *   bun run scripts/perf.ts component=<name>
 *
 * Available components: huffman, deflate, gzip, lzss, compress
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
    {
      file: "src/Deflate/Symbol.mo",
      funcs: ["lengthMarker", "distanceMarker"],
    },
    {
      file: "src/Deflate/Block.mo",
      funcs: ["add", "flush", "clear"],
    },
    {
      file: "src/Deflate/HuffmanCodec.mo",
      funcs: [
        "build",
        "buildFromFreqs",
        "prepareSave",
        "save",
        "headerBits",
        "emit",
      ],
    },
    {
      file: "src/Deflate/Encoder.mo",
      funcs: ["encodeByte", "encode", "flush", "clear", "finish"],
    },
    {
      file: "src/Deflate/Decoder.mo",
      funcs: ["decodeStreamingWithCapacity", "bytesConsumed"],
    },
  ],
  gzip: [
    {
      file: "src/Gzip/Encoder.mo",
      funcs: ["encode", "finish", "compressed", "chunks"],
    },
    {
      file: "src/Gzip/Decoder.mo",
      funcs: ["decode", "start", "step"],
    },
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
        "hashAt",
        "insertString",
        "slideWindow",
        "longestMatch",
        "processOne",
        "encodeByte",
        "encode",
        "flush",
        "clear",
      ],
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
  compress: [
    {
      // Top-level gzip encoder — one encode() + one finish() per run.
      // These are the tags summed by computeTopLevel() for the high-level summary.
      file: "src/Gzip/Encoder.mo",
      funcs: ["encode", "finish", "compressed", "chunks"],
    },
    {
      // LZSS encoder — the byte-by-byte hot loop. `encode` is a thin for-loop
      // wrapper; omitted to avoid one mark pair per 10 KiB batch call.
      file: "src/LZSS/Encoder/lib.mo",
      funcs: [
        "encodeByte",
        "processOne",
        "longestMatch",
        "insertString",
        "slideWindow",
        "flush",
      ],
    },
  ],
  decompress: [
    {
      file: "src/Gzip/Decoder.mo",
      funcs: ["decode", "start", "step"],
    },
    {
      file: "src/Deflate/Decoder.mo",
      funcs: [
        "decodeStreamingWithCapacity",
        "decodeStoredBlock",
        "decodeCompressedBlock",
        "loadDynamicHeader",
      ],
    },
    {
      file: "src/Huffman/Decoder.mo",
      funcs: ["fromBitwidthsFast"],
    },
    {
      file: "src/internal/OutByteBuffer.mo",
      funcs: ["copyMatch", "grow", "toArray"],
    },
  ],
};

/**
 * Top-level function tags (per component) whose inclusive intervals are summed
 * to produce a high-level work + footprint summary printed at the end of a run.
 *
 * Tags follow the `moduleLabel:func` convention used by `fileToLabel`:
 *   src/Gzip/Encoder.mo → "gzip_encoder"
 *   src/Gzip/Decoder.mo → "gzip_decoder"
 */
const TOP_LEVEL: Partial<Record<string, string[]>> = {
  deflate: [
    "deflate_encoder:encode",
    "deflate_encoder:flush",
    "deflate_encoder:finish",
  ],
  gzip: [
    "gzip_encoder:encode",
    "gzip_encoder:finish",
    "gzip_encoder:compressed",
    "gzip_decoder:decode",
    "gzip_decoder:start",
    "gzip_decoder:step",
  ],
  compress: [
    "gzip_encoder:encode",
    "gzip_encoder:finish",
    "gzip_encoder:compressed",
  ],
  decompress: [
    "gzip_decoder:decode",
    "gzip_decoder:start",
    "gzip_decoder:step",
  ],
};

/**
 * Workload size in bytes per component. Low-level primitive components use a
 * tiny payload because their methods fire many times per byte; high-level
 * components stay at 1 MiB to keep the run representative.
 */
const PAYLOAD_BYTES: Record<string, number> = {
  huffman: 10 * 1024,
  deflate: 100 * 1024,
  gzip: 50 * 1024 * 1024,
  lzss: 10 * 1024,
  bitbuffer: 10 * 1024, // 10 KiB — fine-grained primitive
  utils: 10 * 1024, // 10 KiB — fine-grained primitive
  bitreader: 10 * 1024, // 10 KiB — fine-grained primitive
  crc32: 10 * 1024, // 10 KiB — fine-grained primitive
  compress: 100 * 1024,
  decompress: 100 * 1024,
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

// ── Module label derivation ────────────────────────────────────────────────────

/**
 * Derive a short, unique module label from a source file path so that
 * functions with the same name in different files produce distinct mark tags.
 *
 * Rules (applied to the path relative to src/, without the .mo extension):
 *   - Strip a leading "internal/" segment (it adds no disambiguation).
 *   - If the last segment is "lib", drop it and use the parent directory name.
 *   - Convert each remaining CamelCase segment to snake_case.
 *   - Join segments with "_".
 *
 * Examples:
 *   src/Gzip/Encoder.mo            → gzip_encoder
 *   src/Deflate/Encoder.mo         → deflate_encoder
 *   src/Deflate/HuffmanCodec.mo    → deflate_huffman_codec
 *   src/LZSS/Encoder/lib.mo        → lzss_encoder
 *   src/internal/BitBuffer.mo      → bit_buffer
 *   src/internal/CRC32.mo          → crc32
 */
function fileToLabel(file: string): string {
  const normalized = file.replace(/^src\//, "").replace(/\.mo$/, "");
  let parts = normalized.split("/");
  if (parts[0] === "internal") parts = parts.slice(1);
  if (parts[parts.length - 1] === "lib") parts = parts.slice(0, -1);
  const toSnake = (s: string) =>
    s
      .replace(/([A-Z]+)([A-Z][a-z])/g, "$1_$2") // ABCDef → ABC_Def
      .replace(/([a-z])([A-Z])/g, "$1_$2") //  aB  → a_B
      .toLowerCase();
  return parts.map(toSnake).join("_");
}

// ── Source patching ────────────────────────────────────────────────────────────

type PatchRecord = { file: string; original: string };
const patchRecords: PatchRecord[] = [];

/**
 * Locate the line index of `func <name>(` (or `func <name><`) and the line
 * index where the function's opening brace `{` appears.
 * Scans up to 8 lines forward from the declaration to handle multi-line signatures.
 * Uses balanced-paren scanning to skip over structural record types inside the
 * parameter list (e.g. `{ next : () -> T }`) and find the actual function body `{`.
 * Returns null when the function is not found or uses expression-body syntax (`= expr`).
 */
function findFuncBrace(
  lines: string[],
  funcName: string,
): { funcIdx: number; braceIdx: number; braceCharIdx: number } | null {
  const funcRe = new RegExp(`\\bfunc\\s+${funcName}\\s*[(<]`);
  const funcIdx = lines.findIndex((l) => funcRe.test(l));
  if (funcIdx === -1) return null;

  // Join up to 8 lines to handle multi-line signatures, then scan
  // character-by-character so structural record types inside the parameter
  // list (e.g. `{ next : () -> ?T }`) are skipped correctly.
  const combined = lines
    .slice(funcIdx, Math.min(funcIdx + 8, lines.length))
    .join("\n");

  // Position cursor after `func funcName`.
  const funcNameMatch = new RegExp(`\\bfunc\\s+${funcName}\\s*`).exec(combined);
  if (!funcNameMatch) return null;
  let i = funcNameMatch.index + funcNameMatch[0].length;

  // Skip generic type-parameter list `<…>` if present.
  if (combined[i] === "<") {
    let depth = 0;
    while (i < combined.length) {
      if (combined[i] === "<") depth++;
      else if (combined[i] === ">") {
        depth--;
        if (depth === 0) {
          i++;
          break;
        }
      }
      i++;
    }
  }

  // Consume the parameter list `(…)`, tracking nested parens to skip
  // structural types like `(_ : { next : () -> T })`.
  if (combined[i] !== "(") return null;
  let parenDepth = 0;
  while (i < combined.length) {
    if (combined[i] === "(") parenDepth++;
    else if (combined[i] === ")") {
      parenDepth--;
      if (parenDepth === 0) {
        i++;
        break;
      }
    }
    i++;
  }

  // After the param list, scan for:
  //   `{`  → function body opening brace  → return its line index.
  //   `=`  → expression-body (no brace)   → return null.
  //
  // Track `<>` and `{}` depth so that structural types in the return-type
  // annotation (e.g. `Result<{ #more; #done : T }, Text>`) are not mistaken
  // for the function body opening brace.
  let angleDepth = 0;
  let structBraceDepth = 0;
  while (i < combined.length) {
    const ch = combined[i];
    const next = combined[i + 1] ?? "";
    const prev = combined[i - 1] ?? "";

    if (
      ch === "<" &&
      next !== "=" &&
      next !== "<" &&
      prev !== "!" &&
      prev !== "<"
    ) {
      angleDepth++;
    } else if (ch === ">" && prev !== "=" && next !== "=" && next !== ">") {
      if (angleDepth > 0) angleDepth--;
    } else if (ch === "{") {
      if (angleDepth > 0 || structBraceDepth > 0) {
        // Inside a generic type parameter or a nested structural type — not the body.
        structBraceDepth++;
      } else {
        // Top-level `{` with no open `<>` or `{}`: this is the function body.
        const before = combined.slice(0, i);
        const newlinesBefore = (before.match(/\n/g) ?? []).length;
        const lineStartInCombined = before.lastIndexOf("\n") + 1;
        const braceCharIdx = i - lineStartInCombined;
        return { funcIdx, braceIdx: funcIdx + newlinesBefore, braceCharIdx };
      }
    } else if (ch === "}") {
      if (structBraceDepth > 0) structBraceDepth--;
    }

    // Detect expression-body `=` (but not `==`, `!=`, `<=`, `>=`).
    if (
      ch === "=" &&
      next !== "=" &&
      next !== ">" &&
      prev !== "!" &&
      prev !== "<" &&
      prev !== ">"
    ) {
      return null;
    }
    i++;
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
  openBraceCharIdx: number = 0,
): number {
  let depth = 0;
  let inString = false;
  let inLineComment = false;
  let inBlockComment = false;

  for (let lineIdx = openBraceLineIdx; lineIdx < lines.length; lineIdx++) {
    const line = lines[lineIdx];
    inLineComment = false;

    // On the open-brace line, start scanning at the brace itself so that any
    // structural-type `{...}` pair earlier on the same line is not counted.
    const startCol = lineIdx === openBraceLineIdx ? openBraceCharIdx : 0;
    for (let i = startCol; i < line.length; i++) {
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

/**
 * Scan backward from the line before the closing brace to find the last
 * meaningful line in the function body. Returns its line index if it looks
 * like a plain implicit-return expression (i.e. does NOT start with `}` or
 * a closing delimiter). Returns null if the last meaningful line is a block
 * close or the body is empty.
 */
function findImplicitReturnLine(
  lines: string[],
  openBraceLineIdx: number,
  closingBraceLineIdx: number,
): number | null {
  for (let i = closingBraceLineIdx - 1; i > openBraceLineIdx; i--) {
    const trimmed = lines[i].trim();
    if (trimmed === "" || trimmed.startsWith("//")) continue;
    // Block-close or multiline-expression closing delimiter → not a simple expression.
    if (trimmed.startsWith("}") || trimmed.startsWith(")")) return null;
    return i;
  }
  return null;
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
  | {
      kind: "inline_case";
      lineIdx: number;
      indent: string;
      caseHead: string;
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

  // `case (pattern) return expr;` on a single line (Motoko switch-case arm).
  const caseStart = /^\s*case\s+\(/.exec(line);
  if (caseStart) {
    let depth = 0;
    let parenEnd = -1;
    const openIdx = line.indexOf("(", caseStart[0].length - 1);
    for (let i = openIdx; i < line.length; i++) {
      if (line[i] === "(") depth++;
      else if (line[i] === ")") {
        depth--;
        if (depth === 0) {
          parenEnd = i;
          break;
        }
      }
    }
    if (parenEnd !== -1) {
      const afterCase = line.slice(parenEnd + 1).trim();
      if (/^return\b/.test(afterCase)) {
        const caseHead = line.slice(0, parenEnd + 1).trimEnd();
        const returnExpr = afterCase
          .slice("return".length)
          .trim()
          .replace(/;\s*$/, "");
        return { kind: "inline_case", lineIdx, indent, caseHead, returnExpr };
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
// Instrumentation warnings deferred to the results section.
const patchWarnings: string[] = [];

type PatchOp =
  | { kind: "insert"; afterLine: number; text: string }
  | { kind: "replace"; lineIdx: number; newLines: string[] };

/** Patch every registered source file in-memory, recording originals for revert. */
function patchSources(): void {
  for (const { file, funcs } of targets) {
    const absFile = resolve(ROOT, file);
    const original = readFileSync(absFile, "utf8");
    patchRecords.push({ file: absFile, original });

    // Derive a per-file module label so marks are self-identifying regardless
    // of which component registry is active (e.g. "gzip_encoder:encode:start"
    // instead of "compress:encode:start").
    const moduleLabel = fileToLabel(file);

    const lines = original.split("\n");
    const ops: PatchOp[] = [];

    for (const func of funcs) {
      const found = findFuncBrace(lines, func)!;
      const openBraceLineIdx = found.braceIdx;
      const closingBraceLineIdx = findFuncClosingBrace(
        lines,
        openBraceLineIdx,
        found.braceCharIdx,
      );

      const declIndent = lines[found.funcIdx].match(/^(\s*)/)?.[1] ?? "";
      const bodyIndent = declIndent + "  ";
      const startMark = `${bodyIndent}Perf.mark("${moduleLabel}:${func}:start"); // [PERF]`;
      const endMarkBody = `Perf.mark("${moduleLabel}:${func}:end"); // [PERF]`;

      // Special case: single-line function body (opening and closing brace on
      // the same line). Expand to multi-line so :start/:end fit inside the body.
      // Only safe for unit-returning functions; for non-unit single-liners the
      // body IS the return value, so we can't add an :end mark — skip and warn.
      if (closingBraceLineIdx === openBraceLineIdx) {
        if (!funcReturnsUnit(lines, found.funcIdx, openBraceLineIdx)) {
          patchWarnings.push(
            `  ⚠ ${func}: skipping (single-line non-unit function — cannot instrument without altering return type)`,
          );
          continue;
        }
        const line = lines[openBraceLineIdx];
        const openBraceCharIdx = found.braceCharIdx;
        const closeBraceCharIdx = line.lastIndexOf("}");
        const body = line.slice(openBraceCharIdx + 1, closeBraceCharIdx).trim();
        const afterClose = line.slice(closeBraceCharIdx + 1);
        const beforeOpen = line.slice(0, openBraceCharIdx);
        ops.push({
          kind: "replace",
          lineIdx: openBraceLineIdx,
          newLines: [
            `${beforeOpen}{`,
            startMark,
            ...(body ? [`${bodyIndent}${body}`] : []),
            `${bodyIndent}${endMarkBody}`,
            `${declIndent}}${afterClose}`,
          ],
        });
        continue;
      }

      // :start immediately after the opening brace.
      ops.push({
        kind: "insert",
        afterLine: openBraceLineIdx,
        text: startMark,
      });

      // :end immediately before the closing brace — ONLY for unit-returning
      // functions. For non-unit functions, a trailing Perf.mark (type ()) would
      // either become dead code that still type-checks the function body as ()
      // or be parsed as part of the prior expression. Non-unit functions rely
      // entirely on the explicit-`return` sites instrumented below; if any
      // return path can't be classified, the unpaired-mark warning surfaces it.
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
        } else if (site.kind === "inline_case") {
          // Rewrite `case (pat) return expr;` into a block with the end mark.
          ops.push({
            kind: "replace",
            lineIdx: site.lineIdx,
            newLines: [
              `${site.caseHead} {`,
              `${site.indent}  ${endMarkBody}`,
              `${site.indent}  return ${site.returnExpr};`,
              `${site.indent}};`,
            ],
          });
        } else {
          unhandledReturnCount++;
        }
      }

      // For non-unit functions with no explicit `return`, check whether the
      // last meaningful line before the closing brace is a plain expression
      // (e.g. `resp;`). If so, insert an :end mark just before it.
      if (!funcReturnsUnit(lines, found.funcIdx, openBraceLineIdx)) {
        const implicitLineIdx = findImplicitReturnLine(
          lines,
          openBraceLineIdx,
          closingBraceLineIdx,
        );
        if (implicitLineIdx !== null) {
          const implicitIndent =
            lines[implicitLineIdx].match(/^(\s*)/)?.[1] ?? "";
          ops.push({
            kind: "insert",
            afterLine: implicitLineIdx - 1,
            text: `${implicitIndent}${endMarkBody}`,
          });
        }
      }
    }

    // Apply ops in descending line order so each splice doesn't shift later indices.
    // Tie-break rule: for ops targeting the same line, :start marks must be processed
    // LAST so that each splice(P, 0, ...) pushes them topmost in the final file.
    ops.sort((a, b) => {
      const aLine = a.kind === "insert" ? a.afterLine : a.lineIdx;
      const bLine = b.kind === "insert" ? b.afterLine : b.lineIdx;
      if (bLine !== aLine) return bLine - aLine;
      // Equal target line: :start processed last → ends up above :end marks.
      const aIsStart = a.kind === "insert" && a.text.includes(":start");
      const bIsStart = b.kind === "insert" && b.text.includes(":start");
      if (aIsStart !== bIsStart) return aIsStart ? 1 : -1;
      return 0;
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
          new RegExp(esc(`"${moduleLabel}:${func}:start"`), "g"),
        ) ?? []
      ).length;
      const nEnd = (
        patchedSrc.match(
          new RegExp(esc(`"${moduleLabel}:${func}:end"`), "g"),
        ) ?? []
      ).length;
      if (nStart !== nEnd) {
        patchWarnings.push(
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

type TopLevelTagSummary = {
  calls: number;
  total_instrs: number;
  total_mem: number;
  total_heap: number;
};

type TopLevelSummary = {
  /** Sum of inclusive instrs across all top-level tags — total "work" for this run. */
  work_instrs: number;
  /** Sum of inclusive mem deltas across all top-level tags. */
  work_mem: number;
  /** Sum of inclusive heap deltas across all top-level tags. */
  work_heap: number;
  /** Absolute rts_memory_size at the last top-level :end mark — post-run footprint. */
  footprint_mem: number;
  /** Absolute rts_heap_size at the last top-level :end mark — post-run footprint. */
  footprint_heap: number;
  per_tag: Record<string, TopLevelTagSummary>;
};

type Report = {
  component: string;
  timestamp: string;
  total_marks: number;
  unpaired_starts: number;
  unhandled_returns: number;
  timeline: TimelineEntry[];
  intervals: Record<string, IntervalStats>;
  top_level: TopLevelSummary | null;
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

/**
 * Compute a high-level summary for the top-level tags in TOP_LEVEL[component].
 *
 * - work_instrs/mem/heap: sum of (avg × calls) over all top-level tags.
 *   For the single-message inline path calls==1, so avg==total.
 * - footprint_mem/heap: absolute rts_memory_size / rts_heap_size at the LAST
 *   top-level :end mark — a stable post-run snapshot rather than a delta.
 *
 * Returns null when the component has no TOP_LEVEL entry or any required tag
 * produced no completed interval (e.g. message-boundary discard).
 */
function computeTopLevel(
  marks: Mark[],
  intervals: Record<string, IntervalStats>,
  comp: string,
): TopLevelSummary | null {
  const tags = TOP_LEVEL[comp];
  if (!tags || tags.length === 0) return null;

  let work_instrs = 0;
  let work_mem = 0;
  let work_heap = 0;
  const per_tag: Record<string, TopLevelTagSummary> = {};

  for (const tag of tags) {
    const stats = intervals[tag];
    if (!stats || stats.calls === 0) {
      console.warn(
        `  ⚠ top_level: no completed interval for "${tag}" — the call may have failed (check [perf-warn] lines above for details). Skipping summary.`,
      );
      return null;
    }
    const instrs = stats.inclusive.instrs?.avg ?? 0;
    const mem = stats.inclusive.mem?.avg ?? 0;
    const heap = stats.inclusive.heap?.avg ?? 0;
    const total_instrs = instrs * stats.calls;
    const total_mem = mem * stats.calls;
    const total_heap = heap * stats.calls;
    work_instrs += total_instrs;
    work_mem += total_mem;
    work_heap += total_heap;
    per_tag[tag] = { calls: stats.calls, total_instrs, total_mem, total_heap };
  }

  // Absolute mem/heap at the last top-level :end mark.
  let footprint_mem = 0;
  let footprint_heap = 0;
  for (let i = marks.length - 1; i >= 0; i--) {
    const m = marks[i];
    if (m.tag.endsWith(":end")) {
      const func = m.tag.slice(0, m.tag.lastIndexOf(":"));
      if (tags.includes(func)) {
        footprint_mem = m.mem;
        footprint_heap = m.heap;
        break;
      }
    }
  }

  return {
    work_instrs,
    work_mem,
    work_heap,
    footprint_mem,
    footprint_heap,
    per_tag,
  };
}

/** Write one compact JSON object per line (JSON Lines format). */
function writeJsonl(marks: Mark[], path: string): void {
  writeFileSync(path, marks.map((m) => JSON.stringify(m)).join("\n") + "\n");
}

// ── Main ────────────────────────────────────────────────────────────────────────

async function main() {
  const t0 = Date.now();

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
    try {
      await $`${compileArgs}`.env({ ...process.env });
    } catch (err) {
      // Save patched sources so the user can inspect the syntax error before
      // the automatic revert kicks in.
      for (const { file } of patchRecords) {
        const dumpPath = join(
          BUILDS_DIR,
          `${component}-` + file.replace(/\//g, "_") + ".patched.mo",
        );
        writeFileSync(dumpPath, readFileSync(file, "utf8"));
        console.error(`  ✗ Patched source dumped to ${dumpPath}`);
      }
      throw err;
    }

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
    if (patchWarnings.length > 0) {
      console.log("\nInstrumentation notes:");
      for (const w of patchWarnings) console.log(w);
    }
    if (unhandledReturnCount > 0) {
      console.log(
        `  ⚠ ${unhandledReturnCount} return site(s) not automatically instrumented`,
      );
    }

    const topLevel = computeTopLevel(marks, intervals, component);
    const leadTimeMs = Date.now() - t0;
    if (topLevel) {
      const HR2 = "─".repeat(72);
      console.log(`\n${HR2}`);
      console.log(` Top-level summary — component: ${component}`);
      console.log(HR2);
      console.log(` ${"metric".padEnd(28)} ${"value".padStart(18)}`);
      console.log(HR2);
      console.log(
        ` ${"lead_time".padEnd(28)} ${`${(leadTimeMs / 1000).toFixed(1)} s`.padStart(18)}`,
      );
      console.log(
        ` ${"work_instrs".padEnd(28)} ${topLevel.work_instrs.toLocaleString("en-US").padStart(18)}`,
      );
      console.log(
        ` ${"work_mem (KiB)".padEnd(28)} ${(topLevel.work_mem / 1024).toFixed(0).padStart(18)}`,
      );
      console.log(
        ` ${"work_heap (KiB)".padEnd(28)} ${(topLevel.work_heap / 1024).toFixed(0).padStart(18)}`,
      );
      console.log(
        ` ${"footprint_mem (KiB)".padEnd(28)} ${(topLevel.footprint_mem / 1024).toFixed(0).padStart(18)}`,
      );
      console.log(
        ` ${"footprint_heap (KiB)".padEnd(28)} ${(topLevel.footprint_heap / 1024).toFixed(0).padStart(18)}`,
      );
      if (Object.keys(topLevel.per_tag).length > 1) {
        console.log(HR2);
        for (const [tag, s] of Object.entries(topLevel.per_tag)) {
          console.log(
            ` ${tag.padEnd(28)} ${s.total_instrs.toLocaleString("en-US").padStart(18)} instrs`,
          );
        }
      }
      console.log(HR2);
    }

    const report: Report = {
      component,
      timestamp,
      total_marks: marks.length,
      unpaired_starts,
      unhandled_returns: unhandledReturnCount,
      timeline: computeTimeline(marks),
      intervals,
      top_level: topLevel,
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
