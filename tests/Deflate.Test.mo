import { test; suite; expect } "mo:test";
import Array "mo:core/Array";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat16 "mo:core/Nat16";
import Runtime "mo:core/Runtime";
import BitReader "../src/internal/BitReader";
import DeflateDecoder "../src/Deflate/Decoder";
import Symbol "../src/Deflate/Symbol";
import Deflate "../src/Deflate/lib";

// ── Helpers ───────────────────────────────────────────────────────────────

/// Encode `data` with `options`, decode the result, and return the decoded bytes.
func roundTrip(data : [Nat8], options : Deflate.DeflateOptions) : [Nat8] {
  let encoder = Deflate.buildEncoder(options);
  encoder.encode(data);
  let bb = encoder.finish();
  let bytes = bb.getBytes(0, bb.byteSize());

  let reader = BitReader.BitReader();
  reader.addBytes(bytes);
  let decoder = DeflateDecoder.Decoder(reader, null);
  let res = decoder.finish();
  switch res {
    case (#ok(_)) {};
    case (#err(msg)) Runtime.trap("Decode error: " # msg # " bytes=" # debug_show bytes);
  };
  decoder.toArray();
};

let fixedOpts : Deflate.DeflateOptions = {
  deflate_block_size = 65_535;
  dynamic_huffman = false;
  lzss = #fast;
};
let dynOpts : Deflate.DeflateOptions = {
  deflate_block_size = 65_535;
  dynamic_huffman = true;
  lzss = #best;
};

// ── Symbol helpers ────────────────────────────────────────────────────────

func lengthCodeMarker(sym : Symbol.Symbol) : Nat {
  let (m, _, _) = Symbol.lengthCode(sym);
  Nat16.toNat(m);
};

// ── Suite: Symbol encoding ────────────────────────────────────────────────

suite(
  "Symbol encoding",
  func() {

    test(
      "lengthCode #EndOfBlock returns 256",
      func() {
        expect.nat(lengthCodeMarker(#EndOfBlock)).equal(256);
      },
    );

    test(
      "lengthCode #literal(65) returns 65",
      func() {
        expect.nat(lengthCodeMarker(#literal(65))).equal(65);
      },
    );

    test(
      "lengthCode #pointer length=3 returns 257",
      func() {
        expect.nat(lengthCodeMarker(#pointer(1, 3))).equal(257);
      },
    );

    test(
      "lengthCode #pointer length=10 returns 264",
      func() {
        expect.nat(lengthCodeMarker(#pointer(1, 10))).equal(264);
      },
    );

    test(
      "lengthCode #pointer length=258 returns 285",
      func() {
        expect.nat(lengthCodeMarker(#pointer(1, 258))).equal(285);
      },
    );

    test(
      "distanceCode null for #literal",
      func() {
        switch (Symbol.distanceCode(#literal(42))) {
          case null {};
          case (?_) Runtime.trap("Expected null for #literal");
        };
      },
    );

    test(
      "distanceCode #pointer distance=1 returns code 0",
      func() {
        let dc = Symbol.distanceCode(#pointer(1, 3));
        switch dc {
          case (?(code, extra, _)) {
            expect.nat(code).equal(0);
            expect.nat(extra).equal(0);
          };
          case null Runtime.trap("Expected Some");
        };
      },
    );

    test(
      "distanceCode #pointer distance=5 returns code 4",
      func() {
        let dc = Symbol.distanceCode(#pointer(5, 3));
        switch dc {
          case (?(code, extra, _)) {
            expect.nat(code).equal(4);
            expect.nat(extra).equal(1);
          };
          case null Runtime.trap("Expected Some");
        };
      },
    );
  },
);

// ── Suite: Fixed Huffman round-trip ──────────────────────────────────────

suite(
  "Fixed Huffman round-trip",
  func() {

    test(
      "empty input",
      func() {
        expect.array(roundTrip([], fixedOpts), Nat8.toText, Nat8.equal).equal([]);
      },
    );

    test(
      "single byte",
      func() {
        expect.array(roundTrip([99], fixedOpts), Nat8.toText, Nat8.equal).equal([99]);
      },
    );

    test(
      "Hello World!",
      func() {
        let data : [Nat8] = [72, 101, 108, 108, 111, 32, 87, 111, 114, 108, 100, 33];
        expect.array(roundTrip(data, fixedOpts), Nat8.toText, Nat8.equal).equal(data);
      },
    );

    test(
      "repeated pattern compresses and decompresses",
      func() {
        let data : [Nat8] = [65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65];
        expect.array(roundTrip(data, fixedOpts), Nat8.toText, Nat8.equal).equal(data);
      },
    );
  },
);

// ── Suite: Dynamic Huffman round-trip ────────────────────────────────────

suite(
  "Dynamic Huffman round-trip",
  func() {

    test(
      "empty input",
      func() {
        expect.array(roundTrip([], dynOpts), Nat8.toText, Nat8.equal).equal([]);
      },
    );

    test(
      "single byte",
      func() {
        expect.array(roundTrip([77], dynOpts), Nat8.toText, Nat8.equal).equal([77]);
      },
    );

    test(
      "Hello World!",
      func() {
        let data : [Nat8] = [72, 101, 108, 108, 111, 32, 87, 111, 114, 108, 100, 33];
        expect.array(roundTrip(data, dynOpts), Nat8.toText, Nat8.equal).equal(data);
      },
    );

    test(
      "repeated pattern",
      func() {
        let data : [Nat8] = [1, 2, 3, 1, 2, 3, 1, 2, 3, 1, 2, 3, 1, 2, 3];
        expect.array(roundTrip(data, dynOpts), Nat8.toText, Nat8.equal).equal(data);
      },
    );

    test(
      "longer text",
      func() {
        // "abcdefghij" × 3
        let data : [Nat8] = [
          97,
          98,
          99,
          100,
          101,
          102,
          103,
          104,
          105,
          106,
          97,
          98,
          99,
          100,
          101,
          102,
          103,
          104,
          105,
          106,
          97,
          98,
          99,
          100,
          101,
          102,
          103,
          104,
          105,
          106,
        ];
        expect.array(roundTrip(data, dynOpts), Nat8.toText, Nat8.equal).equal(data);
      },
    );
  },
);

// ── Suite: Symbol length / distance boundaries ────────────────────────────

func lengthTuple(sym : Symbol.Symbol) : (Nat, Nat, Nat) {
  let (m, eb, off) = Symbol.lengthCode(sym);
  (Nat16.toNat(m), eb, Nat16.toNat(off));
};

func distanceTuple(sym : Symbol.Symbol) : ?(Nat, Nat, Nat) {
  switch (Symbol.distanceCode(sym)) {
    case null null;
    case (?(m, eb, off)) ?(m, eb, Nat16.toNat(off));
  };
};

suite(
  "Symbol length boundaries",
  func() {

    // RFC 1951 §3.2.5: length code ranges
    //   3-10   → codes 257-264 (0 extra bits)
    //   11-18  → codes 265-268 (1 extra bit)
    //   19-34  → codes 269-272 (2 extra bits)
    //   35-66  → codes 273-276 (3 extra bits)
    //   67-130 → codes 277-280 (4 extra bits)
    //   131-257→ codes 281-284 (5 extra bits)
    //   258    → code  285     (0 extra bits)
    test("length 3   → (257, 0, 0)", func() { expect.text(debug_show lengthTuple(#pointer(1, 3))).equal(debug_show (257 : Nat, 0 : Nat, 0 : Nat)) });
    test("length 10  → (264, 0, 0)", func() { expect.text(debug_show lengthTuple(#pointer(1, 10))).equal(debug_show (264 : Nat, 0 : Nat, 0 : Nat)) });
    test("length 11  → (265, 1, 0)", func() { expect.text(debug_show lengthTuple(#pointer(1, 11))).equal(debug_show (265 : Nat, 1 : Nat, 0 : Nat)) });
    test("length 18  → (268, 1, 1)", func() { expect.text(debug_show lengthTuple(#pointer(1, 18))).equal(debug_show (268 : Nat, 1 : Nat, 1 : Nat)) });
    test("length 19  → (269, 2, 0)", func() { expect.text(debug_show lengthTuple(#pointer(1, 19))).equal(debug_show (269 : Nat, 2 : Nat, 0 : Nat)) });
    test("length 34  → (272, 2, 3)", func() { expect.text(debug_show lengthTuple(#pointer(1, 34))).equal(debug_show (272 : Nat, 2 : Nat, 3 : Nat)) });
    test("length 35  → (273, 3, 0)", func() { expect.text(debug_show lengthTuple(#pointer(1, 35))).equal(debug_show (273 : Nat, 3 : Nat, 0 : Nat)) });
    test("length 66  → (276, 3, 7)", func() { expect.text(debug_show lengthTuple(#pointer(1, 66))).equal(debug_show (276 : Nat, 3 : Nat, 7 : Nat)) });
    test("length 67  → (277, 4, 0)", func() { expect.text(debug_show lengthTuple(#pointer(1, 67))).equal(debug_show (277 : Nat, 4 : Nat, 0 : Nat)) });
    test("length 130 → (280, 4, 15)", func() { expect.text(debug_show lengthTuple(#pointer(1, 130))).equal(debug_show (280 : Nat, 4 : Nat, 15 : Nat)) });
    test("length 131 → (281, 5, 0)", func() { expect.text(debug_show lengthTuple(#pointer(1, 131))).equal(debug_show (281 : Nat, 5 : Nat, 0 : Nat)) });
    test("length 257 → (284, 5, 30)", func() { expect.text(debug_show lengthTuple(#pointer(1, 257))).equal(debug_show (284 : Nat, 5 : Nat, 30 : Nat)) });
    test("length 258 → (285, 0, 0)", func() { expect.text(debug_show lengthTuple(#pointer(1, 258))).equal(debug_show (285 : Nat, 0 : Nat, 0 : Nat)) });
  },
);

suite(
  "Symbol distance boundaries",
  func() {

    // Spot-check every distance code edge from RFC 1951 §3.2.5
    test("distance 1     → code 0  (eb 0)", func() { expect.text(debug_show distanceTuple(#pointer(1, 3))).equal(debug_show (?(0 : Nat, 0 : Nat, 0 : Nat))) });
    test("distance 4     → code 3  (eb 0)", func() { expect.text(debug_show distanceTuple(#pointer(4, 3))).equal(debug_show (?(3 : Nat, 0 : Nat, 0 : Nat))) });
    test("distance 5     → code 4  (eb 1, 0)", func() { expect.text(debug_show distanceTuple(#pointer(5, 3))).equal(debug_show (?(4 : Nat, 1 : Nat, 0 : Nat))) });
    test("distance 6     → code 4  (eb 1, 1)", func() { expect.text(debug_show distanceTuple(#pointer(6, 3))).equal(debug_show (?(4 : Nat, 1 : Nat, 1 : Nat))) });
    test("distance 7     → code 5  (eb 1, 0)", func() { expect.text(debug_show distanceTuple(#pointer(7, 3))).equal(debug_show (?(5 : Nat, 1 : Nat, 0 : Nat))) });
    test("distance 9     → code 6  (eb 2, 0)", func() { expect.text(debug_show distanceTuple(#pointer(9, 3))).equal(debug_show (?(6 : Nat, 2 : Nat, 0 : Nat))) });
    test("distance 16385 → code 28 (eb 13, 0)", func() { expect.text(debug_show distanceTuple(#pointer(16385, 3))).equal(debug_show (?(28 : Nat, 13 : Nat, 0 : Nat))) });
    test("distance 32768 → code 29 (eb 13, 8191)", func() { expect.text(debug_show distanceTuple(#pointer(32768, 3))).equal(debug_show (?(29 : Nat, 13 : Nat, 8191 : Nat))) });
  },
);

// ── Suite: Fixed Huffman full-byte coverage ───────────────────────────────

suite(
  "Fixed Huffman full-range round-trip",
  func() {

    test(
      "all bytes 0..127 (8-bit literal range)",
      func() {
        let data = Array.tabulate<Nat8>(128, func(i) = Nat8.fromNat(i));
        expect.array(roundTrip(data, fixedOpts), Nat8.toText, Nat8.equal).equal(data);
      },
    );

    test(
      "all bytes 128..255 (9-bit literal range)",
      func() {
        let data = Array.tabulate<Nat8>(128, func(i) = Nat8.fromNat(128 + i));
        expect.array(roundTrip(data, fixedOpts), Nat8.toText, Nat8.equal).equal(data);
      },
    );

    test(
      "all bytes 0..255 (mixed 8-bit + 9-bit)",
      func() {
        let data = Array.tabulate<Nat8>(256, func(i) = Nat8.fromNat(i));
        expect.array(roundTrip(data, fixedOpts), Nat8.toText, Nat8.equal).equal(data);
      },
    );
  },
);

// ── Suite: Long-pointer / high-distance round-trips ───────────────────────

suite(
  "Long-pointer round-trips",
  func() {

    // 300 identical bytes → LZSS will emit at least one pointer of length 258.
    test(
      "300×A (exercises max length 258)",
      func() {
        let data = Array.tabulate<Nat8>(300, func(_) = 65);
        expect.array(roundTrip(data, fixedOpts), Nat8.toText, Nat8.equal).equal(data);
        expect.array(roundTrip(data, dynOpts), Nat8.toText, Nat8.equal).equal(data);
      },
    );

    // Periodic pattern over ~1 KB → exercises distances > 4 and length extra bits.
    test(
      "1024 byte periodic pattern (16-byte period)",
      func() {
        let data = Array.tabulate<Nat8>(1024, func(i) = Nat8.fromNat(i % 16));
        expect.array(roundTrip(data, fixedOpts), Nat8.toText, Nat8.equal).equal(data);
        expect.array(roundTrip(data, dynOpts), Nat8.toText, Nat8.equal).equal(data);
      },
    );

    // Forces distance into the >4 codes range when an inner match references a
    // far-back position.
    test(
      "2048 bytes ascending mod 251 (no long matches)",
      func() {
        let data = Array.tabulate<Nat8>(2048, func(i) = Nat8.fromNat(i % 251));
        expect.array(roundTrip(data, dynOpts), Nat8.toText, Nat8.equal).equal(data);
      },
    );
  },
);

// ── Suite: Multi-block round-trips ────────────────────────────────────────

suite(
  "Multi-block round-trips",
  func() {

    test(
      "fixed Huffman, 1000 bytes, block_size=100",
      func() {
        let data = Array.tabulate<Nat8>(1000, func(i) = Nat8.fromNat(i % 256));
        let opts : Deflate.DeflateOptions = {
          deflate_block_size = 100;
          dynamic_huffman = false;
          lzss = #fast;
        };
        expect.array(roundTrip(data, opts), Nat8.toText, Nat8.equal).equal(data);
      },
    );

    test(
      "dynamic Huffman, 500 bytes, block_size=64",
      func() {
        let data = Array.tabulate<Nat8>(500, func(i) = Nat8.fromNat((i * 7) % 256));
        let opts : Deflate.DeflateOptions = {
          deflate_block_size = 64;
          dynamic_huffman = true;
          lzss = #best;
        };
        expect.array(roundTrip(data, opts), Nat8.toText, Nat8.equal).equal(data);
      },
    );
  },
);

// ── Suite: Decoder error paths ────────────────────────────────────────────

func decodeBytes(bytes : [Nat8]) : { #ok : [Nat8]; #err : Text } {
  let reader = BitReader.BitReader();
  reader.addBytes(bytes);
  let decoder = DeflateDecoder.Decoder(reader, null);
  switch (decoder.finish()) {
    case (#ok(_)) #ok(decoder.toArray());
    case (#err(msg)) #err(msg);
  };
};

func expectErr(res : { #ok : [Nat8]; #err : Text }, label_ : Text) {
  switch res {
    case (#ok(bs)) Runtime.trap(label_ # " expected error, got #ok " # debug_show bs);
    case (#err(_)) {};
  };
};

suite(
  "Decoder error paths",
  func() {

    test(
      "invalid BTYPE = 3 rejected",
      func() {
        // First byte = 0b00000111: BFINAL=1, BTYPE=11 (bits laid LSB-first).
        expectErr(decodeBytes([0x07]), "BTYPE=3");
      },
    );

    test(
      "raw block with LEN/NLEN mismatch",
      func() {
        // BFINAL=1, BTYPE=00 → byte 0x01; pad to next byte; LEN=0; NLEN=0 (should be 0xFFFF).
        expectErr(decodeBytes([0x01, 0x00, 0x00, 0x00, 0x00]), "LEN/NLEN mismatch");
      },
    );

    test(
      "empty bitstream is treated as truncated",
      func() {
        expectErr(decodeBytes([]), "empty stream");
      },
    );

    test(
      "non-final raw block followed by EOF is truncated",
      func() {
        // BFINAL=0, BTYPE=00, LEN=0, NLEN=0xFFFF → valid empty non-final block,
        // but no further block exists. Decoder must report truncation.
        expectErr(decodeBytes([0x00, 0x00, 0x00, 0xFF, 0xFF]), "truncated after non-final");
      },
    );

    test(
      "two empty raw blocks (non-final + final) decode to []",
      func() {
        let bytes : [Nat8] = [
          0x00,
          0x00,
          0x00,
          0xFF,
          0xFF, // non-final empty raw
          0x01,
          0x00,
          0x00,
          0xFF,
          0xFF, // final empty raw
        ];
        switch (decodeBytes(bytes)) {
          case (#ok(out)) expect.array(out, Nat8.toText, Nat8.equal).equal([]);
          case (#err(msg)) Runtime.trap("expected #ok, got #err " # msg);
        };
      },
    );
  },
);

// ── Suite: Encoder construction validation ────────────────────────────────

suite(
  "Encoder construction",
  func() {

    test(
      "compressed block_size > 65535 accepted",
      func() {
        let opts : Deflate.DeflateOptions = {
          deflate_block_size = 100_000;
          dynamic_huffman = true;
          lzss = #fast;
        };
        let _ = Deflate.buildEncoder(opts);
      },
    );
  },
);

// ── Suite: Dynamic Huffman edge cases ─────────────────────────────────────

suite(
  "Dynamic Huffman edge cases",
  func() {

    test(
      "input with zero pointers (only literals, distance tree degenerate)",
      func() {
        // 30 distinct bytes → LZSS finds no matches → dist-freq table all zero,
        // exercising the empty_distance hack in DynamicHuffmanCodec.build.
        let data = Array.tabulate<Nat8>(30, func(i) = Nat8.fromNat(i));
        expect.array(roundTrip(data, dynOpts), Nat8.toText, Nat8.equal).equal(data);
      },
    );

    test(
      "highly repetitive input (long zero-runs in bitwidth tables)",
      func() {
        // 500 bytes alternating between 2 values → very narrow literal alphabet,
        // most literal-code bitwidths are zero → exercises RLE codes 17/18 in save().
        let data = Array.tabulate<Nat8>(500, func(i) = if (i % 2 == 0) 0 else 1);
        expect.array(roundTrip(data, dynOpts), Nat8.toText, Nat8.equal).equal(data);
      },
    );
  },
);
