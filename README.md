# motoko-compression

A Motoko compression library for the [Internet Computer](https://internetcomputer.org/), implementing the **DEFLATE** lossless compression algorithm with **Gzip** format support. Built on `mo:core` and targeting the latest Motoko compiler.

This is a modernised port of [edjcase/motoko_compression](https://github.com/edjcase/motoko_compression) (itself a fork of [NatLabs/deflate.mo](https://github.com/NatLabs/deflate.mo)), migrated to `mo:core` and updated with full test coverage.

## Algorithms

| Algorithm | Encode | Decode |
| --------- | ------ | ------ |
| Gzip      | ✅     | ✅     |
| DEFLATE   | ✅     | ✅     |
| LZSS      | ✅     | ✅     |
| Huffman   | ✅     | ✅     |

## Installation

```bash
mops add compression
```

## Usage

### Importing

```motoko
import Gzip "mo:compression/Gzip";
```

### Compress and decompress small data (≤ 1 MB)

```motoko
import Blob "mo:core/Blob";
import Text "mo:core/Text";
import Gzip "mo:compression/Gzip";

let encoder = Gzip.EncoderBuilder().build();
let decoder = Gzip.Decoder();

let data = Blob.toArray(Text.encodeUtf8("Hello, Internet Computer!"));

// Compress
encoder.encode(data);
let compressed = encoder.finish(); // resets encoder

// Decompress
for (chunk in compressed.chunks.vals()) {
    decoder.decode(chunk);
};
let decompressed = decoder.finish(); // resets decoder

assert decompressed.bytes == data;
```

### Compress and decompress large data (> 1 MB)

Because of the ICP instruction limit per call, large payloads must be chunked across multiple canister calls.

```motoko
import Gzip "mo:compression/Gzip";

shared actor class MyCanister() = self {

    let encoder = Gzip.EncoderBuilder().build();
    let decoder = Gzip.Decoder();

    // Feed one chunk per call
    public shared ({ caller }) func encodeChunk(chunk : [Nat8]) : async () {
        assert caller == Principal.fromActor(self);
        encoder.encode(chunk);
    };

    public shared ({ caller }) func decodeChunk(chunk : [Nat8]) : async () {
        assert caller == Principal.fromActor(self);
        decoder.decode(chunk);
    };

    // Compress an arbitrary-length payload
    public func compress(data : [Nat8]) : async Gzip.EncodedResponse {
        let blockSize = encoder.block_size();
        var i = 0;
        while (i < data.size()) {
            let end = Nat.min(i + blockSize, data.size());
            await encodeChunk(Array.tabulate(end - i, func(j) = data[i + j]));
            i += blockSize;
        };
        encoder.finish()
    };

    // Decompress a previously compressed response
    public func decompress(compressed : Gzip.EncodedResponse) : async [Nat8] {
        for (chunk in compressed.chunks.vals()) {
            await decodeChunk(chunk);
        };
        let response = decoder.finish();
        response.bytes
    };
};
```

### Using raw DEFLATE

```motoko
import Deflate "mo:compression/Deflate";

let options : Deflate.DeflateOptions = {
    block_size = 32_768;
    dynamic_huffman = true;
    lzss = null; // use default LZSS encoder
};

let encoder = Deflate.buildEncoder(options);
let decoder = Deflate.buildDecoder(null);
```

### Using LZSS directly

```motoko
import LZSS "mo:compression/LZSS";

let entries = LZSS.encode(bytes);   // [Nat8] -> Buffer<LzssEntry>
let decoded = LZSS.decode(entries); // Buffer<LzssEntry> -> [Nat8]
```

## API Reference

### `Gzip`

| Symbol             | Description                                                                         |
| ------------------ | ----------------------------------------------------------------------------------- |
| `EncoderBuilder()` | Builder for a Gzip encoder. Call `.build()` to get an `Encoder`.                    |
| `Encoder`          | Class with `.encode([Nat8])`, `.finish() → EncodedResponse`, `.block_size() → Nat`. |
| `Decoder()`        | Gzip decoder. Call `.decode([Nat8])` then `.finish() → DecodedResponse`.            |
| `EncodedResponse`  | `{ chunks : [[Nat8]] }`                                                             |
| `DecodedResponse`  | `{ bytes : [Nat8] }`                                                                |

### `Deflate`

| Symbol                  | Description                                                         |
| ----------------------- | ------------------------------------------------------------------- |
| `buildEncoder(options)` | Returns a `Deflate.Encoder`.                                        |
| `buildDecoder(?Buffer)` | Returns a `Deflate.Decoder`.                                        |
| `DeflateOptions`        | `{ block_size : Nat; dynamic_huffman : Bool; lzss : ?LzssEncoder }` |

### `LZSS`

| Symbol                      | Description                                  |
| --------------------------- | -------------------------------------------- |
| `encode([Nat8])`            | Encodes bytes as a buffer of `LzssEntry`.    |
| `decode(Buffer<LzssEntry>)` | Decodes back to bytes.                       |
| `Encoder`                   | Stateful LZSS encoder class.                 |
| `Decoder`                   | Stateful LZSS decoder class.                 |
| `LzssEntry`                 | `#literal : Nat8` or `#pointer : (Nat, Nat)` |
| `CompressionLevel`          | `#none`, `#fast`, `#balance`, `#best`        |

## Development

### Running tests

Motoko unit tests:

```bash
mops test
```

Integration tests run against real canister WASM on PocketIC. Build the canisters first, then run:

```bash
bun run test:build   # compile Motoko → WASM (required before first run and after source changes)
bun run test              # run all integration tests
```

Individual suites:

```bash
bun run test:correctness   # gzip round-trip correctness
bun run test:interop       # gzip interoperability with native implementations
```

### Performance tracing

The repo ships a scripted perf harness that instruments Motoko sources transiently, runs a PocketIC workload, and produces structured reports — without touching committed source.

```bash
bun run perf component=<name>   # huffman | deflate | gzip | lzss
```

Two files are written to `scripts/output/` (git-ignored) after each run:

| File                          | Contents                                                                                                                         |
| ----------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| `perf-<component>-<ts>.jsonl` | Raw marks — one `{ tag, instrs, mem, heap }` JSON object per line                                                                |
| `perf-<component>-<ts>.json`  | Computed report — 11-point timeline (0%–100% by mark index) + per-method avg/min/max delta stats for `instrs`, `mem`, and `heap` |

Instruction counts use `IC.performanceCounter(1)` (cumulative monotonic counter). Delta values between consecutive same-method marks represent the cost of one call.

## Resources

- [DEFLATE RFC 1951](https://www.rfc-editor.org/rfc/rfc1951)
- [Gzip RFC 1952](https://www.rfc-editor.org/rfc/rfc1952)
- [libflate (Rust reference implementation)](https://github.com/sile/libflate)
- [Data Compression — Lempel-Ziv Schemes (lecture)](https://www.youtube.com/watch?v=VDXBnmr8AY0)
- [Data Compression — DEFLATE/gzip (lecture)](https://www.youtube.com/watch?v=oi2lMBBjQ8s)
- [Original fork: edjcase/motoko_compression](https://github.com/edjcase/motoko_compression)

## License

MIT
