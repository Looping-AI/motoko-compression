# AGENTS Instructions

## Project Overview

This is a **Motoko library package** implementing compression algorithms (Gzip, DEFLATE, LZSS, Huffman) for the Internet Computer. It is intended for use by other canisters via `mops add compression`.

- **Language**: Motoko
- **Package manager**: `mops` for Motoko dependencies
- **Build tool**: `icp` CLI (`@icp-sdk/icp-cli`) — used only for compilation checks

## Important: Package Manager

Use `npm` for global CLI tool installs.

Examples:

- `npm install -g @icp-sdk/icp-cli` — ICP CLI
- `npm install -g ic-mops` — Mops package manager

Mops commands:

- `mops install` — Install Motoko dependencies
- `mops test` — Run Motoko unit tests
- `mops add <package>` — Add a Motoko package

## Library Dependencies

### mo:base is Deprecated — Use mo:core

NEVER use `mo:base` — it is deprecated and unmaintained. Use `mo:core` instead.

- `mo:core` is the modern successor to `mo:base`.
- All standard modules are available in `mo:core` (Array, Blob, Principal, Text, etc.)
- If you encounter compatibility issues, check the module definitions in `.mops/core@{version}/src/` for the correct API.

## How to Verify Your Work

Always start by checking for errors using the `get_errors` tool. This catches compilation errors, type issues, and lint warnings.

### For Motoko Code

Run the test suite after every change:

```bash
mops test
```

To check compilation without deploying:

```bash
icp build compression
```

## Debugging with `mops test`

`mops test` (without arguments) suppresses all stdout — `Debug.print` calls are silently discarded. To see console output, run a **specific test file** by passing the filename stem (the filename without the `.Test.mo` suffix):

```bash
mops test Deflate      # runs tests/Deflate.Test.mo and shows stdout
mops test Huffman      # runs tests/Huffman.Test.mo and shows stdout
mops test BitReader    # runs tests/BitReader.Test.mo and shows stdout
```

### Tracing values with `Debug.print`

Scatter `Debug.print` calls in the code under test, using `debug_show` to serialise any value:

```motoko
import Debug "mo:core/Debug";

Debug.print("myVar=" # debug_show myVar);

```

Then run `mops test <Stem>` to see the trace. This is the fastest way to understand what values flow through a function without needing an interactive debugger.

### Cleanup after debugging

Remove all `Debug.print` calls and their `import Debug` lines before committing. Do not leave debug instrumentation in source files.

---

## Performance Tracing

The project includes a scripted performance measurement system that instruments Motoko source files transiently, runs a real workload on PocketIC, captures IC instruction/memory counts, and produces structured reports — all without touching committed source.

### Components

| File                   | Role                                                                                                                      |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| `src/internal/Perf.mo` | Motoko probe — emits `[perf] <tag> instrs=N mem=N heap=N` via `Debug.print` using `IC.performanceCounter(1)` (cumulative) |
| `scripts/perf.ts`      | Orchestrator — patches sources, builds WASM, spawns workload, parses marks, writes reports, reverts sources               |
| `scripts/_perf_run.ts` | PocketIC workload runner — installs instrumented WASM, calls `generate_data` + `compress_data`, tears down                |
| `example/compress.mo`  | Canister entry point compiled for perf runs                                                                               |
| `scripts/output/`      | Report output directory (git-ignored)                                                                                     |

### Usage

```bash
bun run perf component=<name>
```

Available components: `huffman`, `deflate`, `gzip`, `lzss`

The script:

1. Validates that every registered function exists in its source file.
2. Injects `Perf.mark("component:func")` as the first line of each function body and adds the matching `import Perf` — both tagged `// [PERF]` / `// [PERF_IMPORT]` for clean revert.
3. Builds a gzip-compressed WASM from `example/compress.mo`.
4. Spawns `scripts/_perf_run.ts` as a subprocess; captures both stdout and stderr line-by-line.
5. Parses every `[perf]` line emitted by the canister.
6. Prints a summary table to stdout.
7. Writes two output files, then reverts all source changes (even on error or Ctrl+C).

### Output files

Both files share the same base name `scripts/output/perf-<component>-<ISO-timestamp>`:

- **`.jsonl`** — raw marks, one compact JSON object per line. Append-safe and diff-friendly.
- **`.json`** — computed report:
  - `total_marks` — total mark count for the run
  - `unpaired_starts` — `:start` marks without a matching `:end` (uninstrumented exit paths or message-boundary resets)
  - `unhandled_returns` — early-return sites that could not be automatically rewritten
  - `timeline` — 11 samples at 0%, 10%, …, 100% of `:start` marks by index (always includes first and last)
  - `intervals` — per-function statistics computed from matched `:start`/`:end` pairs:
    - `calls` — number of complete intervals
    - `inclusive.instrs / mem / heap` — stats (`avg`, `min`, `max`) for the full function body cost
    - `exclusive.instrs / mem / heap` — stats after subtracting direct instrumented children's inclusive cost (self-time)
    - `null` when there are no complete intervals for a function

