import { test; suite; expect } "mo:test";
import Array  "mo:core/Array";
import Nat    "mo:core/Nat";
import Nat8   "mo:core/Nat8";
import Nat16  "mo:core/Nat16";
import Runtime "mo:core/Runtime";
import BitReader      "../src/BitReader";
import DeflateDecoder "../src/Deflate/Decoder";
import Symbol         "../src/Deflate/Symbol";
import Deflate        "../src/Deflate/lib";

// ── Helpers ───────────────────────────────────────────────────────────────

/// Encode `data` with `options`, decode the result, and return the decoded bytes.
func roundTrip(data : [Nat8], options : Deflate.DeflateOptions) : [Nat8] {
  let encoder = Deflate.buildEncoder(options);
  encoder.encode(data);
  let bb    = encoder.finish();
  let bytes = bb.getBytes(0, bb.byteSize());

  let reader  = BitReader.BitReader();
  reader.addBytes(bytes);
  let decoder = DeflateDecoder.Decoder(reader, null);
  let res = decoder.finish();
  switch res {
    case (#ok(_)) {};
    case (#err(msg)) Runtime.trap("Decode error: " # msg # " bytes=" # debug_show bytes);
  };
  decoder.toArray()
};

let rawOpts  : Deflate.DeflateOptions = { block_size = 65_535; dynamic_huffman = false; lzss = null };
let fixedOpts: Deflate.DeflateOptions = { block_size = 65_535; dynamic_huffman = false; lzss = ?#fast };
let dynOpts  : Deflate.DeflateOptions = { block_size = 65_535; dynamic_huffman = true;  lzss = ?#best };

// ── Symbol helpers ────────────────────────────────────────────────────────

func lengthCodeMarker(sym : Symbol.Symbol) : Nat {
  let (m, _, _) = Symbol.lengthCode(sym);
  Nat16.toNat(m)
};

// ── Suite: Symbol encoding ────────────────────────────────────────────────

suite("Symbol encoding", func() {

  test("lengthCode #EndOfBlock returns 256", func() {
    expect.nat(lengthCodeMarker(#EndOfBlock)).equal(256);
  });

  test("lengthCode #literal(65) returns 65", func() {
    expect.nat(lengthCodeMarker(#literal(65))).equal(65);
  });

  test("lengthCode #pointer length=3 returns 257", func() {
    expect.nat(lengthCodeMarker(#pointer(1, 3))).equal(257);
  });

  test("lengthCode #pointer length=10 returns 264", func() {
    expect.nat(lengthCodeMarker(#pointer(1, 10))).equal(264);
  });

  test("lengthCode #pointer length=258 returns 285", func() {
    expect.nat(lengthCodeMarker(#pointer(1, 258))).equal(285);
  });

  test("distanceCode null for #literal", func() {
    switch (Symbol.distanceCode(#literal(42))) {
      case null {};
      case (?_) Runtime.trap("Expected null for #literal");
    };
  });

  test("distanceCode #pointer distance=1 returns code 0", func() {
    let dc = Symbol.distanceCode(#pointer(1, 3));
    switch dc {
      case (?(code, extra, _)) {
        expect.nat(code).equal(0);
        expect.nat(extra).equal(0);
      };
      case null Runtime.trap("Expected Some");
    };
  });

  test("distanceCode #pointer distance=5 returns code 4", func() {
    let dc = Symbol.distanceCode(#pointer(5, 3));
    switch dc {
      case (?(code, extra, _)) {
        expect.nat(code).equal(4);
        expect.nat(extra).equal(1);
      };
      case null Runtime.trap("Expected Some");
    };
  });
});

// ── Suite: Raw block round-trip ───────────────────────────────────────────

suite("Raw block round-trip", func() {

  test("empty input", func() {
    expect.array(roundTrip([], rawOpts), Nat8.toText, Nat8.equal).equal([]);
  });

  test("single byte", func() {
    expect.array(roundTrip([42], rawOpts), Nat8.toText, Nat8.equal).equal([42]);
  });

  test("Hello World!", func() {
    let data : [Nat8] = [72, 101, 108, 108, 111, 32, 87, 111, 114, 108, 100, 33];
    expect.array(roundTrip(data, rawOpts), Nat8.toText, Nat8.equal).equal(data);
  });

  test("all zeros 256 bytes", func() {
    let arr = Array.tabulate<Nat8>(256, func(_) { 0 });
    expect.array(roundTrip(arr, rawOpts), Nat8.toText, Nat8.equal).equal(arr);
  });
});

// ── Suite: Fixed Huffman round-trip ──────────────────────────────────────

suite("Fixed Huffman round-trip", func() {

  test("empty input", func() {
    expect.array(roundTrip([], fixedOpts), Nat8.toText, Nat8.equal).equal([]);
  });

  test("single byte", func() {
    expect.array(roundTrip([99], fixedOpts), Nat8.toText, Nat8.equal).equal([99]);
  });

  test("Hello World!", func() {
    let data : [Nat8] = [72, 101, 108, 108, 111, 32, 87, 111, 114, 108, 100, 33];
    expect.array(roundTrip(data, fixedOpts), Nat8.toText, Nat8.equal).equal(data);
  });

  test("repeated pattern compresses and decompresses", func() {
    let data : [Nat8] = [65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65];
    expect.array(roundTrip(data, fixedOpts), Nat8.toText, Nat8.equal).equal(data);
  });
});

// ── Suite: Dynamic Huffman round-trip ────────────────────────────────────

suite("Dynamic Huffman round-trip", func() {

  test("empty input", func() {
    expect.array(roundTrip([], dynOpts), Nat8.toText, Nat8.equal).equal([]);
  });

  test("single byte", func() {
    expect.array(roundTrip([77], dynOpts), Nat8.toText, Nat8.equal).equal([77]);
  });

  test("Hello World!", func() {
    let data : [Nat8] = [72, 101, 108, 108, 111, 32, 87, 111, 114, 108, 100, 33];
    expect.array(roundTrip(data, dynOpts), Nat8.toText, Nat8.equal).equal(data);
  });

  test("repeated pattern", func() {
    let data : [Nat8] = [1, 2, 3, 1, 2, 3, 1, 2, 3, 1, 2, 3, 1, 2, 3];
    expect.array(roundTrip(data, dynOpts), Nat8.toText, Nat8.equal).equal(data);
  });

  test("longer text", func() {
    // "abcdefghij" × 3
    let data : [Nat8] = [
      97,98,99,100,101,102,103,104,105,106,
      97,98,99,100,101,102,103,104,105,106,
      97,98,99,100,101,102,103,104,105,106,
    ];
    expect.array(roundTrip(data, dynOpts), Nat8.toText, Nat8.equal).equal(data);
  });
});
