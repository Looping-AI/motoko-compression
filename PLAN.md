# Performance Optimization Plan

## Overview

Scientific, bottom-up performance improvement of the motoko-compression library.
Each component is profiled **before and after** every change using `bun run perf component=<name>`.
A change is accepted only when it reduces the target metric without regressing others.

Optimization order follows the dependency graph: primitives first, then algorithms,
then codec layers, then the public Gzip API.

---

## How to measure

```bash
# Run perf for a component and save the report
bun run perf component=huffman    # Layer 1
bun run perf component=deflate    # Layer 2
bun run perf component=gzip       # Layer 3 (end-to-end)
bun run perf component=lzss       # Layer 1
```

Reports land in `scripts/output/` as `perf-<component>-<timestamp>.json`.
Compare `per_method.avg_delta` for instructions, `mem`, and `heap` across runs.

---

## Checkbox legend

| Symbol | Meaning                      |
| ------ | ---------------------------- |
| `[ ]`  | Not started                  |
| `[~]`  | In progress                  |
| `[x]`  | Done – improvement confirmed |
| `[-]`  | Skipped / not applicable     |

---

## Layer 0 — Primitives

These are the innermost hot-path components. Gains here compound upward.

### `src/utils.mo`

Helper math and byte-conversion functions called throughout the library.

- [x] **Baseline measured** — 2026-05-20T23-35-43Z (10 KiB workload)
- [-] `natToLeBytes` — 3 calls per 10 KiB; impact negligible
- [-] `leBytesToNat` / `bytesToNat` — 3 calls per 10 KiB; impact negligible
- [-] `divCeil` — too few call sites to warrant change
- [x] `range` / `revRange` — **fully removed**; all 20+ call sites replaced with inline `while` loops across 8 src files + 3 test files

**Notes:** Baseline: `range` = 11 201 calls, 48 133 avg instrs/call, 2 684 B heap/call — dominant hot path.
`natToLeBytes`, `leBytesToNat`, `divCeil`: ≤ 3 calls each → combined impact < 0.01% of workload; skipped.
Post-removal: `range`/`revRange` deleted from `src/internal/utils.mo`; functions no longer exist.

---

### `src/internal/BitBuffer.mo`

Bit-level LSB-first read/write buffer. Central to every encode/decode path.
Most hot operations: `addBits`, `readBits`, `byteAt`, `ensureCapacity`.

- [x] **Baseline measured** — 2026-05-20T13:16:25Z (10 KiB workload, 62 473 marks)
- [x] `getPos` — inlined at `getBit` and `getBits` call sites; **−32% instrs and −32% heap per read call; −37 MB final heap for 10 KiB input**
- [x] `ensureCapacity` — hoist out of `addBits` loop (called ~2× per `addBits`; ~19 719 calls vs ~10 259 `addBits` calls)
- [-] `getByte` / `getBits` — byte-aligned fast path (direct array read when offset is byte-aligned)
- [-] `addBits` — replace `2**take` / `%` / `/=` bignum ops with `Nat8` bit ops in inner loop
- [-] Evaluate replacing `[var Nat8]` backing store with a tighter representation

**Notes:** Baseline perf run: `scripts/output/perf-bitbuffer-2026-05-20T13-16-25-550Z.json`.
Post-fix #1 run: `scripts/output/perf-bitbuffer-2026-05-20T13-22-43-922Z.json`.
Surprise: `getPos` was called 10 825× per 10 KiB — same frequency as `getByte`/`getBits` (one allocation per call).
Surprise: `ensureCapacity` fires ~1.9× per `addBits` call (inside the per-byte-boundary loop).

---

### `src/BitReader.mo`

Forward-only bit reader wrapping a `[Nat8]`. Used by every decoder.

- [x] **Baseline measured** — 2026-05-21T05-59-06Z (10 KiB workload, 54 462 marks)
- [x] `isValid` — cache readable upper bound (`available`) as a class field; inline bounds check at every call site; **−59% total instrs, −56% final heap for 10 KiB input**
- [-] `readBit` / `readBits` — eliminate redundant bounds checks: already addressed by inlining `isValid`
- [-] `readByte` / `readBytes` — too few calls (≤5) per 10 KiB; impact negligible
- [-] `getBitsFast` fast-path in BitBuffer (single-byte / two-byte inline) — **attempted, reverted**; see Notes
- [-] Evaluate lazy vs. eager buffering strategy — not warranted after isValid fix

