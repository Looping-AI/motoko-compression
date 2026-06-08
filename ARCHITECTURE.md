# Architecture

## Core concepts

### 1. Two usage modes: one-shot and multi-step

The Gzip API has two complementary modes depending on payload size:

- **One-shot helpers** — `Gzip.compress(enc, bytes)`, `Gzip.decompress(dec, bytes)`, `Gzip.compressText`, `Gzip.compressBlob`. Complete in a single canister message. Safe for payloads up to ~6 MiB raw input (encode) or ~21 MiB compressed input (decode).

- **Multi-step (timer-driven)** — `encode()` + `finish()` spread across timer ticks for large encoding; `start()` + repeated `step()` spread across timer ticks for large decoding. Each tick runs inside a fresh IC instruction budget (~40B instructions).

Reuse encoder and decoder instances across calls by declaring them as `transient let` canister fields. One-shot helpers call `clear()` internally so state never leaks between calls.

### 2. Output accumulates internally — no callbacks

There are no streaming callbacks. Both encoder and decoder accumulate output in internal chunk lists:

- **Encoder**: `encode(bytes)` buffers input; `finish()` flushes the final DEFLATE block and Gzip footer. Afterwards read output via `compressed()` (one flat `[Nat8]`) or `chunks()` (the raw `[[Nat8]]` without a merge allocation).

- **Decoder**: `decode(bytes)` buffers compressed input; `finish()` or `start()` + `step()` runs decompression. Afterwards read output via `decompressed()` (one flat `[Nat8]`) or `chunks()` (the raw `[[Nat8]]` without a merge allocation). Call `clear()` to reset.

### 3. Decode is two-phase: `start()` then `step()`

`start()` parses the Gzip header and pre-sizes the output buffer from the ISIZE footer field.
`step(budget)` decompresses at most `budget` bytes of output and returns:

- `#ok(#more)` → reschedule the timer, call `step()` again.
- `#ok(#done)` → CRC32 and ISIZE verified; output is complete in `decompressed()` / `chunks()`.
- `#err(msg)` → stream is corrupt or truncated.

`finish()` is a convenience wrapper that drives `start()` + `step()` to completion in one call (not timer-safe for large streams).

### 4. IC instruction budget

| Operation | Safe limit per call |
| --------- | ------------------- |
| Encoding  | ~6 MiB raw input    |
| Decoding  | ~21 MiB compressed  |

`encoder.outputChunkSize()` (default 6 MiB) is the recommended per-tick input slice size. Pass this value as the amount of raw input to feed per timer callback. `decoder.step(#default)` uses an internal 21 MiB output budget.

## Layer overview

```
Gzip  (RFC 1952 wrapper: header, CRC32, ISIZE)
  └─ Deflate  (RFC 1951: LZ77 + Huffman coding)
       ├─ LZSS  (match finder: #fast | #balance | #best)
       └─ Huffman  (fixed or dynamic code tables)
```

### Source layout

```
src/
  Gzip/
    lib.mo          ← public entry point; re-exports all types + one-shot helpers
    Encoder.mo      ← Gzip encoder class + EncoderBuilder
    Decoder.mo      ← Gzip decoder class (start/step/finish/clear)
    Header.mo       ← RFC 1952 header encode/decode
  Deflate/
    lib.mo          ← Deflate public API (buildEncoder, buildDecoder)
    Encoder.mo      ← Deflate block encoder
    Decoder.mo      ← Deflate block decoder (decodeBounded)
    Block.mo        ← Block type definitions
    CodeTables.mo   ← Fixed and dynamic code table logic
    HuffmanCodec.mo ← Huffman encode/decode
    Symbol.mo       ← Literal/length/distance symbol types
  Huffman/
    Common.mo       ← Shared code length and tree types
    Encoder.mo      ← Huffman tree builder
    Decoder.mo      ← Huffman tree decoder
  LZSS/
    Common.mo       ← CompressionLevel type, shared constants
    Encoder.mo      ← LZ77 match finder (sliding window)
    Decoder.mo      ← LZ77 back-reference expander
  internal/
    BitAccumulator.mo ← Write-only bit packing
    BitBuffer.mo      ← Read-write bit buffer used by Deflate encoder
    BitReader.mo      ← Read-only bit stream over a pre-sized byte array
    CRC32.mo          ← Incremental CRC32 computation
    OutByteBuffer.mo  ← Streaming output byte accumulator
    Perf.mo           ← Profiling probe (used by perf scripts only)
    utils.mo          ← LE/BE byte conversion helpers
```

## Encode path

1. Input bytes → LZSS match finder → literal/pointer stream
2. Literal/pointer stream → Huffman encoder → bit stream
3. Bit stream packed into DEFLATE blocks → Gzip framing appended

Completed DEFLATE blocks drain from `BitBuffer` into the internal chunk list when the buffer exceeds 1 MiB (the `STREAM_FLUSH_THRESHOLD`). This bounds peak memory use during large encodes.

`EncoderBuilder` options map directly to steps 1–3:

| Option                                                     | Affects                            | Default        |
| ---------------------------------------------------------- | ---------------------------------- | -------------- |
| `.lzss(#fast\|#balance\|#best)`                            | Match quality vs. speed (step 1)   | `#balance`     |
| `.fixedHuffman()` / `.dynamicHuffman()` / `.autoHuffman()` | Code table choice (step 2)         | `fixedHuffman` |
| `.deflateBlockSize(bytes)`                                 | DEFLATE block formation (step 2–3) | 32 KiB         |
| `.outputChunkSize(bytes)`                                  | Recommended per-tick input slice   | 6 MiB          |

