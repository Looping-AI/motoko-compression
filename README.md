# motoko-compression

A Motoko compression library for the [Internet Computer](https://internetcomputer.org/), implementing **Gzip**, **DEFLATE**, **LZSS**, and **Huffman** on top of `mo:core`.

## Status

| Algorithm | Encode | Decode | Import                          |
| --------- | ------ | ------ | ------------------------------- |
| Gzip      | ✅     | ✅     | `mo:motoko-compression/Gzip`    |
| DEFLATE   | ✅     | ✅     | `mo:motoko-compression/Deflate` |
| LZSS      | ✅     | ✅     | `mo:motoko-compression/LZSS`    |
| Huffman   | ✅     | ✅     | internal building blocks        |

## Installation

```bash
mops add motoko-compression
```

## Gzip quick start

### One-shot round trip

Best for small payloads (≤ 6 MiB input). Keep the encoder and decoder as `transient let`
in your canister — the convenience helpers call `clear()` internally so state never leaks.

```motoko
import Blob "mo:core/Blob";
import Runtime "mo:core/Runtime";
import Text "mo:core/Text";
import Gzip "mo:motoko-compression/Gzip";

// Reuse these across calls — declare as `transient let` in a canister.
let enc = Gzip.EncoderBuilder().build();
let dec = Gzip.Decoder();

let input = Blob.toArray(Text.encodeUtf8("Hello, Internet Computer!"));

let compressed = Gzip.compress(enc, input);

switch (Gzip.decompress(dec, compressed)) {
  case (#ok(output)) assert output.size() == input.size();
  case (#err(msg)) Runtime.trap("decompress failed: " # msg);
};

```

The helpers wrap the low-level API (`encode` → `finish` → `compressed`/`clear` and
`decode` → `finish` → `decompressed`/`clear`) for convenience. Use the low-level API
directly when you need to iterate `chunks()` without the merge allocation.

### Multi-step encode (IC-friendly, large data)

Use when the raw input exceeds the ~6 MiB per-message instruction budget.
Each timer tick feeds exactly `enc.outputChunkSize()` bytes of raw input; the final tick
calls `finish()` to flush the Gzip footer.

```motoko
import Array "mo:core/Array";
import Gzip "mo:motoko-compression/Gzip";

let enc = Gzip.EncoderBuilder().build();

// Each timer run: feed one slice of raw input.
let lo = offset;
let hi = Nat.min(lo + enc.outputChunkSize(), rawData.size());
enc.encode(Array.tabulate<Nat8>(hi - lo, func(i) { rawData[lo + i] }));

// Final timer run once all input is consumed:
enc.finish();
// Read output chunk-by-chunk (no merge allocation):
for (chunk in enc.chunks().vals()) { /* store or forward chunk */ };
// Or as a single array:
let compressed = enc.compressed();
enc.clear();

```

### Resumable decode across messages

Use `start()` + `step()` to spread inflate work across multiple IC messages.
Each `step(#default)` processes up to ~21 MiB of compressed input; output accumulates
internally and is read once `#done` is returned.

```motoko
import Runtime "mo:core/Runtime";
import Gzip "mo:motoko-compression/Gzip";

let dec = Gzip.Decoder();

// Feed all compressed bytes first (one or more decode() calls).
dec.decode(compressed);

// Parse the Gzip header and prepare the deflate decoder.
switch (dec.start()) {
  case (#err(msg)) Runtime.trap("start failed: " # msg);
  case (#ok(_header)) {};
};

// Each timer run:
switch (dec.step(#default)) {
  case (#err(msg)) Runtime.trap("step failed: " # msg);
  case (#ok(#more)) { /* reschedule timer */ };
  case (#ok(#done)) {
    let output = dec.decompressed(); // [Nat8] — or dec.chunks() to avoid merge
    dec.clear();
  };
};

```

Pass `#custom(n)` to `step()` to override the default 21 MiB output budget per tick.

## EncoderBuilder options

| Option                                                     | Effect                                                     |
| ---------------------------------------------------------- | ---------------------------------------------------------- |
| `.lzss(#fast \| #balance \| #best)`                        | Match quality vs. speed                                    |
| `.fixedHuffman()` / `.dynamicHuffman()` / `.autoHuffman()` | Huffman table strategy                                     |
| `.deflateBlockSize(bytes)`                                 | DEFLATE block size (not IC message size)                   |
| `.outputChunkSize(bytes)`                                  | Recommended per-self-call input slice size (default 6 MiB) |

## Performance

Benchmarked on PocketIC via `IC.performanceCounter(1)` (retired instruction count).
Test data is a mixed payload — ⅓ constant (0xAA), ⅓ pseudo-random, ⅓ sequential —
to cover both compressible and incompressible content.
Reproduce locally with `bun run perf component=gzip`.

### Encode — `encode()` per tick · `finish()` once

The default chunk size is 6 MiB per `encode()` call; `finish()` adds ≤ 79 M instructions
(negligible) regardless of payload size.

| Payload | Ticks (6 MiB / tick) | Max instructions / tick | Peak heap |
| ------- | -------------------: | ----------------------: | --------: |
| 1 KiB   |                    1 |                   1.7 M |   < 1 MiB |
| 10 KiB  |                    1 |                  15.9 M |   < 1 MiB |
| 1 MiB   |                    1 |                   2.5 B |   ~17 MiB |
| 10 MiB  |                    2 |                  17.0 B |   ~35 MiB |
| 80 MiB  |                   14 |                  31.2 B |   ~60 MiB |

Worst-case encode rate (incompressible data): ≈ 5.5 B instructions / MiB.

### Decode — `start()` once · `step(#default)` per tick

`start()` concatenates all compressed input into one flat buffer for the BitReader —
this is where peak heap is incurred. `step(#default)` then processes ≤ 21 MiB of
output per tick.

| Payload | `start()` instructions | Step ticks (21 MiB / tick) | Max instructions / tick | Peak heap |
| ------- | ---------------------: | -------------------------: | ----------------------: | --------: |
| 1 KiB   |                  4.1 M |                          1 |                   777 K |   < 1 MiB |
| 10 KiB  |                  4.7 M |                          1 |                   6.9 M |   < 1 MiB |
| 1 MiB   |                   79 M |                          1 |                   701 M |   ~16 MiB |
| 10 MiB  |                  754 M |                          1 |                  9.97 B |  ~105 MiB |
| 80 MiB  |                  6.0 B |                          4 |                  25.3 B |  ~235 MiB |

Decode rate: ≈ 1.2 B instructions / MiB of output per step tick.

> **IC budget:** no single operation at any measured size exceeds the 40 B instruction
> limit with default settings.
>
> **Memory:** `start()` holds the entire compressed stream as a flat array until the
> last `step()` call completes. At 80 MiB input this peaks at ~235 MiB heap. Attempting
> 100 MiB exceeds the default 3 GiB Wasm memory cap — raise your canister's
> `memory_allocation` or reduce payload size per stream.

## Example canisters

- `example/compress.mo` — timer-driven job queue: streaming encode + resumable decode across messages
- `example/external-decompress.mo` — upload an externally-produced gzip stream in batches, decode with `finish()`
- `example/compress-images.mo` — image store using independent per-chunk gzip streams

## Development

```bash
bun run format:check
bun run lint
mops test
bun run test:build
bun run test
```

Subsets: `bun run test:correctness` · `test:interop` · `test:timing` · `test:image`

### Performance tracing

```bash
bun run perf component=<name>   # huffman | deflate | gzip | lzss
```

Instruments sources transiently, runs workloads on PocketIC, and writes reports to `scripts/output/`. Instruction counts via `IC.performanceCounter(1)`.

## Resources

- [ARCHITECTURE.md](ARCHITECTURE.md) — streaming model, layer overview, encode/decode paths
- [DEFLATE RFC 1951](https://www.rfc-editor.org/rfc/rfc1951)
- [Gzip RFC 1952](https://www.rfc-editor.org/rfc/rfc1952)
- [zlib manual](https://www.zlib.net/manual.html)
- [zlib/gzlib.c](https://github.com/madler/zlib/blob/master/gzlib.c)
- [zlib/deflate.c](https://github.com/madler/zlib/blob/master/deflate.c)
- [zlib/inflate.c](https://github.com/madler/zlib/blob/master/inflate.c)
- [Original fork: edjcase/motoko_compression](https://github.com/edjcase/motoko_compression)

## License

MIT