**Notes:**
Baseline: `isValid` = 27 215 calls, 91 753 avg instrs/call, 5 522 B heap/call — dominant hot path.
`peekBits` = 16 966 calls; `skipBits` = 10 238 calls. Both call `isValid` on every invocation.
Root cause: `isValid` did `bitbuffer.bitSize() - offset - tailBits`, which is 3 chained Nat
subtractions + a method-call indirection, allocating on every read. Fix: cache
`available = bitbuffer.bitSize() - tailBits` as a class field; maintain it in `addBytes`,
`clearRead`, `hideTailBits`, and `clear`. Inline check becomes `n + offset > available` — one
Nat addition, no heap allocation, no function call.
Post-fix baseline: `peekBits` = 59 874 avg instrs/call, 3 527 B heap/call.

**getBitsFast finding:** Implemented single-byte and two-byte inline fast paths in `BitBuffer` to
eliminate the `getBits` loop for the common DEFLATE peek case. Result: −0.8% instrs, −0.06% heap.
Conclusion: Motoko on IC stores small `Nat` values as tagged immediate integers (no heap
allocation), so the `getBits` loop was already cheap. The remaining ~3 500 B/call in the
`peekBits` interval comes from the calling code between marks (Huffman decoder body: table
lookup, `value % 32`, `value / 32`, loop overhead) — not from `BitBuffer.getBits` itself.
Further reductions require optimising `src/Huffman/Decoder.mo` (Layer 1).

---

### `src/internal/CircularBuffer.mo`

Fixed-capacity O(1) ring buffer for the LZSS sliding window (32 KiB).

- [x] **Baseline measured** — 2026-05-20T15:10:10Z (10 KiB workload, 61 477 marks)
- [-] `push` — replace modulo wraparound with conditional branch; **−0.044% instrs (negligible)**
- [x] `clear` — O(1) reset (only `head := 0; count := 0`) vs. sweep all slots; **−19.3% avg_delta, −3.47M instrs max_delta (accepted)**
- [-] `get` — profile index computation vs. linear scan alternatives
- [-] Evaluate whether Prim.Array_init inlining is necessary

**Notes:**
Tested Candidate 1 (modulo→branch wrap on push/get/popFront): −60 to −120 instrs avg per call, cumulative −0.047%. **Decision: too small, skip.**
Tested Candidate 3 (clear() O(1)): Reduces avg_delta from 9,061,462 to 7,310,982 instrs (−1.75M), min from 63,661 to 36,158 (−27K), max from 18,059,263 to 14,585,806 (−3.47M). **Decision: accept; committed 2026-05-20.**
Candidate 2 (unchecked access paths) not tested; deferred pending use-site refactoring in LZSS encoder.

---

### `src/internal/CRC32.mo`

Single-pass 32-bit checksum over `[Nat8]`.

- [x] **Baseline measured** — 2026-05-21T10-22-27Z (10 KiB workload, 20 488 marks)
- [x] `update` — rewrite to process `data` directly in 8-byte chunks, bypassing per-byte staging buffer; **−93% total instrs, −15× speedup; `updateByte` calls eliminated entirely**
- [-] `updateByte` — intentionally retained as public API
- [-] Replace table-driven lookup — already uses slicing-by-8 (8×256 table); optimal for Motoko/Wasm
- [-] `Nat32` intermediate boxing in `singleSlicingUpdateFromData` — minor; not warranted after bulk-path fix

**Notes:**
Baseline: `updateByte` = 20 480 calls, 33 979 avg instrs/call, 2 106 B heap/call — dominant hot path.
Root cause: `update` routed every byte through `updateByte`, which staged bytes one-at-a-time,
fired `input_size >= INIT_SIZE` checks on every byte, and ran a shift loop.
Fix: fast path in `update` walks `data` in 8-byte strides via `singleSlicingUpdateFromData`,
reading directly from the immutable array. Slow path (buffer has leftover bytes from prior call)
fills to 8, flushes, then re-enters the fast path.
Post-fix: `update` = 2 marks per 10 KiB workload; `updateByte` retained as public API; ~47M total instrs vs ~697M.
Post-fix perf run: `scripts/output/perf-crc32-2026-05-21T10-44-25-774Z.json`; `update(10 KiB)` = ~2.2M instrs (delta `checksum:update → checksum:finish`).

---

## Layer 1 — Core Algorithms

### Huffman

#### `src/Huffman/Common.mo`

