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

```motoko
import Blob "mo:core/Blob";
import List "mo:core/List";
import Runtime "mo:core/Runtime";
import Text "mo:core/Text";
import Gzip "mo:motoko-compression/Gzip";

let input = Blob.toArray(Text.encodeUtf8("Hello, Internet Computer!"));

let encoder = Gzip.EncoderBuilder().build();
encoder.encode(input);
let compressed = encoder.finish();

let decoder = Gzip.Decoder();
switch (compressed) {
  case (#single bytes) { ignore decoder.decode(bytes) };
  case (#chunked chunks) {
    for (chunk in chunks.vals()) ignore decoder.decode(chunk);
  };
};

let output = List.empty<Nat8>();
switch (decoder.finishStreaming(func(chunk) { List.addAll(output, chunk.vals()) })) {
  case (#ok(summary)) assert summary.size == input.size();
  case (#err(msg)) Runtime.trap("gzip decode failed: " # msg);
};

```

### Streaming encode (IC-friendly)

Use when compressed output should be forwarded or stored as it is produced — avoids materializing the full payload.

```motoko
import List "mo:core/List";
import Gzip "mo:motoko-compression/Gzip";

let fragments = List.empty<[Nat8]>();
let encoder = Gzip.EncoderBuilder().outputChunkSize(1_024 * 1_024).build();

encoder.setOnOutput(func(chunk) { List.add(fragments, chunk) });
encoder.encode([1, 2, 3, 4]);
encoder.encode([5, 6, 7, 8]);
ignore encoder.finishStreaming();

// `fragments` are all part of one gzip stream — feed them in order to the same decoder.

```

### Resumable decode across messages

Use `start()` + `step()` to spread inflate work across multiple IC messages.

```motoko
import List "mo:core/List";
import Runtime "mo:core/Runtime";
import Gzip "mo:motoko-compression/Gzip";

// ...feed compressed fragments to decoder.decode(...) first, then:
switch (decoder.start()) {
  case (#ok(_header)) {};
  case (#err(msg)) Runtime.trap("start failed: " # msg);
};

let output = List.empty<Nat8>();
label drive loop {
  switch (decoder.step(512 * 1024, func(chunk) { List.addAll(output, chunk.vals()) })) {
    case (#ok(#more)) { /* schedule next self-call, then call step() again */ };
    case (#ok(#done(summary))) {
      assert summary.size == List.size(output);
      break drive;
    };
    case (#err(msg)) Runtime.trap("step failed: " # msg);
  };
};

```

## EncoderBuilder options

| Option                                                     | Effect                                                                        |
| ---------------------------------------------------------- | ----------------------------------------------------------------------------- |
| `.lzss(#fast \| #balance \| #best)`                        | Match quality vs. speed                                                       |
| `.fixedHuffman()` / `.dynamicHuffman()` / `.autoHuffman()` | Huffman table strategy                                                        |
| `.deflateBlockSize(bytes)`                                 | DEFLATE block size (not IC message size)                                      |
| `.outputChunkSize(bytes)`                                  | Output buffer chunk size; also the recommended per-self-call input slice size |
| `.header(header)`                                          | Custom gzip header                                                            |

> If you call `setOnOutput(...)`, finish with `finishStreaming()` instead of `finish()`.

## Raw DEFLATE

```motoko
import List "mo:core/List";
import Runtime "mo:core/Runtime";
import Deflate "mo:motoko-compression/Deflate";

let options : Deflate.DeflateOptions = {
  deflate_block_size = 32_768;
  force_huffman_kind = null;
  lzss = #balance;
};

let encoder = Deflate.buildEncoder(options);
encoder.encode([1, 2, 3, 1, 2, 3, 1, 2, 3]);
let bitBuffer = encoder.finish();
let compressed = bitBuffer.getBytes(0, bitBuffer.byteSize());

let decoder = Deflate.buildDecoder(compressed);
let output = List.empty<Nat8>();
switch (decoder.decodeStreamingWithCapacity(0, func(chunk) { List.addAll(output, chunk.vals()) })) {
  case (#ok()) {};
  case (#err(msg)) Runtime.trap("deflate decode failed: " # msg);
};

```

## Raw LZSS

```motoko
import List "mo:core/List";
import LZSS "mo:motoko-compression/LZSS";

let output = List.empty<Nat8>();
let decoder = LZSS.Decoder.Decoder();

let sink : LZSS.MatchSink = {
  onLiteral = func(byte) { decoder.literal(output, byte) };
  onPointer = func(offset, len) { decoder.pointer(output, offset, len) };
};

let encoder = LZSS.Encoder.Encoder(#balance); // #fast | #balance | #best
encoder.encode([1, 2, 3, 1, 2, 3, 1, 2, 3], sink);
encoder.flush(sink);

```

## Example canisters

- `example/compress.mo` — timer-driven job queue: streaming encode + resumable decode across messages
- `example/external-decompress.mo` — upload an externally-produced gzip stream in batches, decode with `finishStreaming()`
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
- [libflate (Rust reference)](https://github.com/sile/libflate)
- [Original fork: edjcase/motoko_compression](https://github.com/edjcase/motoko_compression)

## License

MIT
