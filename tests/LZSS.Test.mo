import { test; suite; expect } "mo:test";
import Array "mo:core/Array";
import Iter "mo:core/Iter";
import List "mo:core/List";
import Nat8 "mo:core/Nat8";

import Common "../src/LZSS/Common";
import EncoderLib "../src/LZSS/Encoder";
import Decoder "../src/LZSS/Decoder";

// ── helpers ───────────────────────────────────────────────────────────────

// Phase D: the encoder emits via MatchSink callbacks, never an LzssEntry
// variant. Tests buffer the callback stream into a local tagged-tuple list
// so they can assert on the symbol sequence without re-introducing the
// variant in production code.

type Symbol = { #lit : Nat8; #ptr : (Nat, Nat) };

func bufferSink(buf : List.List<Symbol>) : EncoderLib.MatchSink {
  {
    onLiteral = func(b : Nat8) { List.add(buf, #lit(b)) };
    onPointer = func(off : Nat, len : Nat) { List.add(buf, #ptr(off, len)) };
  };
};

func listToArray<T>(l : List.List<T>) : [T] {
  Iter.toArray(List.values(l));
};

func symEqual(a : Symbol, b : Symbol) : Bool {
  switch (a, b) {
    case (#lit(x), #lit(y)) x == y;
    case (#ptr(ox, lx), #ptr(oy, ly)) ox == oy and lx == ly;
    case _ false;
  };
};

// Encode `bytes` with a fresh #best encoder and return the symbol stream.
func encodeAll(bytes : [Nat8]) : [Symbol] {
  let enc = EncoderLib.Encoder(#best);
  let buf = List.empty<Symbol>();
  let sink = bufferSink(buf);
  enc.encode(bytes, sink);
  enc.flush(sink);
  listToArray(buf);
};

// Decode a symbol stream into a byte list.
func decodeAll(symbols : [Symbol]) : [Nat8] {
  let dec = Decoder.Decoder();
  let out = List.empty<Nat8>();
  for (s in symbols.vals()) {
    switch s {
      case (#lit(b)) dec.literal(out, b);
      case (#ptr(off, len)) dec.pointer(out, off, len);
    };
  };
  listToArray(out);
};

// ── Encoder ───────────────────────────────────────────────────────────────

suite(
  "Encoder",
  func() {

    test(
      "encode([]) returns no symbols",
      func() {
        let result = encodeAll([]);
        expect.nat(result.size()).equal(0);
      },
    );

    test(
      "encode single byte returns [#lit(byte)]",
      func() {
        let result = encodeAll([0x42]);
        expect.nat(result.size()).equal(1);
        expect.bool(symEqual(result[0], #lit(0x42))).isTrue();
      },
    );

    test(
      "encode two bytes returns two literals",
      func() {
        let result = encodeAll([0x41, 0x42]);
        expect.nat(result.size()).equal(2);
        expect.bool(symEqual(result[0], #lit(0x41))).isTrue();
        expect.bool(symEqual(result[1], #lit(0x42))).isTrue();
      },
    );

    test(
      "encode 3 distinct bytes returns 3 literals",
      func() {
        let result = encodeAll([0x41, 0x42, 0x43]);
        expect.nat(result.size()).equal(3);
        expect.bool(symEqual(result[0], #lit(0x41))).isTrue();
        expect.bool(symEqual(result[1], #lit(0x42))).isTrue();
        expect.bool(symEqual(result[2], #lit(0x43))).isTrue();
      },
    );

    test(
      "encode repeated bytes produces at least one #ptr",
      func() {
        let bytes = Array.tabulate<Nat8>(20, func(_) = 0x41);
        let result = encodeAll(bytes);
        var hasPointer = false;
        for (s in result.vals()) {
          switch s {
            case (#ptr(_, _)) hasPointer := true;
            case (#lit(_)) {};
          };
        };
        expect.bool(hasPointer).isTrue();
      },
    );

    test(
      "all #ptr entries have valid offset and length",
      func() {
        let bytes = Array.tabulate<Nat8>(100, func(i) = Nat8.fromNat(i % 7));
        let result = encodeAll(bytes);
        for (s in result.vals()) {
          switch s {
            case (#ptr(off, len)) {
              expect.bool(off >= 1).isTrue();
              expect.bool(off <= Common.MATCH_WINDOW_SIZE).isTrue();
              expect.bool(len >= 3).isTrue();
              expect.bool(len <= Common.MATCH_MAX_SIZE).isTrue();
            };
            case (#lit(_)) {};
          };
        };
      },
    );

    test(
      "stateful encodeByte + flush matches batch encode()",
      func() {
        let bytes : [Nat8] = [0x41, 0x42, 0x43, 0x41, 0x42, 0x43, 0x41, 0x42, 0x43];
        let expected = encodeAll(bytes);
        // Drive the encoder byte-by-byte instead of through `encode([Nat8])`.
        let enc = EncoderLib.Encoder(#best);
        let buf = List.empty<Symbol>();
        let sink = bufferSink(buf);
        for (b in bytes.vals()) { enc.encodeByte(b, sink) };
        enc.flush(sink);
        let got = listToArray(buf);
        expect.bool(got.size() == expected.size()).isTrue();
        var i = 0;
        while (i < got.size()) {
          expect.bool(symEqual(got[i], expected[i])).isTrue();
          i += 1;
        };
      },
    );

  },
);

// ── Compression levels ────────────────────────────────────────────────────

suite(
  "CompressionLevel",
  func() {

    test(
      "all three levels produce correct round-trips",
      func() {
        let bytes = Array.tabulate<Nat8>(200, func(i) = Nat8.fromNat(i % 13));
        for (level in [#fast, #balance, #best].vals()) {
          let enc = EncoderLib.Encoder(level);
          let buf = List.empty<Symbol>();
          let sink = bufferSink(buf);
          enc.encode(bytes, sink);
          enc.flush(sink);
          let decoded = decodeAll(listToArray(buf));
          expect.array(decoded, Nat8.toText, Nat8.equal).equal(bytes);
        };
      },
    );

    test(
      "#best produces <= symbols compared to #fast on repeated bytes",
      func() {
        let bytes = Array.tabulate<Nat8>(300, func(_) = 0x41);
        let encFast = EncoderLib.Encoder(#fast);
        let encBest = EncoderLib.Encoder(#best);
        let bufFast = List.empty<Symbol>();
        let bufBest = List.empty<Symbol>();
        encFast.encode(bytes, bufferSink(bufFast));
        encFast.flush(bufferSink(bufFast));
        encBest.encode(bytes, bufferSink(bufBest));
        encBest.flush(bufferSink(bufBest));
        expect.bool(List.size(bufBest) <= List.size(bufFast)).isTrue();
      },
    );

  },
);

// ── Decoder ───────────────────────────────────────────────────────────────

suite(
  "Decoder",
  func() {

    test(
      "literal() appends bytes",
      func() {
        let dec = Decoder.Decoder();
        let out = List.empty<Nat8>();
        dec.literal(out, 0xAA);
        dec.literal(out, 0xBB);
        dec.literal(out, 0xCC);
        expect.array(listToArray(out), Nat8.toText, Nat8.equal).equal([0xAA, 0xBB, 0xCC]);
      },
    );

    test(
      "pointer() copies previous bytes",
      func() {
        let dec = Decoder.Decoder();
        let out = List.empty<Nat8>();
        dec.literal(out, 0x41);
        dec.literal(out, 0x42);
        dec.literal(out, 0x43);
        dec.pointer(out, 3, 3); // copy [A,B,C]
        expect.array(listToArray(out), Nat8.toText, Nat8.equal).equal([0x41, 0x42, 0x43, 0x41, 0x42, 0x43]);
      },
    );

    test(
      "pointer() with offset < len expands RLE correctly",
      func() {
        let dec = Decoder.Decoder();
        let out = List.empty<Nat8>();
        dec.literal(out, 0x41);
        dec.pointer(out, 1, 5);
        expect.array(listToArray(out), Nat8.toText, Nat8.equal).equal([0x41, 0x41, 0x41, 0x41, 0x41, 0x41]);
      },
    );

  },
);

// ── Round-trip ────────────────────────────────────────────────────────────

suite(
  "LZSS round-trip",
  func() {

    func roundTrip(bytes : [Nat8]) : [Nat8] {
      decodeAll(encodeAll(bytes));
    };

    test(
      "empty bytes round-trip",
      func() {
        expect.array(roundTrip([]), Nat8.toText, Nat8.equal).equal([]);
      },
    );

    test(
      "single byte round-trip",
      func() {
        let bytes : [Nat8] = [0x42];
        expect.array(roundTrip(bytes), Nat8.toText, Nat8.equal).equal(bytes);
      },
    );

    test(
      "short text round-trip",
      func() {
        // "Hello, World!" as bytes
        let bytes : [Nat8] = [0x48, 0x65, 0x6C, 0x6C, 0x6F, 0x2C, 0x20, 0x57, 0x6F, 0x72, 0x6C, 0x64, 0x21];
        expect.array(roundTrip(bytes), Nat8.toText, Nat8.equal).equal(bytes);
      },
    );

    test(
      "100 repeated bytes round-trip",
      func() {
        let bytes = Array.tabulate<Nat8>(100, func(_) = 0x41);
        expect.array(roundTrip(bytes), Nat8.toText, Nat8.equal).equal(bytes);
      },
    );

    test(
      "alternating pattern round-trip",
      func() {
        let bytes = Array.tabulate<Nat8>(50, func(i) = if (i % 2 == 0) 0x41 else 0x42);
        expect.array(roundTrip(bytes), Nat8.toText, Nat8.equal).equal(bytes);
      },
    );

    test(
      "random-ish bytes round-trip (pseudo-random via prime step)",
      func() {
        let bytes = Array.tabulate<Nat8>(500, func(i) = Nat8.fromNat((i * 31 + 7) % 256));
        expect.array(roundTrip(bytes), Nat8.toText, Nat8.equal).equal(bytes);
      },
    );

  },
);
