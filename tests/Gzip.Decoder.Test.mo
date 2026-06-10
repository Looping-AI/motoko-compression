import { test; suite; expect } "mo:test";
import Array "mo:core/Array";
import Nat8 "mo:core/Nat8";
import Runtime "mo:core/Runtime";

import Gzip "../src/Gzip/lib";

// ── Fixture helper ─────────────────────────────────────────────────────────

/// Compress `data` with the default encoder (balance LZSS, fixed Huffman).
/// Used ONLY to generate gzip byte fixtures; the decoder is the object under test.
func gzip(data : [Nat8]) : [Nat8] {
  let enc = Gzip.buildEncoder(Gzip.defaultOptions());
  enc.encode(data);
  enc.finish();
  enc.compressed();
};

// ── Suite 1: One-shot finish() API ────────────────────────────────────────

suite(
  "One-shot finish()",
  func() {

    test(
      "empty payload decompresses to empty array",
      func() {
        let dec = Gzip.buildDecoder();
        dec.decode(gzip([]));
        switch (dec.finish()) {
          case (#err msg) Runtime.trap("Unexpected error: " # msg);
          case (#ok _) {};
        };
        expect.array(dec.decompressed(), Nat8.toText, Nat8.equal).equal([]);
      },
    );

    test(
      "single byte",
      func() {
        let data : [Nat8] = [0x42];
        let dec = Gzip.buildDecoder();
        dec.decode(gzip(data));
        switch (dec.finish()) {
          case (#err msg) Runtime.trap("Unexpected error: " # msg);
          case (#ok _) {};
        };
        expect.array(dec.decompressed(), Nat8.toText, Nat8.equal).equal(data);
      },
    );

    test(
      "ASCII text payload — Hello, Gzip!",
      func() {
        // "Hello, Gzip!" = 72 101 108 108 111 44 32 71 122 105 112 33
        let data : [Nat8] = [72, 101, 108, 108, 111, 44, 32, 71, 122, 105, 112, 33];
        let dec = Gzip.buildDecoder();
        dec.decode(gzip(data));
        switch (dec.finish()) {
          case (#err msg) Runtime.trap("Unexpected error: " # msg);
          case (#ok _) {};
        };
        expect.array(dec.decompressed(), Nat8.toText, Nat8.equal).equal(data);
      },
    );

    test(
      "all 256 byte values",
      func() {
        let data = Array.tabulate<Nat8>(256, func(i) { Nat8.fromNat(i) });
        let dec = Gzip.buildDecoder();
        dec.decode(gzip(data));
        switch (dec.finish()) {
          case (#err msg) Runtime.trap("Unexpected error: " # msg);
          case (#ok _) {};
        };
        expect.array(dec.decompressed(), Nat8.toText, Nat8.equal).equal(data);
      },
    );

    test(
      "highly repetitive payload exercises LZSS back-references",
      func() {
        let data = Array.tabulate<Nat8>(1024, func(i) { Nat8.fromNat(i % 8) });
        let dec = Gzip.buildDecoder();
        dec.decode(gzip(data));
        switch (dec.finish()) {
          case (#err msg) Runtime.trap("Unexpected error: " # msg);
          case (#ok _) {};
        };
        expect.array(dec.decompressed(), Nat8.toText, Nat8.equal).equal(data);
      },
    );

  },
);

// ── Suite 2: Chunked decode() input ──────────────────────────────────────

suite(
  "Chunked decode() input",
  func() {

    test(
      "feed compressed bytes byte-by-byte before finish()",
      func() {
        let data : [Nat8] = [10, 20, 30, 40, 50];
        let bytes = gzip(data);
        let dec = Gzip.buildDecoder();
        for (b in bytes.vals()) {
          dec.decode([b]);
        };
        switch (dec.finish()) {
          case (#err msg) Runtime.trap("finish error: " # msg);
          case (#ok _) {};
        };
        expect.array(dec.decompressed(), Nat8.toText, Nat8.equal).equal(data);
      },
    );

    test(
      "feed compressed bytes in two halves before finish()",
      func() {
        let data = Array.tabulate<Nat8>(64, func(i) { Nat8.fromNat(i % 32) });
        let bytes = gzip(data);
        let mid = bytes.size() / 2;
        let first = Array.tabulate<Nat8>(mid, func(i) { bytes[i] });
        let second = Array.tabulate<Nat8>(bytes.size() - mid, func(i) { bytes[mid + i] });
        let dec = Gzip.buildDecoder();
        dec.decode(first);
        dec.decode(second);
        switch (dec.finish()) {
          case (#err msg) Runtime.trap("finish error: " # msg);
          case (#ok _) {};
        };
        expect.array(dec.decompressed(), Nat8.toText, Nat8.equal).equal(data);
      },
    );

    test(
      "feed empty byte arrays are ignored",
      func() {
        let data : [Nat8] = [7, 8, 9];
        let bytes = gzip(data);
        let dec = Gzip.buildDecoder();
        dec.decode([]);
        dec.decode([]);
        dec.decode(bytes);
        dec.decode([]);
        switch (dec.finish()) {
          case (#err msg) Runtime.trap("finish error: " # msg);
          case (#ok _) {};
        };
        expect.array(dec.decompressed(), Nat8.toText, Nat8.equal).equal(data);
      },
    );

  },
);

// ── Suite 3: Output accessor methods ─────────────────────────────────────

suite(
  "Output accessors",
  func() {

    test(
      "chunks() and decompressed() return equivalent data",
      func() {
        let data = Array.tabulate<Nat8>(256, func(i) { Nat8.fromNat(i % 64) });
        let dec = Gzip.buildDecoder();
        dec.decode(gzip(data));
        switch (dec.finish()) {
          case (#err msg) Runtime.trap("finish error: " # msg);
          case (#ok _) {};
        };
        let flat = dec.decompressed();
        let joined = Array.flatten(dec.chunks());
        expect.array(flat, Nat8.toText, Nat8.equal).equal(joined);
        expect.array(flat, Nat8.toText, Nat8.equal).equal(data);
      },
    );

    test(
      "decompressedSize() equals output byte count after finish()",
      func() {
        let n = 512;
        let data = Array.tabulate<Nat8>(n, func(i) { Nat8.fromNat(i % 256) });
        let dec = Gzip.buildDecoder();
        dec.decode(gzip(data));
        switch (dec.finish()) {
          case (#err msg) Runtime.trap("finish error: " # msg);
          case (#ok _) {};
        };
        expect.nat(dec.decompressedSize()).equal(n);
        expect.nat(dec.decompressed().size()).equal(n);
      },
    );

    test(
      "decompressed() and chunks() and decompressedSize() are 0 on fresh decoder",
      func() {
        let dec = Gzip.buildDecoder();
        expect.nat(dec.decompressedSize()).equal(0);
        expect.array(dec.decompressed(), Nat8.toText, Nat8.equal).equal([]);
        expect.nat(dec.chunks().size()).equal(0);
      },
    );

  },
);

// ── Suite 4: start() / step() streaming API ──────────────────────────────

suite(
  "start() / step() streaming API",
  func() {

    test(
      "step() without start() returns #err",
      func() {
        let dec = Gzip.buildDecoder();
        dec.decode(gzip([1, 2, 3]));
        switch (dec.step(#default)) {
          case (#err _) {};
          case (#ok _) Runtime.trap("Expected #err when calling step() before start()");
        };
      },
    );

    test(
      "start() returns #ok with a valid header",
      func() {
        let data : [Nat8] = [65, 66, 67]; // "ABC"
        let dec = Gzip.buildDecoder();
        dec.decode(gzip(data));
        switch (dec.start()) {
          case (#err msg) Runtime.trap("start() unexpected error: " # msg);
          case (#ok header) {
            expect.bool(header.is_text).isFalse();
            expect.bool(header.is_verified).isFalse();
          };
        };
        // Drive to completion; not the subject of this test but needed for cleanup.
        label drive loop {
          switch (dec.step(#default)) {
            case (#err msg) Runtime.trap("step error: " # msg);
            case (#ok(#more)) {};
            case (#ok(#done)) break drive;
          };
        };
        expect.array(dec.decompressed(), Nat8.toText, Nat8.equal).equal(data);
      },
    );

    test(
      "start() + step(#default) completes small data in one call",
      func() {
        // Data well below the ~1 MiB internal flush threshold, so a single
        // step() with the default 21 MiB budget returns #done immediately.
        let data : [Nat8] = [10, 20, 30, 40];
        let dec = Gzip.buildDecoder();
        dec.decode(gzip(data));
        switch (dec.start()) {
          case (#err msg) Runtime.trap("start error: " # msg);
          case (#ok _) {};
        };
        switch (dec.step(#default)) {
          case (#err msg) Runtime.trap("step error: " # msg);
          case (#ok(#more)) Runtime.trap("Expected #done for small data with large budget");
          case (#ok(#done)) {};
        };
        expect.array(dec.decompressed(), Nat8.toText, Nat8.equal).equal(data);
      },
    );

  },
);

// ── Suite 5: clear() reuse ────────────────────────────────────────────────

suite(
  "clear() and decoder reuse",
  func() {

    test(
      "clear() resets decompressed output and size to zero",
      func() {
        let data : [Nat8] = [1, 2, 3, 4, 5];
        let dec = Gzip.buildDecoder();
        dec.decode(gzip(data));
        switch (dec.finish()) {
          case (#err msg) Runtime.trap("finish error: " # msg);
          case (#ok _) {};
        };
        expect.nat(dec.decompressedSize()).equal(5);

        dec.clear();

        expect.nat(dec.decompressedSize()).equal(0);
        expect.array(dec.decompressed(), Nat8.toText, Nat8.equal).equal([]);
        expect.nat(dec.chunks().size()).equal(0);
      },
    );

    test(
      "decoder correctly processes two independent streams after clear()",
      func() {
        let dataA : [Nat8] = [11, 22, 33];
        let dataB : [Nat8] = [44, 55, 66, 77];
        let dec = Gzip.buildDecoder();

        dec.decode(gzip(dataA));
        switch (dec.finish()) {
          case (#err msg) Runtime.trap("first finish error: " # msg);
          case (#ok _) {};
        };
        expect.array(dec.decompressed(), Nat8.toText, Nat8.equal).equal(dataA);
        dec.clear();

        dec.decode(gzip(dataB));
        switch (dec.finish()) {
          case (#err msg) Runtime.trap("second finish error: " # msg);
          case (#ok _) {};
        };
        expect.array(dec.decompressed(), Nat8.toText, Nat8.equal).equal(dataB);
      },
    );

    test(
      "clear() mid-stream discards partial input and allows a fresh stream",
      func() {
        let data : [Nat8] = [99, 88, 77];
        let bytes = gzip(data);
        let dec = Gzip.buildDecoder();

        // Feed only the first half of a stream, then abandon it.
        dec.decode(Array.tabulate<Nat8>(bytes.size() / 2, func(i) { bytes[i] }));
        dec.clear();

        // The full fresh stream must decode correctly.
        dec.decode(bytes);
        switch (dec.finish()) {
          case (#err msg) Runtime.trap("finish after clear error: " # msg);
          case (#ok _) {};
        };
        expect.array(dec.decompressed(), Nat8.toText, Nat8.equal).equal(data);
      },
    );

  },
);

// ── Suite 6: Error paths ──────────────────────────────────────────────────

suite(
  "Error paths",
  func() {

    test(
      "invalid magic bytes → #err",
      func() {
        // Valid-length 10-byte header but wrong magic (0x00 0x00 instead of 0x1f 0x8b).
        let bad : [Nat8] = [0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03];
        let dec = Gzip.buildDecoder();
        dec.decode(bad);
        switch (dec.finish()) {
          case (#err _) {};
          case (#ok _) Runtime.trap("Expected #err for invalid magic bytes");
        };
      },
    );

    test(
      "unsupported compression method → #err",
      func() {
        // Correct magic, CM = 0x07 (not deflate which is 0x08).
        let bad : [Nat8] = [0x1f, 0x8b, 0x07, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03];
        let dec = Gzip.buildDecoder();
        dec.decode(bad);
        switch (dec.finish()) {
          case (#err _) {};
          case (#ok _) Runtime.trap("Expected #err for unsupported compression method");
        };
      },
    );

    test(
      "truncated stream with no footer → #err",
      func() {
        // Dropping the 8-byte footer leaves intact deflate data but no CRC32/ISIZE.
        let all = gzip([1, 2, 3, 4, 5]);
        let truncated = Array.tabulate<Nat8>(all.size() - 8, func(i) { all[i] });
        let dec = Gzip.buildDecoder();
        dec.decode(truncated);
        switch (dec.finish()) {
          case (#err _) {};
          case (#ok _) Runtime.trap("Expected #err for truncated stream");
        };
      },
    );

    test(
      "corrupted CRC32 → #err",
      func() {
        // The 8-byte footer layout: [CRC32 LE 4 bytes][ISIZE LE 4 bytes].
        // Flipping index (n-8) corrupts the first byte of CRC32 only.
        let all = gzip([1, 2, 3, 4, 5]);
        let n = all.size();
        let corrupted = Array.tabulate<Nat8>(
          n,
          func(i) { if (i == n - 8) { ^all[i] } else { all[i] } },
        );
        let dec = Gzip.buildDecoder();
        dec.decode(corrupted);
        switch (dec.finish()) {
          case (#err _) {};
          case (#ok _) Runtime.trap("Expected #err for CRC32 mismatch");
        };
      },
    );

    test(
      "corrupted ISIZE → #err",
      func() {
        // Flipping index (n-1) corrupts the last byte of ISIZE only,
        // leaving deflate data and CRC32 intact so the CRC check passes first.
        let all = gzip([1, 2, 3, 4, 5]);
        let n = all.size();
        let corrupted = Array.tabulate<Nat8>(
          n,
          func(i) { if (i == n - 1) { ^all[i] } else { all[i] } },
        );
        let dec = Gzip.buildDecoder();
        dec.decode(corrupted);
        switch (dec.finish()) {
          case (#err _) {};
          case (#ok _) Runtime.trap("Expected #err for ISIZE mismatch");
        };
      },
    );

  },
);
