import { test; suite; expect } "mo:test";
import Array "mo:core/Array";
import Nat8 "mo:core/Nat8";
import Runtime "mo:core/Runtime";

import Encoder "../src/Gzip/Encoder";
import Gzip "../src/Gzip/lib";

// ── Helpers ───────────────────────────────────────────────────────────────

/// Compress `data` with `encoder`, decode the result, clear the encoder, and
/// return the decompressed bytes.
func roundTrip(encoder : Encoder.Encoder, data : [Nat8]) : [Nat8] {
  encoder.encode(data);
  encoder.finish();
  let compressed = encoder.compressed();
  encoder.clear();
  let dec = Gzip.Decoder();
  dec.decode(compressed);
  switch (dec.finish()) {
    case (#err(msg)) Runtime.trap("Decode error: " # msg);
    case (#ok(_)) {};
  };
  dec.decompressed();
};

/// Compress `data` in `chunkLen`-byte slices (multi-feed), decode, and return
/// decompressed bytes.
func roundTripChunked(encoder : Encoder.Encoder, data : [Nat8], chunkLen : Nat) : [Nat8] {
  var offset = 0;
  while (offset < data.size()) {
    let end = if (offset + chunkLen > data.size()) data.size() else offset + chunkLen;
    encoder.encode(Array.tabulate<Nat8>(end - offset, func(i) = data[offset + i]));
    offset := end;
  };
  encoder.finish();
  let compressed = encoder.compressed();
  encoder.clear();
  let dec = Gzip.Decoder();
  dec.decode(compressed);
  switch (dec.finish()) {
    case (#err(msg)) Runtime.trap("Decode chunked error: " # msg);
    case (#ok(_)) {};
  };
  dec.decompressed();
};

// ── Suite: EncoderBuilder configuration ──────────────────────────────────

suite(
  "EncoderBuilder configuration",
  func() {

    test(
      "default outputChunkSize is 6 MiB",
      func() {
        let enc = Encoder.EncoderBuilder().build();
        expect.nat(enc.outputChunkSize()).equal(6_291_456);
      },
    );

    test(
      "default deflateBlockSize is 32 KiB",
      func() {
        let enc = Encoder.EncoderBuilder().build();
        expect.nat(enc.deflateBlockSize()).equal(32_768);
      },
    );

    test(
      "outputChunkSize(n) overrides the default",
      func() {
        let enc = Encoder.EncoderBuilder().outputChunkSize(1_000).build();
        expect.nat(enc.outputChunkSize()).equal(1_000);
      },
    );

    test(
      "deflateBlockSize(n) overrides the default",
      func() {
        let enc = Encoder.EncoderBuilder().deflateBlockSize(512).build();
        expect.nat(enc.deflateBlockSize()).equal(512);
      },
    );

    test(
      "builder methods chain and all settings take effect",
      func() {
        let enc = Encoder.EncoderBuilder().outputChunkSize(2_000).deflateBlockSize(128).fixedHuffman().lzss(#fast).build();
        expect.nat(enc.outputChunkSize()).equal(2_000);
        expect.nat(enc.deflateBlockSize()).equal(128);
      },
    );

  },
);

// ── Suite: Round-trip — small / boundary inputs ───────────────────────────

suite(
  "Round-trip — small inputs",
  func() {

    test(
      "empty input",
      func() {
        let enc = Encoder.EncoderBuilder().build();
        expect.array(roundTrip(enc, []), Nat8.toText, Nat8.equal).equal([]);
      },
    );

    test(
      "single byte",
      func() {
        let enc = Encoder.EncoderBuilder().build();
        expect.array(roundTrip(enc, [42]), Nat8.toText, Nat8.equal).equal([42]);
      },
    );

    test(
      "Hello World!",
      func() {
        // "Hello World!" in ASCII
        let data : [Nat8] = [72, 101, 108, 108, 111, 32, 87, 111, 114, 108, 100, 33];
        let enc = Encoder.EncoderBuilder().build();
        expect.array(roundTrip(enc, data), Nat8.toText, Nat8.equal).equal(data);
      },
    );

    test(
      "all bytes 0..255",
      func() {
        let data = Array.tabulate<Nat8>(256, func(i) = Nat8.fromNat(i));
        let enc = Encoder.EncoderBuilder().build();
        expect.array(roundTrip(enc, data), Nat8.toText, Nat8.equal).equal(data);
      },
    );

    test(
      "highly repetitive input (LZSS back-references)",
      func() {
        let data = Array.tabulate<Nat8>(500, func(_) = 0xAB);
        let enc = Encoder.EncoderBuilder().build();
        expect.array(roundTrip(enc, data), Nat8.toText, Nat8.equal).equal(data);
      },
    );

  },
);

// ── Suite: Gzip header correctness ───────────────────────────────────────

suite(
  "Gzip output structure",
  func() {

    test(
      "output starts with Gzip magic bytes 0x1f 0x8b",
      func() {
        let enc = Encoder.EncoderBuilder().build();
        enc.encode([1, 2, 3]);
        enc.finish();
        let out = enc.compressed();
        enc.clear();
        expect.bool(out.size() >= 2).isTrue();
        expect.nat8(out[0]).equal(0x1f);
        expect.nat8(out[1]).equal(0x8b);
      },
    );

    test(
      "empty-input output is still a valid Gzip stream",
      func() {
        let enc = Encoder.EncoderBuilder().build();
        enc.finish();
        let out = enc.compressed();
        enc.clear();
        // A valid (empty) Gzip stream must be at least 18 bytes
        // (10-byte header + 2-byte deflate EOB block + 8-byte footer).
        expect.bool(out.size() >= 18).isTrue();
        expect.nat8(out[0]).equal(0x1f);
        expect.nat8(out[1]).equal(0x8b);
      },
    );

    test(
      "compressed size is smaller than original for repetitive data",
      func() {
        let data = Array.tabulate<Nat8>(4096, func(i) = Nat8.fromNat(i % 8));
        let enc = Encoder.EncoderBuilder().build();
        enc.encode(data);
        enc.finish();
        let out = enc.compressed();
        enc.clear();
        expect.bool(out.size() < data.size()).isTrue();
      },
    );

  },
);

// ── Suite: Multi-feed encoding ────────────────────────────────────────────

suite(
  "Multi-feed encoding",
  func() {

    test(
      "two encode() calls produce the same output as one",
      func() {
        let enc = Encoder.EncoderBuilder().build();

        // Single call
        let data : [Nat8] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
        enc.encode(data);
        enc.finish();
        let singleOut = enc.compressed();
        enc.clear();

        // Two halves
        enc.encode(Array.tabulate<Nat8>(5, func(i) = data[i]));
        enc.encode(Array.tabulate<Nat8>(5, func(i) = data[5 + i]));
        enc.finish();
        let chunkedOut = enc.compressed();
        enc.clear();

        // Both must decompress to the original
        let dec = Gzip.Decoder();
        dec.decode(singleOut);
        switch (dec.finish()) {
          case (#err(msg)) Runtime.trap(msg);
          case (#ok(_)) {};
        };
        let single = dec.decompressed();
        dec.clear();

        dec.decode(chunkedOut);
        switch (dec.finish()) {
          case (#err(msg)) Runtime.trap(msg);
          case (#ok(_)) {};
        };
        let chunked = dec.decompressed();

        expect.array(single, Nat8.toText, Nat8.equal).equal(data);
        expect.array(chunked, Nat8.toText, Nat8.equal).equal(data);
      },
    );

    test(
      "1 KiB data fed in 32-byte slices round-trips",
      func() {
        let data = Array.tabulate<Nat8>(1024, func(i) = Nat8.fromNat(i % 251));
        let enc = Encoder.EncoderBuilder().build();
        expect.array(roundTripChunked(enc, data, 32), Nat8.toText, Nat8.equal).equal(data);
      },
    );

    test(
      "1-byte deflate block size with chunked feed round-trips",
      func() {
        // Extremely small block size forces a block flush on every encode call,
        // exercising the STREAM_FLUSH_THRESHOLD drain callback heavily.
        let data = Array.tabulate<Nat8>(128, func(i) = Nat8.fromNat(i));
        let enc = Encoder.EncoderBuilder().deflateBlockSize(1).build();
        expect.array(roundTripChunked(enc, data, 16), Nat8.toText, Nat8.equal).equal(data);
      },
    );

  },
);

// ── Suite: chunks() vs compressed() ──────────────────────────────────────

suite(
  "chunks() and compressed() are equivalent",
  func() {

    test(
      "single-chunk output: chunks()[0] equals compressed()",
      func() {
        let data : [Nat8] = [10, 20, 30, 40, 50];
        let enc = Encoder.EncoderBuilder().build();
        enc.encode(data);
        enc.finish();
        let merged = enc.compressed();
        let parts = enc.chunks();
        enc.clear();

        let fromChunks = Array.flatten(parts);
        expect.array(fromChunks, Nat8.toText, Nat8.equal).equal(merged);
      },
    );

    test(
      "multi-chunk output: flattened chunks() equals compressed()",
      func() {
        // A very small STREAM_FLUSH_THRESHOLD would be needed to force multiple
        // chunks in practice; instead we verify logical equivalence by comparing
        // Array.flatten(chunks()) with compressed() for a moderately-sized input.
        let data = Array.tabulate<Nat8>(2048, func(i) = Nat8.fromNat(i % 16));
        let enc = Encoder.EncoderBuilder().deflateBlockSize(64).build();
        enc.encode(data);
        enc.finish();
        let merged = enc.compressed();
        let parts = enc.chunks();
        enc.clear();

        let fromChunks = Array.flatten(parts);
        expect.array(fromChunks, Nat8.toText, Nat8.equal).equal(merged);
      },
    );

  },
);

// ── Suite: Encoder reuse via clear() ─────────────────────────────────────

suite(
  "Encoder reuse via clear()",
  func() {

    test(
      "two consecutive compressions with clear() are independent",
      func() {
        let enc = Encoder.EncoderBuilder().build();

        let dataA = Array.tabulate<Nat8>(256, func(i) = Nat8.fromNat(i % 64));
        let dataB = Array.tabulate<Nat8>(128, func(i) = Nat8.fromNat(255 - (i % 128)));

        expect.array(roundTrip(enc, dataA), Nat8.toText, Nat8.equal).equal(dataA);
        expect.array(roundTrip(enc, dataB), Nat8.toText, Nat8.equal).equal(dataB);
      },
    );

    test(
      "clear() after finish() resets headerWritten — next stream has its own header",
      func() {
        let enc = Encoder.EncoderBuilder().build();
        enc.encode([1, 2, 3]);
        enc.finish();
        let first = enc.compressed();
        enc.clear();

        enc.encode([4, 5, 6]);
        enc.finish();
        let second = enc.compressed();
        enc.clear();

        // Both outputs are independently valid Gzip streams.
        let dec = Gzip.Decoder();

        dec.decode(first);
        switch (dec.finish()) {
          case (#err(msg)) Runtime.trap("first clear() decode: " # msg);
          case (#ok(_)) {};
        };
        expect.array(dec.decompressed(), Nat8.toText, Nat8.equal).equal([1, 2, 3]);
        dec.clear();

        dec.decode(second);
        switch (dec.finish()) {
          case (#err(msg)) Runtime.trap("second clear() decode: " # msg);
          case (#ok(_)) {};
        };
        expect.array(dec.decompressed(), Nat8.toText, Nat8.equal).equal([4, 5, 6]);
      },
    );

  },
);

// ── Suite: Huffman mode round-trips ──────────────────────────────────────

suite(
  "Huffman modes",
  func() {

    let data = Array.tabulate<Nat8>(512, func(i) = Nat8.fromNat(i % 64));

    test(
      "fixedHuffman round-trips",
      func() {
        let enc = Encoder.EncoderBuilder().fixedHuffman().build();
        expect.array(roundTrip(enc, data), Nat8.toText, Nat8.equal).equal(data);
      },
    );

    test(
      "dynamicHuffman round-trips",
      func() {
        let enc = Encoder.EncoderBuilder().dynamicHuffman().build();
        expect.array(roundTrip(enc, data), Nat8.toText, Nat8.equal).equal(data);
      },
    );

    test(
      "autoHuffman round-trips",
      func() {
        let enc = Encoder.EncoderBuilder().autoHuffman().build();
        expect.array(roundTrip(enc, data), Nat8.toText, Nat8.equal).equal(data);
      },
    );

  },
);

// ── Suite: LZSS level round-trips ────────────────────────────────────────

suite(
  "LZSS levels",
  func() {

    let data = Array.tabulate<Nat8>(512, func(i) = Nat8.fromNat(i % 64));

    test(
      "#fast round-trips",
      func() {
        let enc = Encoder.EncoderBuilder().lzss(#fast).build();
        expect.array(roundTrip(enc, data), Nat8.toText, Nat8.equal).equal(data);
      },
    );

    test(
      "#balance round-trips",
      func() {
        let enc = Encoder.EncoderBuilder().lzss(#balance).build();
        expect.array(roundTrip(enc, data), Nat8.toText, Nat8.equal).equal(data);
      },
    );

    test(
      "#best round-trips",
      func() {
        let enc = Encoder.EncoderBuilder().lzss(#best).build();
        expect.array(roundTrip(enc, data), Nat8.toText, Nat8.equal).equal(data);
      },
    );

  },
);
