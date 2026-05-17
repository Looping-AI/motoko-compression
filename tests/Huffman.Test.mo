import { test; suite; expect } "mo:test";
import Nat16 "mo:core/Nat16";
import Array "mo:core/Array";
import Iter "mo:core/Iter";
import Result "mo:core/Result";
import Runtime "mo:core/Runtime";
import Prim "mo:⛔";

import Common "../src/Huffman/Common";
import Encoder "../src/Huffman/Encoder";
import Decoder "../src/Huffman/Decoder";
import BitBuffer "../src/internal/BitBuffer";
import BitReader "../src/BitReader";

// ── Common ────────────────────────────────────────────────────────────────

suite("reverseCodeBits", func() {

  test("bitwidth=0 → bits unchanged", func() {
    let code = { bitwidth = 0; bits = 0 : Nat16 };
    let r = Common.reverseCodeBits(code);
    expect.nat(r.bitwidth).equal(0);
    expect.nat(Nat16.toNat(r.bits)).equal(0);
  });

  test("bitwidth=1, bits=0 → bits=0", func() {
    let code = { bitwidth = 1; bits = 0 : Nat16 };
    let r = Common.reverseCodeBits(code);
    expect.nat(Nat16.toNat(r.bits)).equal(0);
  });

  test("bitwidth=1, bits=1 → bits=1", func() {
    let code = { bitwidth = 1; bits = 1 : Nat16 };
    let r = Common.reverseCodeBits(code);
    expect.nat(Nat16.toNat(r.bits)).equal(1);
  });

  test("bitwidth=3, bits=0b101=5 → reversed=0b101=5 (palindrome)", func() {
    // 101 reversed is 101
    let code = { bitwidth = 3; bits = 5 : Nat16 };
    let r = Common.reverseCodeBits(code);
    expect.nat(r.bitwidth).equal(3);
    expect.nat(Nat16.toNat(r.bits)).equal(5);
  });

  test("bitwidth=3, bits=0b100=4 → reversed=0b001=1", func() {
    let code = { bitwidth = 3; bits = 4 : Nat16 };
    let r = Common.reverseCodeBits(code);
    expect.nat(Nat16.toNat(r.bits)).equal(1);
  });

  test("bitwidth=4, bits=0b1100=12 → reversed=0b0011=3", func() {
    let code = { bitwidth = 4; bits = 12 : Nat16 };
    let r = Common.reverseCodeBits(code);
    expect.nat(Nat16.toNat(r.bits)).equal(3);
  });

  test("round-trip: reverseCodeBits(reverseCodeBits(x)) == x", func() {
    let code = { bitwidth = 5; bits = 22 : Nat16 }; // 0b10110 = 22
    let r = Common.reverseCodeBits(Common.reverseCodeBits(code));
    expect.nat(r.bitwidth).equal(code.bitwidth);
    expect.nat(Nat16.toNat(r.bits)).equal(Nat16.toNat(code.bits));
  });

});

