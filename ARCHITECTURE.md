# Architecture

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
};

```

`#chunked` does **not** mean "many independent gzip files". It is one gzip stream split at safe DEFLATE block boundaries so a single `Gzip.Decoder` can receive the fragments across multiple calls.

### 3. Decode is intentionally two-phase

`Gzip.Decoder.decode(bytes)` only buffers compressed bytes. Actual decompression happens when you call either:

- `finishStreaming(consume)` for a one-shot decode, or
- `start()` + repeated `step(maxOutBytes, consume)` to spread the work across multiple IC messages.

For large payloads: **stream output and resume work across messages** instead of materializing or re-chunking whole payloads in one call. This is the main architectural shift from the original `edjcase/motoko_compression`.

## Layer overview

```
Gzip  (RFC 1952 wrapper: header, CRC32, ISIZE)
  └─ Deflate  (RFC 1951: LZ77 + Huffman coding)
       ├─ LZSS  (match finder: #fast | #balance | #best)
       └─ Huffman  (fixed or dynamic code tables)
```

## Encode path

1. Input bytes → LZSS match finder → literal/pointer stream
2. Literal/pointer stream → Huffman encoder → bit stream
3. Bit stream packed into DEFLATE blocks → Gzip framing appended

`EncoderBuilder` options map directly to steps 1–3:

| Option                                                     | Affects                            |
| ---------------------------------------------------------- | ---------------------------------- |
| `.lzss(#fast\|#balance\|#best)`                            | Match quality vs. speed (step 1)   |
| `.fixedHuffman()` / `.dynamicHuffman()` / `.autoHuffman()` | Code table choice (step 2)         |
| `.deflateBlockSize(bytes)`                                 | DEFLATE block formation (step 2–3) |
| `.outputChunkSize(bytes)`                                  | Output buffer splitting (step 3)   |

## Decode path

1. Gzip header parsed by `start()`
2. Compressed bytes buffered via repeated `decode(fragment)`
3. Inflate via `finishStreaming(consume)` **or** iterated `step(maxOut, consume)`
4. CRC32 + ISIZE verified on completion

`step()` is the IC-native path: each call decompresses at most `maxOutBytes` and returns `#more` or `#done`, letting the canister yield between IC messages without re-uploading data.

## Independent streams vs. one fragmented stream

| Pattern                                                 | When to use                                                                                                                              |
| ------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| One stream, fragmented (`#chunked` / `finishStreaming`) | Compressing data produced or consumed in one logical operation                                                                           |
| Multiple independent streams                            | Storing separately-uploaded chunks (e.g. image uploads) where each chunk may arrive in a different call and must be decodable standalone |

`example/compress-images.mo` uses the multi-stream pattern; `example/compress.mo` and `example/external-decompress.mo` use the single-stream pattern.
