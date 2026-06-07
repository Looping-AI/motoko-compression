# motoko-compression

A Motoko compression library for the [Internet Computer](https://internetcomputer.org/), implementing **Gzip**, **DEFLATE**, **LZSS**, and **Huffman** on top of `mo:core`.

This repository is the current `mo:core`-based migration of [edjcase/motoko_compression](https://github.com/edjcase/motoko_compression), with unit tests, integration tests, and example canisters for large-payload flows on the IC.

## Status

| Algorithm | Encode | Decode | Public entry point |
| --------- | ------ | ------ | ------------------ |
| Gzip      | ✅     | ✅     | `mo:motoko-compression/Gzip` |
| DEFLATE   | ✅     | ✅     | `mo:motoko-compression/Deflate` |
| LZSS      | ✅     | ✅     | `mo:motoko-compression/LZSS` |
| Huffman   | ✅     | ✅     | internal building blocks |

## Installation

```bash
mops add motoko-compression
```

```motoko
import Gzip "mo:motoko-compression/Gzip";
import Deflate "mo:motoko-compression/Deflate";
import LZSS "mo:motoko-compression/LZSS";
```

## Core concepts

### 1. Gzip supports both buffered and streaming flows

The Gzip API has two complementary modes:

- **Buffered finish**: call `encode(...)`, then `finish()` to receive `EncodedResponse`.
- **Streaming finish**: register `setOnOutput(...)`, then call `finishStreaming()` to receive compressed bytes incrementally via a callback.

### 2. `#chunked` is still one logical gzip stream

`Gzip.Encoder.finish()` returns:

```motoko
{
  #single : [Nat8];
  #chunked : [[Nat8]];
}
```

`#chunked` does **not** mean “many independent gzip files”. It is one gzip stream split at safe DEFLATE block boundaries so a single `Gzip.Decoder` can receive the fragments across multiple calls.

### 3. Decode is intentionally two-phase

`Gzip.Decoder.decode(bytes)` only buffers compressed bytes. Actual decompression happens when you call either:

- `finishStreaming(consume)` for a one-shot decode, or
- `start()` + repeated `step(maxOutBytes, consume)` to spread the work across multiple IC messages.

This is the main architectural shift in the current codebase: for large payloads, **stream output and resume work across messages instead of materializing or re-chunking whole payloads in one call**.

## Gzip quick start

### One-shot round trip

```motoko
import Blob "mo:core/Blob";
import List "mo:core/List";
import Nat8 "mo:core/Nat8";
import Runtime "mo:core/Runtime";
import Text "mo:core/Text";
import Gzip "mo:motoko-compression/Gzip";

let input = Blob.toArray(Text.encodeUtf8("Hello, Internet Computer!"));

let encoder = Gzip.EncoderBuilder().build();
encoder.encode(input);
let compressed = encoder.finish();

let decoder = Gzip.Decoder();
switch (compressed) {
  case (#single bytes) {
    ignore decoder.decode(bytes);
  };
  case (#chunked chunks) {
    for (chunk in chunks.vals()) {
      ignore decoder.decode(chunk);
    };
  };
};

let output = List.empty<Nat8>();
switch (decoder.finishStreaming(func(chunk : [Nat8]) { List.addAll(output, chunk.vals()) })) {
  case (#ok(summary)) {
    assert summary.size == input.size();
  };
  case (#err(msg)) {
    Runtime.trap("gzip decode failed: " # msg);
  };
};

let roundTrip = List.toArray(output);
```

### Streaming encode without materializing the full compressed payload

Use this when compressed output should be forwarded, stored, or sent across self-calls as it is produced.

```motoko
import List "mo:core/List";
import Nat8 "mo:core/Nat8";
import Gzip "mo:motoko-compression/Gzip";

let part1 : [Nat8] = [1, 2, 3, 4];
let part2 : [Nat8] = [5, 6, 7, 8];

let fragments = List.empty<[Nat8]>();
let encoder = Gzip.EncoderBuilder()
  .outputChunkSize(1_024 * 1_024)
  .build();

encoder.setOnOutput(func(chunk : [Nat8]) {
  List.add(fragments, chunk);
});

encoder.encode(part1);
encoder.encode(part2);

let summary = encoder.finishStreaming();
let gzipStreamFragments : [[Nat8]] = List.toArray(fragments);

// `gzipStreamFragments` are fragments of one gzip stream.
// Feed them all to the same decoder in order.
```

### Resumable decode across multiple messages

Use `start()` + `step()` when inflate work itself must be spread across messages.

```motoko
import List "mo:core/List";
import Nat8 "mo:core/Nat8";
import Runtime "mo:core/Runtime";
import Gzip "mo:motoko-compression/Gzip";

let input : [Nat8] = [1, 2, 3, 4, 5, 6, 7, 8];
let fragments = List.empty<[Nat8]>();

let encoder = Gzip.EncoderBuilder().build();
encoder.setOnOutput(func(chunk : [Nat8]) {
  List.add(fragments, chunk);
});
encoder.encode(input);
ignore encoder.finishStreaming();

let decoder = Gzip.Decoder();
for (fragment in List.values(fragments)) {
  switch (decoder.decode(fragment)) {
    case (#ok(_)) {};
    case (#err(msg)) Runtime.trap("decode failed: " # msg);
  };
};

switch (decoder.start()) {
  case (#ok(_header)) {};
  case (#err(msg)) Runtime.trap("start failed: " # msg);
};

let output = List.empty<Nat8>();
let consume = func(chunk : [Nat8]) {
  List.addAll(output, chunk.vals());
};

label drive loop {
  switch (decoder.step(512 * 1024, consume)) {
    case (#ok(#more)) {
      // Schedule another self-call / timer tick, then call step(...) again.
    };
    case (#ok(#done(summary))) {
      assert summary.size == List.size(output);
      break drive;
    };
    case (#err(msg)) {
      Runtime.trap("step failed: " # msg);
    };
  };
};
```

## Gzip builder options

`Gzip.EncoderBuilder()` exposes the current tuning knobs:

- `.fixedHuffman()` / `.dynamicHuffman()` / `.autoHuffman()`
- `.lzss(#fast | #balance | #best)`
- `.deflateBlockSize(bytes)`
- `.outputChunkSize(bytes)`
- `.header(header)`
- `.build()`

Notes:

- `outputChunkSize()` controls buffered output splitting and is also the repo’s recommended **per-self-call input slice size** when compression is spread across IC messages.
- `deflateBlockSize()` controls DEFLATE block formation, not IC message sizing.
- If you call `setOnOutput(...)`, finish with `finishStreaming()` instead of `finish()`.

## Raw DEFLATE

`Deflate` exposes the lower-level encoder/decoder used by Gzip.

```motoko
import List "mo:core/List";
import Nat8 "mo:core/Nat8";
import Runtime "mo:core/Runtime";
import Deflate "mo:motoko-compression/Deflate";

let input : [Nat8] = [1, 2, 3, 1, 2, 3, 1, 2, 3];

let options : Deflate.DeflateOptions = {
  deflate_block_size = 32_768;
  force_huffman_kind = null;
  lzss = #balance;
};

let encoder = Deflate.buildEncoder(options);
encoder.encode(input);

let bitBuffer = encoder.finish();
let compressed = bitBuffer.getBytes(0, bitBuffer.byteSize());

let decoder = Deflate.buildDecoder(compressed);
let output = List.empty<Nat8>();

switch (decoder.decodeStreamingWithCapacity(0, func(chunk : [Nat8]) {
  List.addAll(output, chunk.vals());
})) {
  case (#ok()) {};
  case (#err(msg)) Runtime.trap("deflate decode failed: " # msg);
};
```

## Raw LZSS

The public LZSS API is callback-based. The encoder emits matches through `MatchSink`; the decoder exposes direct `literal(...)` and `pointer(...)` methods.

```motoko
import List "mo:core/List";
import Nat8 "mo:core/Nat8";
import LZSS "mo:motoko-compression/LZSS";

let input : [Nat8] = [1, 2, 3, 1, 2, 3, 1, 2, 3];
let output = List.empty<Nat8>();
let decoder = LZSS.Decoder.Decoder();

let sink : LZSS.MatchSink = {
  onLiteral = func(byte : Nat8) {
    decoder.literal(output, byte);
  };
  onPointer = func(offset : Nat, len : Nat) {
    decoder.pointer(output, offset, len);
  };
};

let encoder = LZSS.Encoder.Encoder(#balance);
encoder.encode(input, sink);
encoder.flush(sink);

let roundTrip = List.toArray(output);
```

Compression levels are:

- `#fast`
- `#balance`
- `#best`

## Example canisters in this repository

- `example/compress.mo` — timer-driven job queue showing **streaming encode** plus **resumable decode** across messages.
- `example/external-decompress.mo` — upload one externally-produced gzip stream in batches, then decode it with `finishStreaming()`.
- `example/compress-images.mo` — image store example. For large uploads it stores multiple **independent gzip streams** (one per uploaded chunk), which is different from the single-stream fragment flow used by the core streaming API.

## Development

### Checks

```bash
bun run format:check
bun run lint
mops test
bun run test:build
bun run test
```

Useful subsets:

```bash
bun run test:correctness
bun run test:interop
bun run test:timing
bun run test:image
```

### Performance tracing

The repo ships a perf harness that instruments Motoko sources transiently, runs workloads on PocketIC, and writes reports to `scripts/output/`.

```bash
bun run perf component=<name>
```

Available components: `huffman`, `deflate`, `gzip`, `lzss`

Instruction counts are measured with `IC.performanceCounter(1)`.

## Resources

- [DEFLATE RFC 1951](https://www.rfc-editor.org/rfc/rfc1951)
- [Gzip RFC 1952](https://www.rfc-editor.org/rfc/rfc1952)
- [libflate (Rust reference implementation)](https://github.com/sile/libflate)
- [Original fork: edjcase/motoko_compression](https://github.com/edjcase/motoko_compression)

## License

MIT