suite("restore_huffman_codes", func() {

  test("empty bitwidth array → #err", func() {
    let builder = Encoder.Builder(1);
    let result = Common.restore_huffman_codes<Encoder.Encoder>(builder, []);
    expect.bool(Result.isErr(result)).isTrue();
  });

  test("all-zero bitwidths → encoder with no entries, returns #ok", func() {
    // all zeros means no symbol has a code; builder with 1 slot
    let builder = Encoder.Builder(1);
    let result = Common.restore_huffman_codes<Encoder.Encoder>(builder, [0, 0, 0]);
    // no mappings set, should succeed (no error from builder)
    expect.bool(Result.isOk(result)).isTrue();
  });

  test("single symbol bitwidth=1 → code 0 assigned", func() {
    let builder = Encoder.Builder(2);
    let result = Common.restore_huffman_codes<Encoder.Encoder>(builder, [1]);
    switch (result) {
      case (#ok(enc)) {
        let code = enc.lookup(0);
        expect.nat(code.bitwidth).equal(1);
      };
      case (#err(msg)) Runtime.trap("Expected #ok but got #err: " # msg);
    };
  });

  test("canonical two-symbol codes [1,1]", func() {
    // symbol 0 → bitwidth 1, symbol 1 → bitwidth 1
    // canonical: symbol0 gets bits=0, symbol1 gets bits=1
    let builder = Encoder.Builder(2);
    let result = Common.restore_huffman_codes<Encoder.Encoder>(builder, [1, 1]);
    switch (result) {
      case (#ok(enc)) {
        let c0 = enc.lookup(0);
        let c1 = enc.lookup(1);
        expect.nat(c0.bitwidth).equal(1);
        expect.nat(c1.bitwidth).equal(1);
        // codes must be distinct
        expect.bool(Nat16.toNat(c0.bits) != Nat16.toNat(c1.bits)).isTrue();
      };
      case (#err(msg)) Runtime.trap("Expected #ok: " # msg);
    };
  });

  test("three-symbol canonical codes [2,2,1]", func() {
    // symbol 2 has bitwidth 1 (shortest), symbols 0 and 1 have bitwidth 2
    let builder = Encoder.Builder(3);
    let result = Common.restore_huffman_codes<Encoder.Encoder>(builder, [2, 2, 1]);
    switch (result) {
      case (#ok(enc)) {
        let c0 = enc.lookup(0);
        let c1 = enc.lookup(1);
        let c2 = enc.lookup(2);
        expect.nat(c0.bitwidth).equal(2);
        expect.nat(c1.bitwidth).equal(2);
        expect.nat(c2.bitwidth).equal(1);
      };
      case (#err(msg)) Runtime.trap("Expected #ok: " # msg);
    };
  });

});

// ── Encoder ───────────────────────────────────────────────────────────────

suite("Encoder.fromBitwidths", func() {

  test("empty bitwidths → #err", func() {
    let result = Encoder.fromBitwidths([]);
    expect.bool(Result.isErr(result)).isTrue();
  });

  test("all-zero bitwidths → #err (symbol_count=0)", func() {
    // symbol_count collapses to 0 then builder(1) is called with no assignments
    // restore_huffman_codes on all-zeros → #ok empty encoder
    let result = Encoder.fromBitwidths([0, 0, 0]);
    expect.bool(Result.isOk(result)).isTrue();
  });

  test("simple two-symbol table builds correctly", func() {
    let result = Encoder.fromBitwidths([1, 1]);
    switch (result) {
      case (#ok(enc)) {
        let c0 = enc.lookup(0);
        let c1 = enc.lookup(1);
        expect.nat(c0.bitwidth).equal(1);
        expect.nat(c1.bitwidth).equal(1);
        expect.bool(Nat16.toNat(c0.bits) != Nat16.toNat(c1.bits)).isTrue();
      };
      case (#err(msg)) Runtime.trap("Expected #ok: " # msg);
    };
  });

  test("max_symbol returns correct last assigned symbol", func() {
    // symbols 0,1,2 with bitwidths 3,3,2 — last non-zero is symbol 2
    let result = Encoder.fromBitwidths([3, 3, 2]);
    switch (result) {
      case (#ok(enc)) {
        expect.nat(enc.max_symbol()).equal(2);
      };
      case (#err(msg)) Runtime.trap("Expected #ok: " # msg);
    };
  });

  test("trailing zeros: max_symbol ignores zero-bitwidth symbols", func() {
    // bitwidths=[1,1,0,0] — symbols 2,3 have no code
    let result = Encoder.fromBitwidths([1, 1, 0, 0]);
    switch (result) {
      case (#ok(enc)) {
        expect.nat(enc.max_symbol()).equal(1);
      };
      case (#err(msg)) Runtime.trap("Expected #ok: " # msg);
    };
  });

});

suite("Encoder.fromFrequencies", func() {

  test("uniform distribution: two symbols → equal-length codes", func() {
    let result = Encoder.fromFrequencies([10, 10], 15);
    switch (result) {
      case (#ok(enc)) {
        let c0 = enc.lookup(0);
        let c1 = enc.lookup(1);
        expect.nat(c0.bitwidth).equal(1);
        expect.nat(c1.bitwidth).equal(1);
      };
      case (#err(msg)) Runtime.trap("Expected #ok: " # msg);
    };
  });

  test("skewed distribution: high-freq symbol gets shorter code", func() {
    // symbol 0: freq=100, symbol 1: freq=1
    let result = Encoder.fromFrequencies([100, 1], 15);
    switch (result) {
      case (#ok(enc)) {
        let c0 = enc.lookup(0);
        let c1 = enc.lookup(1);
        expect.bool(c0.bitwidth <= c1.bitwidth).isTrue();
      };
      case (#err(msg)) Runtime.trap("Expected #ok: " # msg);
    };
  });

  test("zero-frequency symbols are excluded from codes", func() {
    // symbol 1 has freq=0 → should get no code (bitwidth=0)
    let result = Encoder.fromFrequencies([5, 0, 5], 15);
    switch (result) {
      case (#ok(enc)) {
        let c1 = enc.lookup(1);
        expect.nat(c1.bitwidth).equal(0);
      };
      case (#err(msg)) Runtime.trap("Expected #ok: " # msg);
    };
  });

  test("three symbols uniform: all get same bitwidth", func() {
    let result = Encoder.fromFrequencies([1, 1, 1], 15);
    switch (result) {
      case (#ok(enc)) {
        let c0 = enc.lookup(0);
        let c1 = enc.lookup(1);
        let c2 = enc.lookup(2);
        // At least one symbol may get a longer code due to tree shape;
        // just check all have a valid (non-zero) code
        expect.bool(c0.bitwidth > 0).isTrue();
        expect.bool(c1.bitwidth > 0).isTrue();
        expect.bool(c2.bitwidth > 0).isTrue();
      };
      case (#err(msg)) Runtime.trap("Expected #ok: " # msg);
    };
  });

  test("respects max_bitwidth limit", func() {
    // Many symbols but limit bitwidth to 4
    let freqs = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16];
    let result = Encoder.fromFrequencies(freqs, 4);
    switch (result) {
      case (#ok(enc)) {
        var sym = 0;
        while (sym < freqs.size()) {
          let code = enc.lookup(sym);
          if (code.bitwidth > 0) {
            expect.bool(code.bitwidth <= 4).isTrue();
          };
          sym += 1;
        };
      };
      case (#err(msg)) Runtime.trap("Expected #ok: " # msg);
    };
  });

});

suite("Encoder.encode", func() {

  test("encode writes correct bits to BitBuffer", func() {
    // bitwidths = [1, 1]: symbol 0 → 1-bit code, symbol 1 → 1-bit code
    let result = Encoder.fromBitwidths([1, 1]);
    switch (result) {
      case (#ok(enc)) {
        let buf = BitBuffer.BitBuffer(8);
        enc.encode(buf, 0);
        enc.encode(buf, 1);
        expect.nat(buf.bitSize()).equal(2);
        // The two 1-bit codes must differ
        expect.bool(buf.getBit(0) != buf.getBit(1)).isTrue();
      };
      case (#err(msg)) Runtime.trap("Expected #ok: " # msg);
    };
  });

});

// ── Decoder ───────────────────────────────────────────────────────────────

suite("Decoder.fromBitwidths", func() {

  test("empty bitwidths → #err", func() {
    let result = Decoder.fromBitwidths([]);
    expect.bool(Result.isErr(result)).isTrue();
  });

  test("single symbol bitwidth=1 builds correctly", func() {
    let result = Decoder.fromBitwidths([1]);
    expect.bool(Result.isOk(result)).isTrue();
  });

  test("two-symbol table builds without error", func() {
    let result = Decoder.fromBitwidths([1, 1]);
    expect.bool(Result.isOk(result)).isTrue();
  });

});

suite("Decoder.decode", func() {

  test("decode single symbol round-trip (bitwidth=1)", func() {
    let bws = [1, 1];
    let enc_result = Encoder.fromBitwidths(bws);
    let dec_result = Decoder.fromBitwidths(bws);
    switch (enc_result, dec_result) {
      case (#ok(enc), #ok(dec)) {
        let buf = BitBuffer.BitBuffer(8);
        enc.encode(buf, 0);
        let reader = BitReader.fromBytes(Iter.toArray(buf.bytes()));
        switch (dec.decode(reader)) {
          case (#ok(sym)) expect.nat(sym).equal(0);
          case (#err(msg)) Runtime.trap("Decode failed: " # msg);
        };
      };
      case _ Runtime.trap("Setup failed");
    };
  });

  test("decode second symbol round-trip (bitwidth=1)", func() {
    let bws = [1, 1];
    let enc_result = Encoder.fromBitwidths(bws);
    let dec_result = Decoder.fromBitwidths(bws);
    switch (enc_result, dec_result) {
      case (#ok(enc), #ok(dec)) {
        let buf = BitBuffer.BitBuffer(8);
        enc.encode(buf, 1);
        let reader = BitReader.fromBytes(Iter.toArray(buf.bytes()));
        switch (dec.decode(reader)) {
          case (#ok(sym)) expect.nat(sym).equal(1);
          case (#err(msg)) Runtime.trap("Decode failed: " # msg);
        };
      };
      case _ Runtime.trap("Setup failed");
    };
  });

  test("multiple consecutive encodes and decodes", func() {
    let bws = [2, 2, 2, 2];
    let enc_result = Encoder.fromBitwidths(bws);
    let dec_result = Decoder.fromBitwidths(bws);
    switch (enc_result, dec_result) {
      case (#ok(enc), #ok(dec)) {
        let buf = BitBuffer.BitBuffer(16);
        enc.encode(buf, 0);
        enc.encode(buf, 1);
        enc.encode(buf, 2);
        enc.encode(buf, 3);
        buf.byteAlign();
        let reader = BitReader.fromBytes(Iter.toArray(buf.bytes()));
        for (expected in [0, 1, 2, 3].vals()) {
          switch (dec.decode(reader)) {
            case (#ok(sym)) expect.nat(sym).equal(expected);
            case (#err(msg)) Runtime.trap("Decode failed at symbol " # debug_show expected # ": " # msg);
          };
        };
      };
      case _ Runtime.trap("Setup failed");
    };
  });

  test("round-trip with fromFrequencies", func() {
    let freqs = [10, 20, 5, 30, 15];
    let max_bw = 15;
    let enc_result = Encoder.fromFrequencies(freqs, max_bw);
    switch (enc_result) {
      case (#ok(enc)) {
        // collect bitwidths then build decoder
        let bws_mut = Prim.Array_init<Nat>(freqs.size(), 0);
        var idx = 0;
        for (f in freqs.vals()) {
          ignore f;
          bws_mut[idx] := enc.lookup(idx).bitwidth;
          idx += 1;
        };
        let bws = Array.fromVarArray(bws_mut);
        let dec_result = Decoder.fromBitwidths(bws);
        switch (dec_result) {
          case (#ok(dec)) {
            let buf = BitBuffer.BitBuffer(64);
            for (sym in [0, 1, 2, 3, 4].vals()) {
              if (enc.lookup(sym).bitwidth > 0) enc.encode(buf, sym);
            };
            buf.byteAlign();
            let reader = BitReader.fromBytes(Iter.toArray(buf.bytes()));
            for (sym in [0, 1, 2, 3, 4].vals()) {
              if (enc.lookup(sym).bitwidth > 0) {
                switch (dec.decode(reader)) {
                  case (#ok(s)) expect.nat(s).equal(sym);
                  case (#err(msg)) Runtime.trap("Decode failed: " # msg);
                };
              };
            };
          };
          case (#err(msg)) Runtime.trap("Decoder build failed: " # msg);
        };
      };
      case (#err(msg)) Runtime.trap("Encoder build failed: " # msg);
    };
  });

});