Note: fixed Huffman is the default because dynamic table computation is expensive at IC instruction rates and rarely yields a meaningful ratio gain over fixed tables at the 32 KiB block size.

## Decode path

1. Compressed bytes buffered via one or more `decode(fragment)` calls.
2. `start()` — concatenates fragments into one `BitReader`, parses the Gzip header, pre-sizes the output buffer from ISIZE.
3. `step(budget)` — decompresses at most `budget` bytes via `decodeBounded`, accumulates output in the internal chunk list, returns `#more` or `#done`.
4. On `#done`, CRC32 and ISIZE are verified; decompressed output is accessible via `decompressed()` or `chunks()` until `clear()` is called.

`step()` is the IC-native path: each call decompresses at most `budget` bytes and returns `#more` or `#done`, letting the canister yield between IC messages without re-uploading data. Pass `#default` to use the internal 21 MiB budget, or `#custom(n)` to override it.

## API quick reference

```motoko
// ── Import ──────────────────────────────────────────────────────────────────
import Gzip "mo:compression/Gzip";

// ── One-shot (small data) ───────────────────────────────────────────────────
let enc = Gzip.EncoderBuilder().build(); // reuse as transient let
let dec = Gzip.Decoder(); // reuse as transient let

let compressed : [Nat8] = Gzip.compress(enc, input);
let compressed : [Nat8] = Gzip.compressText(enc, text);
let compressed : [Nat8] = Gzip.compressBlob(enc, blob);
let result : Result<[Nat8], Text> = Gzip.decompress(dec, compressed);

// ── Multi-step encoding (large data, spread across timer ticks) ─────────────
let enc = Gzip.EncoderBuilder().build();

// Each timer tick: feed exactly enc.outputChunkSize() bytes of raw input.
enc.encode(nextSlice(enc.outputChunkSize()));

// Final tick once all input has been fed:
enc.finish();
let out : [Nat8] = enc.compressed(); // flat merge
let out : [[Nat8]] = enc.chunks(); // no-copy iteration
enc.clear();

// ── Multi-step decoding (large data, spread across timer ticks) ─────────────
let dec = Gzip.Decoder();

dec.decode(compressed); // or multiple fragments
switch (dec.start()) {
  case (#err msg) Runtime.trap(msg);
  case (#ok _) {};
};

// Each timer tick:
switch (dec.step(#default)) {
  // or #custom(n) to override budget
  case (#err msg) Runtime.trap(msg);
  case (#ok(#more)) rescheduleTimer();
  case (#ok(#done)) {
    let out : [Nat8] = dec.decompressed();
    let out : [[Nat8]] = dec.chunks();
    let n : Nat = dec.decompressedSize(); // progress before #done
    dec.clear();
  };
};

```

## Example canisters

| File                                                             | Canister name         | Demonstrates                                                                                                                           |
| ---------------------------------------------------------------- | --------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| [example/compress.mo](example/compress.mo)                       | `compression`         | One-shot compress/decompress + timer-driven job queue for large payloads                                                               |
| [example/compress-images.mo](example/compress-images.mo)         | `image-compression`   | Named image store with transparent Gzip; chunked upload via `beginImageUpload`/`uploadImageChunk`/`finishImageUpload`; async load jobs |
| [example/external-decompress.mo](example/external-decompress.mo) | `external-decompress` | Interoperability test: receives externally-compressed bytes (node:zlib, pako, etc.) and round-trips them through the Motoko decoder    |

### Key pattern: `transient let` for codec singletons

All example canisters declare encoder and decoder as `transient let` fields. This avoids re-allocating internal structures (sliding window, bit buffer) on every call, while ensuring the Motoko compiler does not attempt to serialize them to stable memory on upgrade.

### Pattern comparison

| Pattern                                                                        | When to use                                                                                             |
| ------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------- |
| One-shot (`Gzip.compress` / `Gzip.decompress`)                                 | Payloads ≤ ~6 MiB raw / ~21 MiB compressed; no timer overhead                                           |
| Timer-driven encode (`encode()` per tick, `finish()` at end)                   | Raw input > 6 MiB; each tick feeds one `outputChunkSize()` slice                                        |
| Timer-driven decode (`start()` once, `step()` per tick)                        | Compressed input > 21 MiB; each tick decompresses one `#default` budget chunk                           |
| Chunked upload (`beginImageUpload` / `uploadImageChunk` / `finishImageUpload`) | Payload exceeds the IC ingress limit (~2 MiB); client drives the splitting across separate update calls |

## Test structure

```
tests/
  *.Test.mo                  ← Unit tests (run via `mops test`)
  internal/*.Test.mo         ← Unit tests for internal modules
  helpers/TrapCanister.mo    ← Helper actor for trap-testing
  integration/               ← Integration tests (run via `bun test`)
    gzip-correctness.test.ts ← Round-trip correctness with PocketIC
    gzip-interop.test.ts     ← Interop with node:zlib (external-decompress canister)
    gzip-timing.test.ts      ← Instruction count and timing benchmarks
    image-compression.test.ts← Image store canister end-to-end
    traps.test.ts            ← Trap/error-path coverage
    setup.ts                 ← PocketIC harness setup
    build.ts                 ← Canister build script
```

Run unit tests: `mops test`  
Run integration tests: `bun test`
