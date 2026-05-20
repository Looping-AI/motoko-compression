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

- [ ] **Baseline measured** — capture `avg_delta` for each util call site
- [ ] `natToLeBytes` — avoid intermediate allocations
- [ ] `leBytesToNat` / `bytesToNat` — loop unroll or bitshift path
- [ ] `divCeil` — verify compiler constant-folds; otherwise inline at call sites
- [ ] `range` / `revRange` — check if `Iter` wrapper adds overhead vs raw loops

**Notes:** <!-- fill in deltas and commit refs -->

---

### `src/internal/BitBuffer.mo`

Bit-level LSB-first read/write buffer. Central to every encode/decode path.
Most hot operations: `addBits`, `readBits`, `byteAt`, `ensureCapacity`.

- [ ] **Baseline measured**
- [ ] Reduce `ensureCapacity` copy overhead (copy only live bytes, consider doubling strategy)
- [ ] `addBits` — eliminate branch for common single-byte case
- [ ] `readBits` — profile vs. raw bit-shift; avoid boxing intermediate Nat values
- [ ] Evaluate replacing `[var Nat8]` backing store with a tighter representation

**Notes:**

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

- [ ] **Baseline measured**
- [ ] `push` — ensure single modular-index write, no branch
- [ ] `get` — profile index computation vs. linear scan alternatives
- [ ] Evaluate whether Prim.Array_init inlining is necessary

**Notes:**

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

| Date | Component | File | Change | Δ instrs | Δ mem | Δ heap | Commit |
| ---- | --------- | ---- | ------ | -------- | ----- | ------ | ------ |
| —    | —         | —    | —      | —        | —     | —      | —      |
