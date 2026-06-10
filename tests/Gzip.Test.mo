import { test; suite; expect } "mo:test";
import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Nat8 "mo:core/Nat8";
import Runtime "mo:core/Runtime";
import Text "mo:core/Text";

import Gzip "../src/Gzip/lib";

func assertDecompress(dec : Gzip.Decoder, bytes : [Nat8], expected : [Nat8]) {
  switch (Gzip.decompress(dec, bytes)) {
    case (#err msg) Runtime.trap("Unexpected error: " # msg);
    case (#ok out) expect.array(out, Nat8.toText, Nat8.equal).equal(expected);
  };
};

suite(
  "compress / decompress helpers",
  func() {
    let enc = Gzip.buildEncoder(Gzip.defaultOptions());
    let dec = Gzip.buildDecoder();

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

suite(
  "stateful codec builders",
  func() {
    test(
      "encoder reused for three distinct payloads",
      func() {
        let enc = Gzip.buildEncoder(Gzip.defaultOptions());
        let dec = Gzip.buildDecoder();
        let payloads : [[Nat8]] = [
          Array.repeat<Nat8>(0x01, 100),
          Array.repeat<Nat8>(0x02, 200),
          Array.repeat<Nat8>(0x03, 50),
        ];
        for (data in payloads.vals()) {
          enc.encode(data);
          enc.finish();
          let compressed = enc.compressed();
          enc.clear();

          dec.clear();
          dec.decode(compressed);
          switch (dec.finish()) {
            case (#err msg) Runtime.trap("Decode error: " # msg);
            case (#ok _) {};
          };
          expect.array(dec.decompressed(), Nat8.toText, Nat8.equal).equal(data);
        };
      },
    );
  },
);

suite(
  "compressText",
  func() {
    let enc = Gzip.buildEncoder(Gzip.defaultOptions());
    let dec = Gzip.buildDecoder();

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

suite(
  "compressBlob",
  func() {
    let enc = Gzip.buildEncoder(Gzip.defaultOptions());
    let dec = Gzip.buildDecoder();

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

suite(
  "decompress error handling",
  func() {
    let dec = Gzip.buildDecoder();
    let enc = Gzip.buildEncoder(Gzip.defaultOptions());

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
        let full = Gzip.compress(enc, Array.repeat<Nat8>(0xAA, 100));
        let truncated = Array.tabulate<Nat8>(10, func(i) = full[i]);
        switch (Gzip.decompress(dec, truncated)) {
          case (#ok _) Runtime.trap("Expected error for truncated input");
          case (#err _) {};
        };
      },
    );
  },
);
