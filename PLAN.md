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

| Date       | Component | File                                  | Change                                                                                           | Δ instrs/call                                                              | Δ heap/call                                | Δ total heap (10 KiB)   | Commit |
| ---------- | --------- | ------------------------------------- | ------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------- | ------------------------------------------ | ----------------------- | ------ |
| 2026-05-20 | bitbuffer | `src/internal/BitBuffer.mo`           | Inline `getPos` at 2 call sites                                                                  | −58 034 (−32%) on `getByte`/`getBits`                                      | −3 464 B (−32%)                            | −37 MB                  | —      |
| 2026-05-21 | utils     | `src/internal/utils.mo` + 8 src files | Remove `range`/`revRange`; inline `while` loops at all 20+ call sites                            | −48 133 per `range` call (×11 201 calls)                                   | −2 684 B per call                          | ~−30 MB                 | —      |
| 2026-05-21 | bitreader | `src/internal/BitReader.mo`           | Cache `available` field; inline `isValid` bounds check at all 5 call sites                       | −59% total workload instrs; `peekBits` −59% instrs, `skipBits` −59% instrs | `peekBits` −60% heap, `skipBits` −60% heap | −90 MB (161 MB → 71 MB) | —      |
| 2026-05-21 | crc32     | `src/internal/CRC32.mo`               | Rewrite `update` to process `[Nat8]` in direct 8-byte strides; remove `updateByte` + dead fields | −93% total instrs (697M → 47M); `updateByte` 20 480 calls → 0              | 2 106 B/byte → ~0                          | −35 MB (48 MB → 13 MB)  | —      |