Shared types and helpers: `reverseCodeBits`, `restoreHuffmanCodes`.

- [x] **Baseline measured** — 2026-05-21 (100 KiB workload, `perf-huffman-2026-05-21T11-29-07-926Z.json`)
- [-] `reverseCodeBits` — SWAR 16-bit bit-parallel reverse attempted (Phase 3); −851 instrs/call but only 636 calls total ≈ negligible; **reverted**
- [-] `restoreHuffmanCodes` — 318 calls per workload; not hot enough to warrant change

**Notes:** `reverseCodeBits` is called only 636×/100 KiB. Even a 100% speedup moves the overall workload by < 0.3%. Not worth further investment.

---

#### `src/Huffman/Encoder.mo`

Builds a Huffman encoder from bit-widths or symbol frequencies.

- [x] **Baseline measured** — 2026-05-21 (100 KiB workload): `encode` = 102 243 calls, 54 045 avg instrs, 3 104 B heap
- [-] `encode` assert — changed to scalar field check (Phase 1A, kept); −70 instrs/call, negligible in practice
- [-] `fromFrequencies` — construction path; 4 calls per workload; not hot
- [-] Tree traversal / `tupleCompare` — not hot enough to warrant change

**Notes:** `encode` is hot (102 K calls) but its ~54 K instrs/call cost is dominated by the `BitBuffer.addBits` callee (Layer 0). No Huffman-layer change can meaningfully reduce this without optimising the primitive.

---

#### `src/Huffman/Decoder.mo`

Decodes Huffman-coded bit streams.

- [x] **Baseline measured** — 2026-05-21 (100 KiB workload): `decode` = 102 243 calls, 57 047 avg instrs, 3 318 B heap
- [-] `decode` — `?Nat min_bitwidth` → `Nat` sentinel (Phase 2A): IC represents small `?Nat` as tagged immediate; 0 heap savings, −85 instrs; **reverted**
- [-] `decodeSymbol` trap method to avoid `#ok`/`#err` overhead (Phase 2B): −24 B/call; **reverted as negligible**
- [-] `setMapping` loop — stride walk to eliminate per-iteration Nat16 conversions (Phase 4): `2 ** bitwidth` exponentiation costs more than the ops it replaced; **+7% regression; reverted**
- [-] Evaluate canonical Huffman LUT — already implemented (flat `[var Nat]` table, O(1) lookup); no algorithm change needed

**Notes:** `decode` cost (~57 K instrs/call) is dominated by `BitReader.peekBits` / `skipBits` (Layer 0). The LUT is already in place; remaining cost is in bit-reader primitives. Further gains require Layer 0 work on `BitReader`.

---

### LZSS

#### `src/LZSS/Encoder/PrefixTable/lib.mo`

65 536-bucket hash table mapping 3-byte prefixes to most-recent positions.
Slot `i` (= b0×256 + b1) holds a `List<(Nat8, Nat)>` mapping the third byte to
the most-recent insertion index.

- [x] **Baseline measured** — 2026-05-21T14-44-47Z (10 KiB pseudo-random; `insert` avg: 285 651 instrs, 17 240 B heap, 10 244 calls)
- [-] Flat 2D array `[var ?([var ?Nat])]` (65 536 outer × 256 inner) — **implemented and reverted**; _worse_ than `List` on random data. Each new (b0, b1) bucket allocates a 256-slot array (≈2 KB). For 10 KiB of random input, ~8 700 unique (b0, b1) pairs × 2 KB = ~17 MB extra vs. `List` at ~192 B per new bucket. insert: +727 instrs (+0.25%), heap +1 665 B (+9.7%). See Notes.
- [x] `insert(bytes:[Nat8], start, len, index)` → `insert(b0, b1, b2, index)` — eliminates transient immutable `[Nat8]` heap allocation at every call site; removes bounds-check trap and index arithmetic inside `insert`. **−514 instrs/call (−0.18%), −56 B heap/call.**
- [-] Bucket eviction strategy — keep only the most-recent match per prefix (single-slot direct-mapped table); would improve performance at the cost of compression ratio; deferred pending ratio impact measurement
- [-] Per-bucket `List` → smaller structure — `List<(Nat8,Nat)>` has Brodnik block overhead even for 1-element buckets; but both alternatives tried so far were worse or negligible; structural change needs a different angle

**Notes:**
Baseline perf runs:

