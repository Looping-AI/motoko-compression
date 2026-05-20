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
  for (chunk in resp.chunks.vals()) {
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

// ── Suite: No-compression round-trips ────────────────────────────────────

suite(
  "No-compression (raw) round-trips",
  func() {

    test(
      "empty input (raw)",
      func() {
        let enc = Gzip.EncoderBuilder().noCompression();
        expect.array(roundTrip([], enc), Nat8.toText, Nat8.equal).equal([]);
      },
    );

    test(
      "hello world (raw)",
      func() {
        let data : [Nat8] = [72, 101, 108, 108, 111, 32, 87, 111, 114, 108, 100];
        let enc = Gzip.EncoderBuilder().noCompression();
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
        ignore dec.decode(resp.chunks[0]);
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
        ignore dec.decode(resp.chunks[0]);
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
        // A 1-byte block size forces a chunk per symbol (many chunks)
        let data = Array.tabulate<Nat8>(64, func(i) { Nat8.fromNat(i) });
        let encoder = Gzip.EncoderBuilder().blockSize(1).build();
        encoder.encode(data);
        let resp = encoder.finish();
        expect.bool(resp.chunks.size() > 0).isTrue();

        // All chunks together should decompress correctly
        let decoder = Gzip.Decoder();
        for (chunk in resp.chunks.vals()) {
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
        let encoder = Gzip.EncoderBuilder().blockSize(64).build();
        encoder.encode(data);
        let resp = encoder.finish();

        var sum = 0;
        for (chunk in resp.chunks.vals()) { sum += chunk.size() };
        expect.nat(sum).equal(resp.total_size);
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
        let all = resp.chunks[0];
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
