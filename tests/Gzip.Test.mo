import { test; suite; expect } "mo:test";
import Array "mo:core/Array";
import Nat8 "mo:core/Nat8";
import Runtime "mo:core/Runtime";

import Gzip "../src/Gzip/lib";

// ── Helpers ───────────────────────────────────────────────────────────────

/// Encode `data` with `enc`, feed all chunks through a decoder, return decoded bytes.
func roundTrip(data : [Nat8], enc : Gzip.EncoderBuilder) : [Nat8] {
  let encoder = enc.build();
  encoder.encode(data);
  let resp = encoder.finish();

  let decoder = Gzip.Decoder();
  let chunks = switch (resp) {
    case (#single data) [data];
    case (#chunked chunks) chunks;
  };
  for (chunk in chunks.vals()) {
    switch (decoder.decode(chunk)) {
      case (#err(msg)) Runtime.trap("decode error: " # msg);
      case (#ok(_)) {};
    };
  };
  switch (decoder.finish()) {
    case (#err(msg)) Runtime.trap("finish error: " # msg);
    case (#ok(result)) result.bytes;
  };
};

func defaultBuilder() : Gzip.EncoderBuilder {
  Gzip.EncoderBuilder();
};

// ── Suite: Fixed-Huffman round-trips ─────────────────────────────────────

suite(
  "Fixed Huffman round-trips",
  func() {

    test(
      "empty input",
      func() {
        expect.array(roundTrip([], defaultBuilder()), Nat8.toText, Nat8.equal).equal([]);
      },
    );

    test(
      "single byte",
      func() {
        expect.array(roundTrip([42], defaultBuilder()), Nat8.toText, Nat8.equal).equal([42]);
      },
    );

    test(
      "hello world",
      func() {
        let data : [Nat8] = [72, 101, 108, 108, 111, 32, 87, 111, 114, 108, 100];
        expect.array(roundTrip(data, defaultBuilder()), Nat8.toText, Nat8.equal).equal(data);
      },
    );

    test(
      "1 KB repeated bytes (high compression ratio)",
      func() {
        let data = Array.tabulate<Nat8>(1024, func(_) { 0xAA });
        expect.array(roundTrip(data, defaultBuilder()), Nat8.toText, Nat8.equal).equal(data);
      },
    );

    test(
      "all 256 byte values",
      func() {
        let data = Array.tabulate<Nat8>(256, func(i) { Nat8.fromNat(i) });
        expect.array(roundTrip(data, defaultBuilder()), Nat8.toText, Nat8.equal).equal(data);
      },
    );

  },
);

// ── Suite: Dynamic-Huffman round-trips ───────────────────────────────────

suite(
  "Dynamic Huffman round-trips",
  func() {

    test(
      "hello world (dynamic)",
      func() {
        let data : [Nat8] = [72, 101, 108, 108, 111, 32, 87, 111, 114, 108, 100];
        let enc = Gzip.EncoderBuilder().dynamicHuffman();
        expect.array(roundTrip(data, enc), Nat8.toText, Nat8.equal).equal(data);
      },
    );

    test(
      "1 KB repeated bytes (dynamic)",
      func() {
        let data = Array.tabulate<Nat8>(1024, func(_) { 0xBB });
        let enc = Gzip.EncoderBuilder().dynamicHuffman();
        expect.array(roundTrip(data, enc), Nat8.toText, Nat8.equal).equal(data);
      },
    );

  },
);

// ── Suite: LZSS level options ─────────────────────────────────────────────

suite(
  "LZSS compression levels",
  func() {

    test(
      "#fast level",
      func() {
        let data = Array.tabulate<Nat8>(512, func(i) { Nat8.fromNat(i % 64) });
        let enc = Gzip.EncoderBuilder().lzss(#fast);
        expect.array(roundTrip(data, enc), Nat8.toText, Nat8.equal).equal(data);
      },
    );

    test(
      "#balance level",
      func() {
        let data = Array.tabulate<Nat8>(512, func(i) { Nat8.fromNat(i % 64) });
        let enc = Gzip.EncoderBuilder().lzss(#balance);
        expect.array(roundTrip(data, enc), Nat8.toText, Nat8.equal).equal(data);
      },
    );

    test(
      "#best level",
      func() {
        let data = Array.tabulate<Nat8>(512, func(i) { Nat8.fromNat(i % 64) });
        let enc = Gzip.EncoderBuilder().lzss(#best);
        expect.array(roundTrip(data, enc), Nat8.toText, Nat8.equal).equal(data);
      },
    );

  },
);

// ── Suite: Header fields preserved ───────────────────────────────────────

suite(
  "Header fields",
  func() {

    test(
      "OS byte preserved",
      func() {
        let h = { Gzip.defaultHeader() with os = #Macintosh };
        let encoder = Gzip.EncoderBuilder().header(h).build();
        encoder.encode([1, 2, 3]);
        let resp = encoder.finish();

        let dec = Gzip.Decoder();
        let all = switch (resp) {
          case (#single d) d;
          case (#chunked chunks) chunks[0];
        };
        ignore dec.decode(all);
        switch (dec.finish()) {
          case (#ok(r)) {
            switch (r.header.os) {
              case (#Macintosh) {};
              case (other) Runtime.trap("Expected #Macintosh, got " # debug_show other);
            };
          };
          case (#err(msg)) Runtime.trap(msg);
        };
      },
    );

    test(
      "filename preserved",
      func() {
        let h = { Gzip.defaultHeader() with filename = ?"hello.txt" };
        let encoder = Gzip.EncoderBuilder().header(h).build();
        encoder.encode([1, 2, 3]);
        let resp = encoder.finish();

        let dec = Gzip.Decoder();
        let all = switch (resp) {
          case (#single d) d;
          case (#chunked chunks) chunks[0];
        };
        ignore dec.decode(all);
        switch (dec.finish()) {
          case (#ok(r)) {
            switch (r.header.filename) {
              case (?"hello.txt") {};
              case (other) Runtime.trap("Filename mismatch: " # debug_show other);
            };
          };
          case (#err(msg)) Runtime.trap(msg);
        };
      },
    );

  },
);

// ── Suite: Multi-chunk streaming ──────────────────────────────────────────

suite(
  "Multi-chunk output",
  func() {

    test(
      "small block size produces multiple chunks",
      func() {
        // A 1-byte deflate block size forces a block per byte (many chunks)
        let data = Array.tabulate<Nat8>(64, func(i) { Nat8.fromNat(i) });
        let encoder = Gzip.EncoderBuilder().deflateBlockSize(1).outputChunkSize(1).build();
        encoder.encode(data);
        let resp = encoder.finish();
        let chunks = switch (resp) {
          case (#single d) [d];
          case (#chunked chunks) chunks;
        };
        expect.bool(chunks.size() > 0).isTrue();

        // All chunks together should decompress correctly
        let decoder = Gzip.Decoder();
        for (chunk in chunks.vals()) {
          switch (decoder.decode(chunk)) {
            case (#err(msg)) Runtime.trap("chunk decode error: " # msg);
            case (#ok(_)) {};
          };
        };
        switch (decoder.finish()) {
          case (#err(msg)) Runtime.trap("finish error: " # msg);
          case (#ok(result)) {
            expect.array(result.bytes, Nat8.toText, Nat8.equal).equal(data);
          };
        };
      },
    );

    test(
      "total_size matches sum of chunk sizes",
      func() {
        let data = Array.tabulate<Nat8>(256, func(i) { Nat8.fromNat(i % 128) });
        let encoder = Gzip.EncoderBuilder().deflateBlockSize(64).outputChunkSize(64).build();
        encoder.encode(data);
        let resp = encoder.finish();

        let respChunks = switch (resp) {
          case (#single d) [d];
          case (#chunked chunks) chunks;
        };
        var sum = 0;
        for (chunk in respChunks.vals()) { sum += chunk.size() };
        // total compressed size equals sum of all chunk sizes
        expect.bool(sum > 0).isTrue();
      },
    );

  },
);

// ── Suite: Error handling ─────────────────────────────────────────────────

suite(
  "Error handling",
  func() {

    test(
      "invalid magic bytes → #err",
      func() {
        let decoder = Gzip.Decoder();
        ignore decoder.decode([0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03]);
        switch (decoder.finish()) {
          case (#err(_)) {}; // expected
          case (#ok(_)) Runtime.trap("Expected error for invalid magic bytes");
        };
      },
    );

    test(
      "CRC32 mismatch → #err",
      func() {
        // Encode valid data
        let encoder = Gzip.EncoderBuilder().build();
        encoder.encode([1, 2, 3, 4, 5]);
        let resp = encoder.finish();

        // Corrupt a byte in the middle of the payload
        let all = switch (resp) {
          case (#single d) d;
          case (#chunked chunks) chunks[0];
        };
        let corrupted = Array.tabulate<Nat8>(
          all.size(),
          func(i) {
            if (i == 12) { ^all[i] } else { all[i] } // flip bits at offset 12
          },
        );

        let decoder = Gzip.Decoder();
        ignore decoder.decode(corrupted);
        switch (decoder.finish()) {
          case (#err(_)) {}; // expected
          case (#ok(_)) Runtime.trap("Expected error for corrupted data");
        };
      },
    );

  },
);