- 100 KiB (hit instruction limit): `perf-lzss-2026-05-21T14-20-55-707Z.json`
- 10 KiB clean baseline (reverted to `List`): `perf-lzss-2026-05-21T14-44-47-545Z.json`
- 10 KiB post-2D-array (reverted): `perf-lzss-2026-05-21T14-40-07-347Z.json`

Why the 2D array was worse: `Prim.Array_init<?Nat>(256, null)` allocates a 256-slot array for every new (b0, b1) pair encountered. Pseudo-random data maximises the number of unique (b0, b1) pairs, so almost every insert created a fresh 256-slot bucket. The `List` approach lazily allocates ~192 B per new bucket, far cheaper at low-n.

Key perf insight: the delta values for `insert`, `encodeByte`, `encodeAsLiterals`, and `getUnsafe` all reflect **one full encoder cycle** (time between consecutive same-tag entries), not the cost of the function body alone. Isolated per-function cost cannot be read from this data; absolute improvements appear proportionally across all method deltas.

---

#### `src/LZSS/Encoder/lib.mo`

Main LZSS encoder: sliding-window match search producing `LzssEntry` streams.

- [x] **Baseline measured** — 2026-05-21T14-44-47Z (10 KiB, `encodeByte` avg: 285 759 instrs, 17 247 B heap, 10 240 calls)
- [x] `cache_buffer: CircularBuffer(2)` → two `?Nat8` scalar fields (`cache0`, `cache1`) — eliminates CircularBuffer object dispatch (size/push/popFront/get) for 2-byte post-match cache. **−33 instrs/call (−0.012%), −18 B heap/call.**
- [-] Match search loop — limit look-back depth; not hot on random data (almost no matches); defer until compressible-data workload is available
- [-] Lazy matching — deferred
- [-] Output `List<LzssEntry>` accumulation — **structural root cause of heap growth**: each `#literal(Nat8)` variant is a heap object; on incompressible data the encoder emits one `LzssEntry` per input byte, driving heap growth at ≈17 KB/byte (net live heap delta per `encodeByte` call). Addressing this requires either reducing the number of emitted objects (batch-literal representation) or a different output strategy.

**Notes:**
Post scalar-args run: `perf-lzss-2026-05-21T15-12-47-512Z.json`
Post scalar-cache run: `perf-lzss-2026-05-21T15-25-32-994Z.json`

