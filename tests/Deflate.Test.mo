import { test; suite; expect } "mo:test";
import Array "mo:core/Array";
import Nat8 "mo:core/Nat8";
import Nat "mo:core/Nat";
import Runtime "mo:core/Runtime";
import DeflateDecoder "../src/Deflate/Decoder";
import Symbol "../src/Deflate/Symbol";
import CodeTables "../src/Deflate/CodeTables";
import Deflate "../src/Deflate/lib";

// ── Helpers ───────────────────────────────────────────────────────────────

/// Encode `data` with `options`, decode the result, and return the decoded bytes.
func roundTrip(data : [Nat8], options : Deflate.DeflateOptions) : [Nat8] {
  let encoder = Deflate.buildEncoder(options);
  encoder.encode(data);
  let bb = encoder.finish();
  let bytes = bb.getBytes(0, bb.byteSize());

  let decoder = DeflateDecoder.Decoder(bytes);
  switch (decoder.decode()) {
    case (#ok(result)) result;
    case (#err(msg)) Runtime.trap("Decode error: " # msg # " bytes=" # debug_show bytes);
  };
};

/// Encode `data` with `options` and return the compressed byte count.
func compressedSize(data : [Nat8], options : Deflate.DeflateOptions) : Nat {
  let encoder = Deflate.buildEncoder(options);
  encoder.encode(data);
  encoder.finish().byteSize();
};

let fixedOpts : Deflate.DeflateOptions = {
  deflate_block_size = 65_535;
  force_huffman_kind = ?#fixed;
  lzss = #fast;
};
let dynOpts : Deflate.DeflateOptions = {
  deflate_block_size = 65_535;
  force_huffman_kind = ?#dynamic;
  lzss = #best;
};

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
    test("length 3   → code 257", func() { expect.nat(Symbol.lengthMarker(#pointer(1, 3))).equal(257) });
    test("length 10  → code 264", func() { expect.nat(Symbol.lengthMarker(#pointer(1, 10))).equal(264) });
    test("length 11  → code 265", func() { expect.nat(Symbol.lengthMarker(#pointer(1, 11))).equal(265) });
    test("length 18  → code 268", func() { expect.nat(Symbol.lengthMarker(#pointer(1, 18))).equal(268) });
    test("length 19  → code 269", func() { expect.nat(Symbol.lengthMarker(#pointer(1, 19))).equal(269) });
    test("length 34  → code 272", func() { expect.nat(Symbol.lengthMarker(#pointer(1, 34))).equal(272) });
    test("length 35  → code 273", func() { expect.nat(Symbol.lengthMarker(#pointer(1, 35))).equal(273) });
    test("length 66  → code 276", func() { expect.nat(Symbol.lengthMarker(#pointer(1, 66))).equal(276) });
    test("length 67  → code 277", func() { expect.nat(Symbol.lengthMarker(#pointer(1, 67))).equal(277) });
    test("length 130 → code 280", func() { expect.nat(Symbol.lengthMarker(#pointer(1, 130))).equal(280) });
    test("length 131 → code 281", func() { expect.nat(Symbol.lengthMarker(#pointer(1, 131))).equal(281) });
    test("length 257 → code 284", func() { expect.nat(Symbol.lengthMarker(#pointer(1, 257))).equal(284) });
    test("length 258 → code 285", func() { expect.nat(Symbol.lengthMarker(#pointer(1, 258))).equal(285) });
  },
);

suite(
  "Symbol distance boundaries",
  func() {

    // Spot-check every distance code edge from RFC 1951 §3.2.5
    test("#literal    → NO_DISTANCE", func() { expect.nat(Symbol.distanceMarker(#literal(42))).equal(Symbol.NO_DISTANCE) });
    test("#EndOfBlock → NO_DISTANCE", func() { expect.nat(Symbol.distanceMarker(#EndOfBlock)).equal(Symbol.NO_DISTANCE) });
    test("distance 1     → code 0", func() { expect.nat(Symbol.distanceMarker(#pointer(1, 3))).equal(0) });
    test("distance 4     → code 3", func() { expect.nat(Symbol.distanceMarker(#pointer(4, 3))).equal(3) });
    test("distance 5     → code 4", func() { expect.nat(Symbol.distanceMarker(#pointer(5, 3))).equal(4) });
    test("distance 6     → code 4", func() { expect.nat(Symbol.distanceMarker(#pointer(6, 3))).equal(4) });
    test("distance 7     → code 5", func() { expect.nat(Symbol.distanceMarker(#pointer(7, 3))).equal(5) });
    test("distance 9     → code 6", func() { expect.nat(Symbol.distanceMarker(#pointer(9, 3))).equal(6) });
    test("distance 16385 → code 28", func() { expect.nat(Symbol.distanceMarker(#pointer(16385, 3))).equal(28) });
    test("distance 32768 → code 29", func() { expect.nat(Symbol.distanceMarker(#pointer(32768, 3))).equal(29) });
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
          force_huffman_kind = ?#fixed;
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
          force_huffman_kind = ?#dynamic;
          lzss = #best;
        };
        expect.array(roundTrip(data, opts), Nat8.toText, Nat8.equal).equal(data);
      },
    );
  },
);

// ── Suite: Decoder error paths ────────────────────────────────────────────

func decodeBytes(bytes : [Nat8]) : { #ok : [Nat8]; #err : Text } {
  let decoder = DeflateDecoder.Decoder(bytes);
  switch (decoder.decode()) {
    case (#ok(result)) #ok(result);
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
          force_huffman_kind = ?#dynamic;
          lzss = #fast;
        };
        let _ = Deflate.buildEncoder(opts);
      },
    );
  },
);

// ── Suite: Auto Huffman selection (C2) ───────────────────────────────────

suite(
  "Auto Huffman selection",
  func() {

    // For each input, auto (force_huffman_kind = null) must never produce more
    // bytes than the better of forced-fixed / forced-dynamic, and must always
    // round-trip byte-identically.
    func autoOpts(level : Deflate.DeflateOptions) : Deflate.DeflateOptions {
      { level with force_huffman_kind = null };
    };

    func checkAuto(name : Text, data : [Nat8], base : Deflate.DeflateOptions) {
      test(
        name,
        func() {
          let fixedSz = compressedSize(data, { base with force_huffman_kind = ?#fixed });
          let dynSz = compressedSize(data, { base with force_huffman_kind = ?#dynamic });
          let autoSz = compressedSize(data, autoOpts(base));
          // Auto picks the smaller of the two analytic costs; allow it to equal
          // the better (it never exceeds it).
          expect.bool(autoSz <= Nat.min(fixedSz, dynSz)).isTrue();
          // All three encodings decode back to the original bytes.
          expect.array(roundTrip(data, autoOpts(base)), Nat8.toText, Nat8.equal).equal(data);
          expect.array(roundTrip(data, { base with force_huffman_kind = ?#fixed }), Nat8.toText, Nat8.equal).equal(data);
          expect.array(roundTrip(data, { base with force_huffman_kind = ?#dynamic }), Nat8.toText, Nat8.equal).equal(data);
        },
      );
    };

    // Tiny input: dynamic-table header overhead dwarfs the payload, so fixed wins.
    checkAuto("tiny input → fixed-favoured", [0x41, 0x42, 0x43], fixedOpts);

    // Large skewed text-like input: dynamic tables pay off, so dynamic wins.
    let skewed = Array.tabulate<Nat8>(
      4096,
      func(i) = if (i % 8 == 0) 0x7A else 0x61, // mostly 'a', occasional 'z'
    );
    checkAuto("large skewed input → dynamic-favoured", skewed, dynOpts);

    // Incompressible-ish pseudo-random: auto must stay valid and not corrupt.
    let rand = Array.tabulate<Nat8>(2048, func(i) = Nat8.fromNat((i * 2_654_435_761) % 256));
    checkAuto("pseudo-random input", rand, dynOpts);
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
        // exercising the empty_distance guard in DynamicHuffmanCodec.buildFromFreqs.
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

// ── Suite: CodeTables equivalence ─────────────────────────────────────────
//
// CodeTables replaces the inline length if-else cascade and the distance
// while-loop on the encoder hot path. Its (code, extra-bits, extra-value)
// output must be byte-identical to the previous logic for every legal length
// (3..258) and distance (1..32768), otherwise compressed output would change.

// Reference length encoding (mirrors the previous inline cascade in Block.flush).
func refLength(len : Nat) : (Nat, Nat, Nat) {
  if (len <= 10) { (257 + (len - 3), 0, 0) } else if (len <= 18) {
    (265 + (len - 11) / 2, 1, (len - 11) % 2);
  } else if (len <= 34) {
    (269 + (len - 19) / 4, 2, (len - 19) % 4);
  } else if (len <= 66) {
    (273 + (len - 35) / 8, 3, (len - 35) % 8);
  } else if (len <= 130) {
    (277 + (len - 67) / 16, 4, (len - 67) % 16);
  } else if (len < 258) {
    (281 + (len - 131) / 32, 5, (len - 131) % 32);
  } else { (285, 0, 0) };
};

// Reference distance encoding (mirrors the previous inline while-loop).
func refDistance(dist : Nat) : (Nat, Nat, Nat) {
  if (dist <= 4) { (dist - 1, 0, 0) } else {
    var b = 1;
    var base = 4;
    while (base * 2 < dist) { b += 1; base *= 2 };
    let half = base / 2;
    let code = 2 * b + 2 + (if (dist < base + half + 1) 0 else 1);
    (code, b, (dist - base - 1) % half);
  };
};

suite(
  "CodeTables equivalence",
  func() {

    let t = CodeTables.CodeTables();

    test(
      "length codes 3..258 match reference + Symbol.lenCode",
      func() {
        var len = 3;
        while (len <= 258) {
          let (rCode, rBits, rVal) = refLength(len);
          expect.nat(t.lengthCode[len - 3]).equal(rCode);
          expect.nat(t.lengthExtraBits[len - 3]).equal(rBits);
          expect.nat(t.lengthExtraVal[len - 3]).equal(rVal);
          expect.nat(t.lengthCode[len - 3]).equal(Symbol.lenCode(len));
          len += 1;
        };
      },
    );

    test(
      "distance codes 1..32768 match reference + Symbol.distCode",
      func() {
        var dist = 1;
        while (dist <= 32_768) {
          let (rCode, rBits, rVal) = refDistance(dist);
          let code = t.distCodeOf(dist);
          expect.nat(code).equal(rCode);
          expect.nat(code).equal(Symbol.distCode(dist));
          expect.nat(t.distExtraBits[code]).equal(rBits);
          expect.nat(dist - t.distBase[code]).equal(rVal);
          dist += 1;
        };
      },
    );
  },
);