### Important constraints

- **Never commit `Perf.mo` imports in `src/`**. The module is for transient instrumentation only. After a run, verify with `rg "[PERF]|PERF_IMPORT" src` — expect no matches.
- `scripts/builds/` and `scripts/output/` are git-ignored. Do not add report files to source control.
- Instruction counts use `IC.performanceCounter(1)` (monotonically cumulative, resets at ICP message boundaries). Intervals are formed by matching `:start`/`:end` mark pairs; pairs that straddle a message boundary are discarded.

### Parsing Performance Reports

The `.json` output files contain detailed per-function statistics. To generate human-readable reports:

#### File Structure

The output JSON has this shape:

```json
{
  "component": "lzss",
  "timestamp": "2026-05-21T22:02:48.941Z",
  "total_marks": 136439,
  "unpaired_starts": 1,
  "unhandled_returns": 0,
  "timeline": [...],
  "intervals": {
    "function:name": {
      "calls": 10240,
      "inclusive": {
        "instrs": { "avg": 593246, "min": 32195, "max": 115341735 },
        "mem": { "avg": 35955, "min": 0, "max": 7143424 },
        "heap": { "avg": 35918, "min": 1888, "max": 7086544 }
      },
      "exclusive": { /* same structure */ }
    }
  }
}
```

#### Generating Reports

1. **Extract intervals:** Iterate over `json.intervals` to get all function data
2. **Calculate totals:** For each metric, compute `calls * avg` to get aggregate cost
3. **Sort by total:** Rank functions by total instructions, memory, and heap separately
4. **Create tables:** Build three tables per cost type (inclusive, exclusive):
   - Sort by **total** descending
   - Columns: Function, Calls, Avg, Min, Max, **Total** (at end)
5. **Interpretation:**
   - **Inclusive:** Full cost including all children (use for identifying bottlenecks)
   - **Exclusive:** Self-time only (use for identifying where the actual work happens)
   - High **inclusive-to-exclusive** ratio indicates a function calls expensive children

#### Example Workflow

To analyze `perf-lzss-2026-05-21T22-02-48-941Z.json`:

1. Load the JSON file and extract `intervals` object
2. For each function, compute:
   - `total_instrs = calls * avg_instrs_inclusive`
   - `total_mem = calls * avg_mem_inclusive`
   - `total_heap = calls * avg_heap_inclusive`
3. Sort functions by `total_instrs` descending for the instructions table
4. Repeat for memory and heap (separate sorts)
5. Do the same for exclusive metrics in parallel sections
6. Add summary insights:
   - Which functions dominate total cost
   - Which are most-called vs. most-expensive-per-call
   - Call overhead analysis (inclusive vs. exclusive gap)

#### When to Request Report Generation

Ask an AI assistant to parse and generate a report by providing:

- The `.json` file path
- Specific metrics to focus on (e.g., "sort by total instructions")
- Optional: any custom grouping or filtering

The assistant will read the JSON, compute totals, and generate markdown tables sorted as requested.

---

## Motoko Conventions

- Model function parameter order: place the state/collection parameter first, aligning with `mo:core` idioms (e.g. `Map.get(map, compare, key)`).
- `Nat` is a subtype of `Int` (`Nat <: Int`): do not add explicit casts when a function parameter is typed `Int` and the caller has a `Nat`.
- Prefer `query` functions for read-only operations to save cycles.
- Use `Result<T, E>` for fallible operations; variant names are `#ok`/`#err`.

## When to Request Feedback (CRITICAL)

STOP and REQUEST USER FEEDBACK before proceeding in these situations:

### Design Decision Blockers

- Architecture changes that affect the public library API
- Algorithm design choices with multiple valid trade-offs (speed vs. compression ratio)
- Dependency decisions where multiple options exist (e.g. replacing an external package with inline logic)

### Technical Blockers

- Multiple solution paths exist with unclear "best" choice
- External dependency limitations (package not compatible with mo:core or moc version)
- Workarounds needed that compromise original requirements

### How to Request Feedback

When you encounter a blocking decision, use the `ask_questions` tool to surface the decision before proceeding. Do not ask in free text — the tool formats the question clearly.

Steps:

1. Stop immediately — do not implement a solution
2. Use `ask_questions`: frame the situation, present 2-3 options (with pros/cons), mark your recommended option
3. Wait for user decision before coding

## Testing Practices

### Prefer `expect` Over `assert`

In Motoko tests, use `expect` syntax instead of `assert`. The `expect` API provides better error messages with actual vs expected values.

Refer to `.mops/test@{version}/README.md` for complete `expect` documentation and examples.