Combined effect of both micro-optimisations (#2 + #3 vs. baseline):
`encodeByte`: 285 759 → 285 212 instrs (−547, −0.19%); heap 17 247 → 17 229 B (−18 B).

The ~17 KB/byte net heap growth is not from any one function. It reflects cumulative allocation
across the whole encoder cycle (PrefixTable list nodes, LzssEntry variant objects, List backing
blocks for the output buffer). On pseudo-random data every byte is emitted as a literal, which is
the worst case for object count. Real compressible data emits far fewer entries (one `#pointer`
replaces many `#literal`s), so the heap cost on realistic inputs will be significantly lower.

---

#### `src/LZSS/Decoder.mo`

Expands back-references from an `LzssEntry` list.

- [x] **Baseline measured** — 2026-05-21T15-25-32Z (`decodeEntry` avg: 40 452 instrs, 0 B mem, 10 234 calls per 10 KiB)
- [-] Back-copy loop — at 40 K instrs/call vs. 285 K for the encoder, decoder is ~7× cheaper; low-priority until encoder is improved
- [-] Output `List` building — decoder also grows a heap-allocated output list; same structural concern as encoder

**Notes:**
`decodeEntry` fires 10 234 times for 10 KiB decoded output (≈ one call per output byte).
Total decoder cost ≈ 414 M instrs per 10 KiB. Compare to encoder ≈ 2 920 M instrs — decoder is
already 7× cheaper; optimisation priority is lower.

---

## Layer 2 — DEFLATE

#### `src/Deflate/Symbol.mo`

Maps LZSS entries to DEFLATE length/distance symbols and extra bits.

- [x] **Baseline measured** — 2026-05-21T23-21-50Z (100 KiB, dynamic Huffman, single block)
- [ ] `lengthCode` / `distanceCode` — eliminate per-call tuple heap allocation
- [ ] Replace `switch` arithmetic with precomputed lookup arrays (LENGTH_TABLE / DISTANCE_TABLE already exist on the decode side)

**Notes:**
`lengthCode` = 45,835 calls, **54,967 avg instrs/call, 3,309 B heap/call**.
`distanceCode` = 45,835 calls, **54,911 avg instrs/call, 3,273 B heap/call**.
Together: ~5.04B instrs ≈ **50% of total `flush` cost**; ~302 MB heap across one 100 KiB compress call.
Root cause: both functions return heap-allocated tuple types — `(Nat16, Nat, Nat16)` and `?(Nat, Nat, Nat16)`.
`distanceCode` also contains a `while` loop (up to log₂(distance) iterations) that mutates `Nat` locals, adding box/unbox overhead per pointer symbol.
Primary target: eliminate tuple allocation — pass an output record by ref, use a lookup table, or return a flat scalar encoding.

---

#### `src/Deflate/Block.mo`

Block type management and block boundary encoding.

- [x] **Baseline measured** — 2026-05-21T23-21-50Z (same run as Symbol.mo)
- [-] `blockToNat` — non-unit return type; unpaired in baseline run (`:end` not emitted). Called once; negligible.
- [-] `block` factory — called once at construction; not hot.
- [ ] `Compress.flush` — contains the Huffman `build` + `save` + symbol-emission loop; non-unit callees not yet measured (see HuffmanCodec.mo)

**Notes:**
All block functions have non-unit return types or were called only once. `flush` and `add` were not captured as intervals because `flush` is unit-returning and was found, but `build`/`save` inside it are non-unit and their `:end` marks were not injected. The residual cost inside `Compress.flush` after subtracting `lengthCode`+`distanceCode` (5.04B) from the total `flush` interval (10.17B) is **~5.13B instrs** — attributable to LZSS lookahead drain, Huffman `build`, `save`, and the symbol-emission loop.

---

#### `src/Deflate/HuffmanCodec.mo`

Fixed and Dynamic Huffman codec: `build`, `save`, `load`.

- [x] **Baseline measured** — 2026-05-21T23-21-50Z (same run; unpaired — non-unit returns)
- [ ] Dynamic `build` — frequency counting + two `HuffmanEncoder.fromFrequencies` calls; cost unknown (unpaired)
- [ ] `save` — writes HLIT/HDIST/HCLEN + meta-Huffman tree + RLE code lengths; cost unknown (unpaired)
- [ ] `load` — reads meta-Huffman tree + decode bitwidth sequences; cost unknown (unpaired)
- [ ] Instrument return sites manually (add `:end` marks before each `#ok`/`#err` return) to unlock cost data

**Notes:**
`build`, `save`, `load` all return `Result<...>` — perf.ts did not inject `:end` marks (9 unpaired starts total across the deflate run). The combined cost of `build` + `save` + symbol-encoding loop is embedded in the ~5.13B residual of `Compress.flush`. To isolate these, add manual `Perf.mark()` calls in `HuffmanCodec.mo` before/after each function body, or extend perf.ts's `findReturnSites` to handle `Result`-returning functions.

---

#### `src/Deflate/Encoder.mo`

DEFLATE encoder: converts symbol stream to compressed bit stream.

- [x] **Baseline measured** — 2026-05-21T23-21-50Z
- [ ] Symbol emission loop — `lengthCode`/`distanceCode` called once per symbol; fixing those (Symbol.mo) will directly reduce this
- [ ] BitBuffer interaction — batch writes where symbol + extra bits fit in one call
- [ ] Block flush strategy — tune block-size threshold (currently 1 MiB → single block for 100 KiB workload)

**Notes:**
`encode` (top-level byte feeder): 1 call, **614M instrs** (LZSS + byte accumulation for 100 KiB).
`flush` (final `finish()` call): 1 call, **10,171M instrs** — entire compression step.
Only 1 block flushed for the 100 KiB workload (block_size = 1 MiB in example/compress.mo).
`encodeByte`, `clear`, `finish` are unit-returning but only called 1-2 times; not individually hot.

---

#### `src/Deflate/Decoder.mo`

DEFLATE decoder: reconstructs byte stream from compressed blocks.

- [x] **Baseline measured** — 2026-05-21T23-21-50Z (decoder ran; all functions unpaired)
- [ ] Block loop — reduce redundant state checks
- [ ] Back-reference copy — batch byte writes into CircularBuffer
- [ ] Instrument return sites manually (`decode`, `decodeCompressed`, `finish` all return `Result<>`)

**Notes:**
`decode`, `decodeCompressed`, `load` (HuffmanCodec), `save`: all non-unit return types — `:end` marks not injected. `:start` marks confirmed in the JSONL output (decoder ran after encoder). Decoder cost cannot be isolated without manual `:end` injection or a dedicated decoder-only perf workload.

---

## Layer 3 — Gzip

#### `src/Gzip/Header.mo`

Gzip header encode/decode (RFC 1952).

- [ ] **Baseline measured** (use `bun run perf component=gzip`)
- [ ] `encode` — profile optional-field branches; most headers are default
- [ ] `decode` — fast-path for default-format headers

**Notes:**

---

#### `src/Gzip/Encoder.mo`

Full Gzip encode pipeline: header → DEFLATE → CRC32 → trailer.

- [ ] **Baseline measured**
- [ ] Pipeline allocation — ensure intermediate buffers are sized correctly upfront
- [ ] CRC32 update frequency — batch vs. per-byte

**Notes:**

---

#### `src/Gzip/Decoder.mo`

Full Gzip decode pipeline: header → DEFLATE → CRC32 verification.

- [ ] **Baseline measured**
- [ ] Verification pass — avoid re-scanning output bytes for CRC

**Notes:**

---

## End-to-end baseline

Record the last clean perf run for each component here before any optimization work.
Update these numbers each time a new baseline is established.

| Component | Timestamp            | `avg_delta` instrs                              | `avg_delta` mem (bytes) | `avg_delta` heap (bytes) |
| --------- | -------------------- | ----------------------------------------------- | ----------------------- | ------------------------ |
| huffman   | 2026-05-20T10:06:04Z | —                                               | —                       | —                        |
| gzip      | 2026-05-20T09:17:56Z | —                                               | —                       | —                        |
| deflate   | 2026-05-21T23-21-50Z | 54,967 (`lengthCode`) / 54,911 (`distanceCode`) | 3,311 / 3,274           | 3,309 / 3,273            |
| lzss      | 2026-05-21T14-44-47Z | 285 759 (`encodeByte`)                          | 17 247 (`encodeByte`)   | 17 247 (`encodeByte`)    |

<!-- Fill in per_method deltas from scripts/output/ JSON reports -->

---

## Completed optimizations log

| Date       | Component | File                                  | Change                                                                                                                                                | Δ instrs/call                                                              | Δ heap/call                                | Δ total heap (10 KiB)   | Commit |
| ---------- | --------- | ------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------- | ------------------------------------------ | ----------------------- | ------ |
| 2026-05-20 | bitbuffer | `src/internal/BitBuffer.mo`           | Inline `getPos` at 2 call sites                                                                                                                       | −58 034 (−32%) on `getByte`/`getBits`                                      | −3 464 B (−32%)                            | −37 MB                  | —      |
| 2026-05-21 | utils     | `src/internal/utils.mo` + 8 src files | Remove `range`/`revRange`; inline `while` loops at all 20+ call sites                                                                                 | −48 133 per `range` call (×11 201 calls)                                   | −2 684 B per call                          | ~−30 MB                 | —      |
| 2026-05-21 | bitreader | `src/internal/BitReader.mo`           | Cache `available` field; inline `isValid` bounds check at all 5 call sites                                                                            | −59% total workload instrs; `peekBits` −59% instrs, `skipBits` −59% instrs | `peekBits` −60% heap, `skipBits` −60% heap | −90 MB (161 MB → 71 MB) | —      |
| 2026-05-21 | crc32     | `src/internal/CRC32.mo`               | Rewrite `update` to process `[Nat8]` in direct 8-byte strides; remove `updateByte` + dead fields                                                      | −93% total instrs (697M → 47M); `updateByte` 20 480 calls → 0              | 2 106 B/byte → ~0                          | −35 MB (48 MB → 13 MB)  | —      |
| 2026-05-21 | lzss      | `src/LZSS/Encoder/PrefixTable/lib.mo` | `insert(bytes:[Nat8], start, len, index)` → `insert(b0, b1, b2, index)`; eliminates transient `[Nat8]` allocation and bounds-check at every call site | −514 instrs/call (−0.18%)                                                  | −56 B/call (−0.32%)                        | −574 KB (10 KiB run)    | —      |
| 2026-05-21 | lzss      | `src/LZSS/Encoder/lib.mo`             | `cache_buffer: CircularBuffer(2)` → two `?Nat8` scalar fields; removes object dispatch for 2-byte post-match cache                                    | −33 instrs/call (−0.012%)                                                  | −18 B/call                                 | −184 KB (10 KiB run)    | —      |
