# PLAN.md — motoko-compression Migration

Incremental migration of [edjcase/motoko_compression](https://github.com/edjcase/motoko_compression) into this repo, replacing `mo:base` with `mo:core`, targeting `moc = "1.7.0"`, with full test coverage at every phase.

Work through phases in order. Each phase ends with `mops test` passing before the next begins.

---

## Status Legend

- `[ ]` Not started
- `[~]` In progress
- `[x]` Complete

---

## Phase 0 — Housekeeping

- [x] Create `README.md`
- [x] Update `AGENTS.md`
- [x] Create `PLAN.md`

---

## Phase 1 — Internal Primitives [x]

**Decision:** All external mops packages (`bitbuffer@1`, `itertools@0`, `circular-buffer@0`, `buffer-deque@0`) were audited and **none are needed**. All required functionality is implemented directly in Motoko using `mo:core` only — no additional entries in `mops.toml`.

**External packages evaluated and replaced:**

| Package             | Used for                                         | Decision                                                         |
| ------------------- | ------------------------------------------------ | ---------------------------------------------------------------- |
| `base@0`            | Array, Buffer, Iter, Nat8/16/32, Hash, etc.      | Removed — all migrated to `mo:core`                              |
| `bitbuffer@1`       | Bit-level read/write buffer                      | Replaced by `src/internal/BitBuffer.mo` (custom, `mo:core` only) |
| `itertools@0`       | `RevIter`, `Itertools.equal`, `Itertools.chunks` | Replaced by helpers in `src/utils.mo` + `mo:core/Iter`           |
| `circular-buffer@0` | Rolling window buffer for LZSS                   | Replaced by `src/internal/CircularBuffer.mo` (custom)            |
| `buffer-deque@0`    | Deque operations                                 | Replaced by `mo:core/Deque`                                      |

**Files created:**

- [x] `src/utils.mo` — iterator helpers: `range(lo, hi)` (exclusive), `revRange(hi, lo)`, `iterEqual`
- [x] `src/internal/BitBuffer.mo` — LSB-first bit buffer; `[var Nat8]` auto-doubling array; API: `new`, `addBit`/`getBit`, `addBits`/`getBits`, `addByte`/`getByte`, `addBytes`/`getBytes`, `byteAlign`, `dropBits`, `clear`, `bytes`
- [x] `src/internal/CircularBuffer.mo` — fixed-capacity `Nat8` ring buffer for LZSS sliding window (default 32 768 slots); API: `capacity`, `size`, `isFull`, `push`, `get`, `values`, `clear`

**Test files created:**

- [x] `tests/Utils.Test.mo` — 24 tests
- [x] `tests/internal/BitBuffer.Test.mo` — 38 tests
- [x] `tests/internal/CircularBuffer.Test.mo` — 30 tests

**Total: 92 tests passing**

---

## Phase 2 — Utils expansion + CRC32

**Note:** `src/utils.mo` and `tests/Utils.Test.mo` already exist from Phase 1 (iterator helpers). This phase **expands** `src/utils.mo` with the functions from the [edjcase source](https://github.com/edjcase/motoko_compression/blob/main/src/utils.mo) and adds the CRC32 module.

**File to expand:**

- `src/utils.mo` — add: `div_ceil`, `nat_to_le_bytes`, `le_bytes_to_nat`, `bytes_to_nat`, `array_equal`, `nat8_to_32`, `nat8_to_16`

**File to create:**

- `src/libs/CRC32.mo` — CRC32 checksum (IEEE polynomial); source: [src/libs/CRC32.mo](https://github.com/edjcase/motoko_compression/blob/main/src/libs/CRC32.mo)

**Key migration work:**

- Replace all `mo:base@0/*` imports with `mo:core/*` equivalents
- `Hash.Hash` → `Nat32` (mo:core drops the Hash type alias)
- No `mo:itertools` needed — use `mo:core/Iter` and existing `Utils.range` / `Utils.revRange`

**Test files:**

- `tests/Utils.Test.mo` — already exists (24 tests for Phase 1 helpers); **expand** with tests for the new functions
- `tests/CRC32.Test.mo` — create new

**Test coverage required:**

- `utils.mo` additions: `div_ceil`, `nat_to_le_bytes`, `le_bytes_to_nat`, `bytes_to_nat`, `array_equal`, `nat8_to_32`, `nat8_to_16`; edge cases: zero, max `Nat8`, empty arrays, multi-byte roundtrips
- `CRC32.mo`: known vectors (`[]` → `0x00000000`, `[0x61]` → `0xE8B7BE43`), empty input, single byte, multi-byte, `reset()` behaviour, `updateByte` vs `update` equivalence

**Verify:** `mops test`

---

## Phase 3 — BitReader [x]

**Files created:**

- [x] `src/BitReader.mo` — bit-level reader backed by `src/internal/BitBuffer.mo`
- [x] `tests/BitReader.Test.mo` — 29 sync tests
- [x] `tests/helpers/TrapCanister.mo` — helper actor class for trap testing
- [x] `tests/BitReaderTraps.Test.mo` — 4 replica tests for out-of-bounds traps

**Files modified:**

- [x] `src/internal/BitBuffer.mo` — `Prim.trap` → `Runtime.trap` (added `import Runtime "mo:core/Runtime"`)
- [x] `src/internal/CircularBuffer.mo` — `Prim.trap` → `Runtime.trap` (added `import Runtime "mo:core/Runtime"`)

**Key migration decisions:**

- `mo:core/Debug` has no `trap` function (only `print` and `todo`). Used `Runtime.trap(msg)` from `mo:core/Runtime` for all synchronous error paths.
- `throw` is async-only in Motoko; `Runtime.trap` is the only option for sync bounds-checking.
- Three API improvements over the original:
  1. `peekByte()` — removed dead `nbits < 8` branch (unreachable after `is_valid(8)` guard)
  2. `peekBytes(n)` — replaced mutate-then-restore tabulate with `bitbuffer.getBytes(offset, n)` directly
  3. `readBytes(n)` — uses `bitbuffer.getBytes(offset, min_bytes)` + `offset += min_bytes * 8` (no side-effectful tabulate)

**Trap testing approach:**

- `expect.call(fn).reject()` only catches `#canister_reject` (thrown errors); it cannot catch `#canister_error` (traps). The `trap()` method in `mo:test` is commented out as "unable to catch".
- Pattern used: deploy a `persistent actor class TrapCanister` that wraps each trapping sync call in a public `async` method. From the replica test, call each method inside a `try/catch` and check `Error.code(err) == #canister_error`.
- Cycles: the mops test replica actor requires `(with cycles = 10_000_000_000_000)` (10 trillion) to instantiate a helper canister. 1 trillion is not enough — results in `install-code-not-enough-cycles`.

**Total new tests: 33** (29 sync + 4 replica)

**Verify:** `mops test` — all 6 files passing

---

## Phase 4 — Huffman [x]

**Files created:**

- [x] `src/Huffman/Common.mo` — `Code` type, `reverseCodeBits`, `restore_huffman_codes`, `BuilderInterface`
- [x] `src/Huffman/Encoder.mo` — build Huffman codes from symbol frequencies
- [x] `src/Huffman/Decoder.mo` — decode Huffman-encoded bit streams

**Key migration decisions:**

- `mo:base/Buffer.Buffer<T>` → `mo:core/List` (mutable growable array). `List.get` returns `?T` — unwrap inline with `else Runtime.unreachable()`.
- `mo:base/Heap` → `mo:core/PriorityQueue` with inverted compare. PriorityQueue is max-first; inverting the compare function restores min-heap semantics.
- `Prelude.unreachable()` → `Runtime.unreachable()` (exists in mo:core/Runtime).
- `Array.init<T>` → `Prim.Array_init<T>`. `Array.freeze` → `Array.fromVarArray` (mo:core).
- `Itertools.enumerate` → `Iter.enumerate` (same API in mo:core).
- `Itertools.range(a, b)` is **exclusive** `[a, b)` — same as `Utils.range(a, b)`.
- `Iter.range(a, b)` from **mo:base** is **inclusive** `[a, b]` → `Utils.range(a, b + 1)`.
- Drop dead import `nat8_to_16` from Common (never used in body).
- Remove redundant `assert` before `#err` in Encoder.Builder.setMapping.
- Fix typo `min_bidwidth` → `min_bitwidth` in Decoder.
- Simplify `% (2 ** 5)` → `% 32` and `/ (2 ** 5)` → `/ 32` in Decoder.

**Test file:** `tests/Huffman.Test.mo` — 30 sync tests across 5 suites

**Verify:** `mops test` — all 7 files passing

---

## Phase 5 — LZSS

**Files to create:**

- `src/LZSS/Common.mo` — `LzssEntry`, `CompressionLevel`, constants (`MATCH_WINDOW_SIZE`, `MATCH_MAX_SIZE`)
- `src/LZSS/Encoder/PrefixTable/HashValueTrie.mo`
- `src/LZSS/Encoder/PrefixTable/HashValueTrieMap.mo`
- `src/LZSS/Encoder/PrefixTable/lib.mo`
- `src/LZSS/Encoder/lib.mo` — stateful `Encoder` class
- `src/LZSS/Decoder.mo` — `Decoder` class and `decode` function
- `src/LZSS/lib.mo` — public facade (`encode`, `decode`, re-exports)

**Source reference:**

- [src/LZSS/](https://github.com/edjcase/motoko_compression/tree/main/src/LZSS)

**Key migration work:**

- Replace all `mo:base@0/*` imports with `mo:core/*`
- `TrieMap` / hash map usage — audit against `mo:core/Map`
- `Buffer.Buffer` → `mo:core/Buffer`

**Test files:** `tests/LZSS/Encoder.Test.mo`, `tests/LZSS/PrefixTable.Test.mo`

**Test coverage required:**

- `encode` / `decode` round-trip: short string, long repeated string, random bytes, empty input, single byte
- Compression levels: `#none`, `#fast`, `#balance`, `#best` — verify `#best` produces smaller or equal output vs `#fast`
- `#pointer` entries reference valid previous positions (offset within window, length within `MATCH_MAX_SIZE`)
- `#literal` entries pass through unchanged
- PrefixTable: insert, lookup (found / not found), window eviction, hash collision handling

**Verify:** `mops test`

---

## Phase 6 — Deflate

**Files to create:**

- `src/Deflate/Symbol.mo` — `Symbol` type (literal/length/distance/end-of-block)
- `src/Deflate/Block.mo` — DEFLATE block types (stored, fixed Huffman, dynamic Huffman)
- `src/Deflate/Encoder.mo` — `Encoder` class
- `src/Deflate/Decoder.mo` — `Decoder` class
- `src/Deflate/lib.mo` — public facade (`buildEncoder`, `buildDecoder`, `DeflateOptions`, re-exports)

**Source reference:**

- [src/Deflate/](https://github.com/edjcase/motoko_compression/tree/main/src/Deflate)

**Key migration work:**

- Replace all `mo:base@0/*` imports with `mo:core/*`
- `BitBuffer` / `BitReader` usage — internal cross-module
- Depends on Phases 3 (BitReader), 4 (Huffman), 5 (LZSS)

**Test file:** `tests/Deflate.Test.mo`

**Test coverage required:**

- Stored block mode (no compression): round-trip, empty, max block size
- Fixed Huffman mode: round-trip, known compressed byte sequence
- Dynamic Huffman mode: round-trip, correct code table generation
- `block_size` boundary: data exactly at boundary, data spanning multiple blocks
- `DeflateOptions.lzss = null` vs custom `LzssEncoder` — both paths exercised
- Decoder: truncated input (expect `#err`), corrupt header (expect `#err`)

**Verify:** `mops test`

---

## Phase 7 — Gzip

**Files to create:**

- `src/Gzip/Header.mo` — Gzip header parsing and serialisation
- `src/Gzip/Encoder.mo` — `Encoder` class and `EncoderBuilder`, `EncodedResponse`
- `src/Gzip/Decoder.mo` — `Decoder` class, `DecodedResponse`
- `src/Gzip/lib.mo` — public facade (re-exports, type aliases)

**Source reference:**

- [src/Gzip/](https://github.com/edjcase/motoko_compression/tree/main/src/Gzip)

**Key migration work:**

- Replace all `mo:base@0/*` imports with `mo:core/*`
- CRC32 integration — uses `src/libs/CRC32.mo` for footer checksum
- Depends on Phase 6 (Deflate), Phase 2 (CRC32)

**Test files:** `tests/Gzip/Encoder.Test.mo`, `tests/Gzip/Decoder.Test.mo`

**Test coverage required:**

- Round-trip (encode then decode): empty bytes, single byte, short text, 100 KB repeated pattern
- `EncoderBuilder` defaults and custom options
- `EncodedResponse.chunks` — multiple chunks on large input
- Header: magic bytes (`\x1f\x8b`), compression method (`\x08`), flags, modification time
- CRC32 footer verification — corrupt checksum detected (expect `#err`)
- ISIZE footer — correct uncompressed size modulo 2^32
- Decoder: wrong magic bytes (expect `#err`), truncated stream (expect `#err`), mismatched CRC32 (expect `#err`)
- Chunk-based decode: feed compressed data in multiple small chunks, same result as single-pass

**Verify:** `mops test`

---

## Phase 8 — Public API

**File to update:**

- `src/main.mo` — replace placeholder with clean module re-exports

**Tasks:**

- Expose `Gzip`, `Deflate`, `LZSS` as top-level named imports
- Verify `icp build compression` passes (full compilation check)
- Final `mops test` — all phases green

---

## Optional: TypeScript Cross-Validation (Bun)

If binary-level validation against a reference gzip implementation is needed:

- Set up `bun` runtime with a small TypeScript script
- Use Node.js built-in `zlib` to compress known test vectors
- Compare output bytes with this library's Gzip encoder output
- Integrate as a separate `make validate` step (not part of `mops test`)

Trigger: decide during Phase 7 if there are any correctness concerns with the Gzip footer (CRC32 / ISIZE).

---

## File Map (final state)

```
src/
  main.mo                              ← Phase 8
  utils.mo                             ← Phase 1 (expanded Phase 2)
  BitReader.mo                         ← Phase 3
  internal/
    BitBuffer.mo                       ← Phase 1
    CircularBuffer.mo                  ← Phase 1
  libs/
    CRC32.mo                           ← Phase 2
  Huffman/
    Common.mo                          ← Phase 4
    Encoder.mo                         ← Phase 4
    Decoder.mo                         ← Phase 4
  LZSS/
    Common.mo                          ← Phase 5
    Decoder.mo                         ← Phase 5
    lib.mo                             ← Phase 5
    Encoder/
      lib.mo                           ← Phase 5
      PrefixTable/
        HashValueTrie.mo               ← Phase 5
        HashValueTrieMap.mo            ← Phase 5
        lib.mo                         ← Phase 5
  Deflate/
    Symbol.mo                          ← Phase 6
    Block.mo                           ← Phase 6
    Encoder.mo                         ← Phase 6
    Decoder.mo                         ← Phase 6
    lib.mo                             ← Phase 6
  Gzip/
    Header.mo                          ← Phase 7
    Encoder.mo                         ← Phase 7
    Decoder.mo                         ← Phase 7
    lib.mo                             ← Phase 7

tests/
  Utils.Test.mo                        ← Phase 1 (expanded Phase 2)
  CRC32.Test.mo                        ← Phase 2
  BitReader.Test.mo                    ← Phase 3
  internal/
    BitBuffer.Test.mo                  ← Phase 1
    CircularBuffer.Test.mo             ← Phase 1
  Huffman.Test.mo                      ← Phase 4
  LZSS/
    Encoder.Test.mo                    ← Phase 5
    PrefixTable.Test.mo                ← Phase 5
  Deflate.Test.mo                      ← Phase 6
  Gzip/
    Encoder.Test.mo                    ← Phase 7
    Decoder.Test.mo                    ← Phase 7
```
