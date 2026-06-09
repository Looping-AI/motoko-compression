import { test; suite; expect } "mo:test";
import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Nat8 "mo:core/Nat8";
import Runtime "mo:core/Runtime";
import Text "mo:core/Text";

import Gzip "../src/Gzip/lib";

// ── Helpers ───────────────────────────────────────────────────────────────

func assertDecompress(dec : Gzip.Decoder, bytes : [Nat8], expected : [Nat8]) {
  switch (Gzip.decompress(dec, bytes)) {
    case (#err msg) Runtime.trap("Unexpected error: " # msg);
    case (#ok out) expect.array(out, Nat8.toText, Nat8.equal).equal(expected);
  };
};

// ── Suite 1: compress / decompress round-trip ─────────────────────────────

suite(
  "compress / decompress helpers",
  func() {
    let enc = Gzip.EncoderBuilder().build();
    let dec = Gzip.Decoder();

    test(
      "empty data",
      func() {
        let compressed = Gzip.compress(enc, []);
        assertDecompress(dec, compressed, []);
      },
    );

    test(
      "single byte",
      func() {
        let data : [Nat8] = [0x42];
        let compressed = Gzip.compress(enc, data);
        assertDecompress(dec, compressed, data);
      },
    );

    test(
      "compressible data (repeated pattern)",
      func() {
        let data = Array.repeat<Nat8>(0xAB, 4096);
        let compressed = Gzip.compress(enc, data);
        // Highly compressible — verify the compressed form is smaller and round-trips.
        expect.bool(compressed.size() < data.size()).isTrue();
        assertDecompress(dec, compressed, data);
      },
    );

    test(
      "incompressible data (all distinct bytes)",
      func() {
        let data = Array.tabulate<Nat8>(256, func(i) = Nat8.fromNat(i));
        let compressed = Gzip.compress(enc, data);
        assertDecompress(dec, compressed, data);
      },
    );
  },
);

// ── Suite 2: encoder / decoder reuse ─────────────────────────────────────

suite(
  "object reuse across calls",
  func() {
    let enc = Gzip.EncoderBuilder().build();
    let dec = Gzip.Decoder();

    test(
      "encoder reused for three distinct payloads",
      func() {
        let payloads : [[Nat8]] = [
          Array.repeat<Nat8>(0x01, 100),
          Array.repeat<Nat8>(0x02, 200),
          Array.repeat<Nat8>(0x03, 50),
        ];
        for (data in payloads.vals()) {
          let compressed = Gzip.compress(enc, data);
          assertDecompress(dec, compressed, data);
        };
      },
    );

    test(
      "decoder reused for three distinct compressed streams",
      func() {
        let enc2 = Gzip.EncoderBuilder().build();
        let streams : [([Nat8], [Nat8])] = [
          (Gzip.compress(enc2, [0x11, 0x22, 0x33]), [0x11, 0x22, 0x33]),
          (Gzip.compress(enc2, [0xAA, 0xBB]), [0xAA, 0xBB]),
          (Gzip.compress(enc2, []), []),
        ];
        for ((compressed, expected) in streams.vals()) {
          assertDecompress(dec, compressed, expected);
        };
      },
    );
  },
);

// ── Suite 3: compressText helper ──────────────────────────────────────────

suite(
  "compressText",
  func() {
    let enc = Gzip.EncoderBuilder().build();
    let dec = Gzip.Decoder();

    test(
      "ASCII text round-trips as UTF-8 bytes",
      func() {
        let t = "Hello, Gzip!";
        let compressed = Gzip.compressText(enc, t);
        let expected = Blob.toArray(Text.encodeUtf8(t));
        assertDecompress(dec, compressed, expected);
      },
    );

    test(
      "multi-byte Unicode text round-trips as UTF-8 bytes",
      func() {
        let t = "Motoko \u{1F680} compression \u{2728}";
        let compressed = Gzip.compressText(enc, t);
        let expected = Blob.toArray(Text.encodeUtf8(t));
        assertDecompress(dec, compressed, expected);
      },
    );

    test(
      "empty string",
      func() {
        let compressed = Gzip.compressText(enc, "");
        assertDecompress(dec, compressed, []);
      },
    );
  },
);

// ── Suite 4: compressBlob helper ──────────────────────────────────────────

suite(
  "compressBlob",
  func() {
    let enc = Gzip.EncoderBuilder().build();
    let dec = Gzip.Decoder();

    test(
      "blob round-trips byte-for-byte",
      func() {
        let data : [Nat8] = [0x00, 0xFF, 0x80, 0x01, 0xFE];
        let b = Blob.fromArray(data);
        let compressed = Gzip.compressBlob(enc, b);
        assertDecompress(dec, compressed, data);
      },
    );

    test(
      "empty blob",
      func() {
        let compressed = Gzip.compressBlob(enc, Blob.fromArray([]));
        assertDecompress(dec, compressed, []);
      },
    );
  },
);

// ── Suite 5: decompress error handling ───────────────────────────────────

suite(
  "decompress error handling",
  func() {
    let dec = Gzip.Decoder();

    test(
      "garbage bytes return #err",
      func() {
        let garbage : [Nat8] = [0x00, 0x01, 0x02, 0x03, 0x04];
        switch (Gzip.decompress(dec, garbage)) {
          case (#ok _) Runtime.trap("Expected error for garbage input");
          case (#err _) {};
        };
      },
    );

    test(
      "truncated gzip stream returns #err",
      func() {
        let enc = Gzip.EncoderBuilder().build();
        let full = Gzip.compress(enc, Array.repeat<Nat8>(0xAA, 100));
        // Keep only the header bytes — strip the body.
        let truncated = Array.tabulate<Nat8>(10, func(i) = full[i]);
        switch (Gzip.decompress(dec, truncated)) {
          case (#ok _) Runtime.trap("Expected error for truncated input");
          case (#err _) {};
        };
      },
    );
  },
);
