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
    { file: "src/Huffman/Encoder.mo", funcs: ["encode", "fromFrequencies"] },
    { file: "src/Huffman/Decoder.mo", funcs: ["decode"] },
  ],
  deflate: [
    { file: "src/Deflate/Encoder.mo", funcs: ["encode", "finish"] },
    { file: "src/Deflate/Decoder.mo", funcs: ["decode"] },
  ],
  gzip: [
    { file: "src/Gzip/Encoder.mo", funcs: ["encode", "finish"] },
    { file: "src/Gzip/Decoder.mo", funcs: ["decode"] },
  ],
  lzss: [{ file: "src/LZSS/lib.mo", funcs: ["encode", "decode"] }],
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
      funcs: ["natToLeBytes", "leBytesToNat", "range", "revRange"],
    },
  ],
};

/**
 * Workload size in bytes per component. Low-level primitive components use a
 * tiny payload because their methods fire many times per byte; high-level
 * components stay at 1 MiB to keep the run representative.
 */
const PAYLOAD_BYTES: Record<string, number> = {
  huffman: 1024 * 1024,
  deflate: 1024 * 1024,
  gzip: 1024 * 1024,
  lzss: 1024 * 1024,
  bitbuffer: 10 * 1024, // 10 KiB — fine-grained primitive
  circularbuffer: 10 * 1024, // 10 KiB — fine-grained primitive
  utils: 10 * 1024, // 10 KiB — fine-grained primitive
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

/** Patch every registered source file in-memory, recording originals for revert. */
function patchSources(): void {
  for (const { file, funcs } of targets) {
    const absFile = resolve(ROOT, file);
    const original = readFileSync(absFile, "utf8");
    patchRecords.push({ file: absFile, original });

    const lines = original.split("\n");

    // 1. Collect insertion points first; process in reverse order so that
    //    earlier splice() calls don't shift the indices of later ones.
    const insertions: Array<{ afterLine: number; mark: string }> = [];
    for (const func of funcs) {
      const found = findFuncBrace(lines, func)!;
      const declIndent = lines[found.funcIdx].match(/^(\s*)/)?.[1] ?? "";
      const bodyIndent = declIndent + "  ";
      insertions.push({
        afterLine: found.braceIdx,
        mark: `${bodyIndent}Perf.mark("${component}:${func}"); // [PERF]`,
      });
    }

    insertions.sort((a, b) => b.afterLine - a.afterLine);
    for (const { afterLine, mark } of insertions) {
      lines.splice(afterLine + 1, 0, mark);
    }

    // 2. Inject the Perf import after the last existing `import` line.
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

type DeltaStat = {
  avg_delta: number;
  min_delta: number;
  max_delta: number;
} | null;

type MethodStats = {
  calls: number;
  instrs: DeltaStat;
  mem: DeltaStat;
  heap: DeltaStat;
};

type Report = {
  component: string;
  timestamp: string;
  total_marks: number;
  skipped_boundaries: number;
  timeline: TimelineEntry[];
  per_method: Record<string, MethodStats>;
};

/** Sample up to `points` evenly-spaced marks by index (always includes first and last). */
function computeTimeline(marks: Mark[], points = 11): TimelineEntry[] {
  const N = marks.length;
  if (N === 0) return [];
  const indices = new Set<number>();
  for (let i = 0; i < points; i++) {
    indices.add(Math.floor((i * (N - 1)) / (points - 1)));
  }
  return [...indices]
    .sort((a, b) => a - b)
    .map((idx) => ({ index: idx, ...marks[idx] }));
}

/** Compute per-method delta statistics (instrs/mem/heap) from consecutive calls.
 *
 * IC.performanceCounter(1) resets to zero at the start of each new ICP message
 * (e.g. every inter-canister self-call boundary in the gzip encoder). Any pair
 * of consecutive marks where instrs[i] < instrs[i-1] is a cross-message pair
 * and its delta is meaningless — we detect these globally and exclude them.
 */
function computePerMethod(marks: Mark[]): {
  stats: Record<string, MethodStats>;
  skipped_boundaries: number;
} {
  // Build a sorted array of reset global indices for efficient range queries.
  const resetIndices: number[] = [];
  for (let i = 1; i < marks.length; i++) {
    if (marks[i].instrs < marks[i - 1].instrs) resetIndices.push(i);
  }

  /** Returns true if a message boundary reset occurred strictly between
   *  global indices `a` (exclusive) and `b` (inclusive). */
  function hasResetBetween(a: number, b: number): boolean {
    return resetIndices.some((r) => r > a && r <= b);
  }

  // Group marks in first-seen insertion order, tagging each with its global index.
  const groups = new Map<string, Array<{ mark: Mark; globalIdx: number }>>();
  for (let i = 0; i < marks.length; i++) {
    const m = marks[i];
    const g = groups.get(m.tag);
    if (g) g.push({ mark: m, globalIdx: i });
    else groups.set(m.tag, [{ mark: m, globalIdx: i }]);
  }

  const result: Record<string, MethodStats> = {};
  for (const [tag, group] of groups) {
    if (group.length < 2) {
      result[tag] = {
        calls: group.length,
        instrs: null,
        mem: null,
        heap: null,
      };
      continue;
    }
    const stats = (key: "instrs" | "mem" | "heap"): DeltaStat => {
      let sum = 0,
        min = Infinity,
        max = -Infinity,
        count = 0;
      for (let i = 1; i < group.length; i++) {
        // Skip the pair if a message boundary reset occurred anywhere between
        // the two marks (not just at the second mark's global index).
        if (hasResetBetween(group[i - 1].globalIdx, group[i].globalIdx))
          continue;
        const d = group[i].mark[key] - group[i - 1].mark[key];
        sum += d;
        if (d < min) min = d;
        if (d > max) max = d;
        count++;
      }
      if (count === 0) return null;
      return {
        avg_delta: Math.round(sum / count),
        min_delta: min,
        max_delta: max,
      };
    };
    result[tag] = {
      calls: group.length,
      instrs: stats("instrs"),
      mem: stats("mem"),
      heap: stats("heap"),
    };
  }
  return { stats: result, skipped_boundaries: resetIndices.length };
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

    const { stats: perMethod, skipped_boundaries } = computePerMethod(marks);
    if (skipped_boundaries > 0) {
      console.log(
        `  ⚠ Skipped ${skipped_boundaries} cross-message boundary pair(s) from delta stats`,
      );
    }

    const report: Report = {
      component,
      timestamp,
      total_marks: marks.length,
      skipped_boundaries,
      timeline: computeTimeline(marks),
      per_method: perMethod,
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
