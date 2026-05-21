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

- [ ] **Baseline measured**
- [ ] `readBit` / `readBits` — inline shift arithmetic, eliminate redundant bounds checks
- [ ] `readByte` / `readBytes` — fast-path when bit cursor is byte-aligned
- [ ] Evaluate lazy vs. eager buffering strategy

**Notes:**

---

### `src/internal/CircularBuffer.mo`

Fixed-capacity O(1) ring buffer for the LZSS sliding window (32 KiB).

- [x] **Baseline measured** — 2026-05-20T15:10:10Z (10 KiB workload, 61 477 marks)
- [-] `push` — replace modulo wraparound with conditional branch; **−0.044% instrs (negligible)**
- [x] `clear` — O(1) reset (only `head := 0; count := 0`) vs. sweep all slots; **−19.3% avg_delta, −3.47M instrs max_delta (accepted)**
- [ ] `get` — profile index computation vs. linear scan alternatives
- [ ] Evaluate whether Prim.Array_init inlining is necessary

**Notes:**
Tested Candidate 1 (modulo→branch wrap on push/get/popFront): −60 to −120 instrs avg per call, cumulative −0.047%. **Decision: too small, skip.**
Tested Candidate 3 (clear() O(1)): Reduces avg_delta from 9,061,462 to 7,310,982 instrs (−1.75M), min from 63,661 to 36,158 (−27K), max from 18,059,263 to 14,585,806 (−3.47M). **Decision: accept; committed 2026-05-20.**
Candidate 2 (unchecked access paths) not tested; deferred pending use-site refactoring in LZSS encoder.

---

### `src/internal/CRC32.mo`

Single-pass 32-bit checksum over `[Nat8]`.

- [ ] **Baseline measured**
- [ ] Replace table-driven lookup with the standard 256-entry precomputed table (if not already)
- [ ] Ensure loop body avoids unnecessary boxing of Nat32 intermediate values

**Notes:**

---

## Layer 1 — Core Algorithms

### Huffman

#### `src/Huffman/Common.mo`

Shared types and helpers: `reverseCodeBits`, `restoreHuffmanCodes`.

- [ ] **Baseline measured**
- [ ] `reverseCodeBits` — use bit-parallel reverse or precomputed 8-bit table
- [ ] `restoreHuffmanCodes` — profile sort step; consider radix sort for small alphabets

**Notes:**

---

#### `src/Huffman/Encoder.mo`

Builds a Huffman encoder from bit-widths or symbol frequencies.

- [ ] **Baseline measured** (use `bun run perf component=huffman`)
- [ ] `fromFrequencies` — heap-sort priority queue vs. current structure
- [ ] Tree traversal — eliminate List allocations in canonical-code assignment
- [ ] `tupleCompare` — ensure it is inlined by the compiler

**Notes:**

---

#### `src/Huffman/Decoder.mo`

Decodes Huffman-coded bit streams.

- [ ] **Baseline measured**
- [ ] `fromBitwidths` — profile table construction cost
- [ ] Inner decode loop — look-up table (LUT) decode vs. tree traversal
- [ ] Evaluate canonical Huffman LUT (256-entry, O(1) per symbol)

**Notes:**

---

### LZSS

#### `src/LZSS/Encoder/PrefixTable/lib.mo`

65 536-bucket hash table mapping 3-byte prefixes to most-recent positions.

- [ ] **Baseline measured** (use `bun run perf component=lzss`)
- [ ] `insert` — reduce allocation of `List` cons cells per collision
- [ ] Bucket eviction strategy — keep only N most-recent matches per prefix
- [ ] Evaluate flat array or chained array representation instead of `List`

**Notes:**

---

#### `src/LZSS/Encoder/lib.mo`

Main LZSS encoder: sliding-window match search producing `LzssEntry` streams.

- [ ] **Baseline measured**
- [ ] Match search loop — limit look-back depth when `PrefixTable` has many hits
- [ ] Lazy matching — try next byte before committing to current match
- [ ] Output `List` accumulation — consider building in reverse then reversing once

**Notes:**

---

#### `src/LZSS/Decoder.mo`

Expands back-references from an `LzssEntry` list.

- [ ] **Baseline measured**
- [ ] Back-copy loop — avoid re-indexing `CircularBuffer` per byte; batch copies
- [ ] Output `List` building — minimize cons allocations

**Notes:**

---

## Layer 2 — DEFLATE

#### `src/Deflate/Symbol.mo`

Maps LZSS entries to DEFLATE length/distance symbols and extra bits.

- [ ] **Baseline measured** (captured within `bun run perf component=deflate`)
- [ ] `lengthCode` / `distanceCode` — verify static tables are compiled as constants
- [ ] Replace `switch` chains with binary-search or precomputed lookup arrays

**Notes:**

---

#### `src/Deflate/Block.mo`

Block type management and block boundary encoding.

- [ ] **Baseline measured**
- [ ] `blockToNat` — trivial, likely already optimal
- [ ] `block` factory — ensure no closure overhead per block

**Notes:**

---

#### `src/Deflate/HuffmanCodec.mo`

Fixed and Dynamic Huffman codec: `build`, `save`, `load`.

- [ ] **Baseline measured**
- [ ] Dynamic `build` — profile frequency counting pass
- [ ] `save` — minimize BitBuffer write calls (batch multi-bit writes)
- [ ] `load` — optimize decoding-tree reconstruction from bit-widths

**Notes:**

---

#### `src/Deflate/Encoder.mo`

DEFLATE encoder: converts symbol stream to compressed bit stream.

- [ ] **Baseline measured**
- [ ] Symbol emission loop — reduce per-symbol dispatch overhead
- [ ] BitBuffer interaction — batch writes where symbol + extra bits fit in one call
- [ ] Block flush strategy — tune block-size threshold

**Notes:**

---

#### `src/Deflate/Decoder.mo`

DEFLATE decoder: reconstructs byte stream from compressed blocks.

- [ ] **Baseline measured**
- [ ] Block loop — reduce redundant state checks
- [ ] Back-reference copy — batch byte writes into CircularBuffer

**Notes:**

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

| Component | Timestamp            | `avg_delta` instrs | `avg_delta` mem (bytes) | `avg_delta` heap (bytes) |
| --------- | -------------------- | ------------------ | ----------------------- | ------------------------ |
| huffman   | 2026-05-20T10:06:04Z | —                  | —                       | —                        |
| gzip      | 2026-05-20T09:17:56Z | —                  | —                       | —                        |
| deflate   | —                    | —                  | —                       | —                        |
| lzss      | —                    | —                  | —                       | —                        |

<!-- Fill in per_method deltas from scripts/output/ JSON reports -->

---

## Completed optimizations log

| Date       | Component | File                                  | Change                                                                | Δ instrs/call                            | Δ heap/call       | Δ total heap (10 KiB) | Commit |
| ---------- | --------- | ------------------------------------- | --------------------------------------------------------------------- | ---------------------------------------- | ----------------- | --------------------- | ------ |
| 2026-05-20 | bitbuffer | `src/internal/BitBuffer.mo`           | Inline `getPos` at 2 call sites                                       | −58 034 (−32%) on `getByte`/`getBits`    | −3 464 B (−32%)   | −37 MB                | —      |
| 2026-05-21 | utils     | `src/internal/utils.mo` + 8 src files | Remove `range`/`revRange`; inline `while` loops at all 20+ call sites | −48 133 per `range` call (×11 201 calls) | −2 684 B per call | ~−30 MB               | —      |
