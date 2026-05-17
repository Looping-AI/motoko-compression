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

## Phase 1 — Dependency Audit + `mops.toml` Setup

Determine which external mops packages are still needed after replacing `mo:base@0` with `mo:core`.

**Reference repo dependencies to evaluate:**

| Package             | Used for                                                                    | mo:core covers? | Action                              |
| ------------------- | --------------------------------------------------------------------------- | --------------- | ----------------------------------- |
| `base@0`            | Array, Buffer, Iter, Nat8/16/32, Hash, Deque, Order, Debug, Result, Prelude | ✅ Yes          | Remove — migrate to `mo:core`       |
| `bitbuffer@1`       | `BitBuffer` (bit-level buffer), `BitBuffer.getByte`, `BitBuffer.addBytes`   | ❌ No           | Keep — add to `mops.toml`           |
| `itertools@0`       | `RevIter.fromDeque`, `Itertools.equal`, `Itertools.chunks`                  | Partial         | Audit — check `mo:core/Iter` first  |
| `circular-buffer@0` | Rolling window buffer in LZSS                                               | Partial         | Audit — check `mo:core`             |
| `buffer-deque@0`    | Deque operations                                                            | Partial         | Audit — `mo:core/Deque` may suffice |

**Tasks:**

- [ ] Run `mops search bitbuffer` — confirm latest compatible version
- [ ] Run `mops search itertools` — check if a mo:core-compatible version exists
- [ ] Run `mops search circular-buffer` — same check
- [ ] Run `mops search buffer-deque` — same check
- [ ] Add confirmed packages via `mops add <pkg>`
- [ ] Run `mops install` and confirm no errors

---

## Phase 2 — Utils + CRC32

**Files to create:**

- `src/utils.mo` — general utility functions
- `src/libs/CRC32.mo` — CRC32 checksum (IEEE polynomial, slicing-by-8 optimisation)

**Source reference:**

- [src/utils.mo](https://github.com/edjcase/motoko_compression/blob/main/src/utils.mo)
- [src/libs/CRC32.mo](https://github.com/edjcase/motoko_compression/blob/main/src/libs/CRC32.mo)

**Key migration work:**

- Replace all `mo:base@0/*` imports with `mo:core/*` equivalents
- Replace `mo:itertools@0/RevIter` usage (if not available, inline or use `mo:core/Iter`)
- `Hash.Hash` → `Nat32` (mo:core drops the Hash type alias)
- `Buffer.last(buf)` → `buf.get(buf.size() - 1)` if API differs

**Test file:** `tests/Utils.Test.mo`, `tests/CRC32.Test.mo`

**Test coverage required:**

- `utils.mo`: `div_ceil`, `nat_to_le_bytes`, `le_bytes_to_nat`, `bytes_to_nat`, `array_equal`, `nat8_to_32`, `nat8_to_16`; edge cases: zero, max Nat8, empty arrays, multi-byte roundtrips
- `CRC32.mo`: known CRC32 vectors (e.g. `[]` → `0x00000000`, `[0x61]` → `0xE8B7BE43`), empty input, single byte, multi-byte, `reset()` behaviour, `updateByte` vs `update` equivalence

**Verify:** `mops test`

---

## Phase 3 — BitReader

**Files to create:**

- `src/BitReader.mo` — bit-level reader wrapping `mo:bitbuffer@1/BitBuffer`

**Source reference:**

- [src/BitReader.mo](https://github.com/edjcase/motoko_compression/blob/main/src/BitReader.mo)

**Key migration work:**

- Replace `mo:base@0/*` imports with `mo:core/*`
- Keep `mo:bitbuffer@1/BitBuffer` (no core equivalent)
- Verify `BitBuffer` API compatibility with the version added in Phase 1

**Test file:** `tests/BitReader.Test.mo`

**Test coverage required:**

- `readBit` / `peekBit` — single bit, multiple bits, boundary
- `readBits` / `peekBits` — multi-bit reads, correct value reconstruction
- `readByte` / `peekByte` — full byte, boundary
- `readBytes` / `peekBytes` — multi-byte, exact vs over-read
- `skipBits` — advance without reading
- `byteAlign` — alignment padding
- `hideTailBits` / `showTailBits` — tail masking
- `clearRead` / `reset` / `clear` — state reset
- `getPosition` / `setPosition` — seek behaviour
- Trap on out-of-bounds reads (use `expect` trap checks)

**Verify:** `mops test`

---

## Phase 4 — Huffman

**Files to create:**

- `src/Huffman/Common.mo` — `Code` type, `reverseCodeBits`, `restore_huffman_codes`, `BuilderInterface`
- `src/Huffman/Encoder.mo` — build Huffman codes from symbol frequencies
- `src/Huffman/Decoder.mo` — decode Huffman-encoded bit streams

**Source reference:**

- [src/Huffman/Common.mo](https://github.com/edjcase/motoko_compression/blob/main/src/Huffman/Common.mo)
- [src/Huffman/Encoder.mo](https://github.com/edjcase/motoko_compression/blob/main/src/Huffman/Encoder.mo)
- [src/Huffman/Decoder.mo](https://github.com/edjcase/motoko_compression/blob/main/src/Huffman/Decoder.mo)

**Key migration work:**

- Replace all `mo:base@0/*` imports with `mo:core/*`
- `Buffer.sort` API — verify signature against `mo:core/Buffer`
- `Order.Order` → `mo:core/Order`

**Test file:** `tests/Huffman.Test.mo`

**Test coverage required:**

- `reverseCodeBits` — known input/output pairs, zero bitwidth, max bitwidth (15)
- `restore_huffman_codes` — empty bitwidth array (expect `#err`), single symbol, canonical codes, fixed Huffman table (DEFLATE spec), degenerate (all same bitwidth)
- Encoder: frequency array → code table, symbol with zero frequency excluded, uniform distribution
- Decoder: round-trip with encoder output, invalid code (expect `#err`), single-symbol alphabet

**Verify:** `mops test`

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
  utils.mo                             ← Phase 2
  BitReader.mo                         ← Phase 3
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
  Utils.Test.mo                        ← Phase 2
  CRC32.Test.mo                        ← Phase 2
  BitReader.Test.mo                    ← Phase 3
  Huffman.Test.mo                      ← Phase 4
  LZSS/
    Encoder.Test.mo                    ← Phase 5
    PrefixTable.Test.mo                ← Phase 5
  Deflate.Test.mo                      ← Phase 6
  Gzip/
    Encoder.Test.mo                    ← Phase 7
    Decoder.Test.mo                    ← Phase 7
```
