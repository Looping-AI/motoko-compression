import { test; suite; expect } "mo:test";
import Array "mo:core/Array";
import Iter "mo:core/Iter";
import List "mo:core/List";
import Nat8 "mo:core/Nat8";

import Common "../src/LZSS/Common";
import EncoderLib "../src/LZSS/Encoder/lib";
import Decoder "../src/LZSS/Decoder";
import LZSS "../src/LZSS/lib";

// ── helpers ───────────────────────────────────────────────────────────────

type LzssEntry = Common.LzssEntry;

func listToArray<T>(l : List.List<T>) : [T] {
  Iter.toArray(List.values(l));
};

func entryEqual(a : LzssEntry, b : LzssEntry) : Bool {
  switch (a, b) {
    case (#literal(x), #literal(y)) x == y;
    case (#pointer(ox, lx), #pointer(oy, ly)) ox == oy and lx == ly;
    case _ false;
  };
};

// ── Encoder ───────────────────────────────────────────────────────────────

suite(
  "Encoder",
  func() {

    test(
      "encode([]) returns empty list",
      func() {
        let result = EncoderLib.encode([]);
        expect.nat(List.size(result)).equal(0);
      },
    );

    test(
      "encode single byte returns [#literal(byte)]",
      func() {
        let result = EncoderLib.encode([0x42]);
        expect.nat(List.size(result)).equal(1);
        let entries = listToArray(result);
        expect.bool(entryEqual(entries[0], #literal(0x42))).isTrue();
      },
    );

    test(
      "encode two bytes returns two literals",
      func() {
        let result = EncoderLib.encode([0x41, 0x42]);
        let entries = listToArray(result);
        expect.nat(entries.size()).equal(2);
        expect.bool(entryEqual(entries[0], #literal(0x41))).isTrue();
        expect.bool(entryEqual(entries[1], #literal(0x42))).isTrue();
      },
    );

    test(
      "encode 3 distinct bytes returns 3 literals",
      func() {
        let result = EncoderLib.encode([0x41, 0x42, 0x43]);
        let entries = listToArray(result);
        expect.nat(entries.size()).equal(3);
        expect.bool(entryEqual(entries[0], #literal(0x41))).isTrue();
        expect.bool(entryEqual(entries[1], #literal(0x42))).isTrue();
        expect.bool(entryEqual(entries[2], #literal(0x43))).isTrue();
      },
    );

    test(
      "encode repeated bytes produces at least one #pointer entry",
      func() {
        // 20 repeated bytes: after the first match the encoder should emit pointers.
        let bytes = Array.tabulate<Nat8>(20, func(_) = 0x41);
        let entries = listToArray(EncoderLib.encode(bytes));
        var has_pointer = false;
        for (e in entries.vals()) {
          switch e {
            case (#pointer(_, _)) has_pointer := true;
            case (#literal(_)) {};
          };
        };
        expect.bool(has_pointer).isTrue();
      },
    );

    test(
      "all #pointer entries have valid offset and length",
      func() {
        let bytes = Array.tabulate<Nat8>(100, func(i) = Nat8.fromNat(i % 7));
        let entries = listToArray(EncoderLib.encode(bytes));
        for (e in entries.vals()) {
          switch e {
            case (#pointer(off, len)) {
              expect.bool(off >= 1).isTrue();
              expect.bool(off <= Common.MATCH_WINDOW_SIZE).isTrue();
              expect.bool(len >= 3).isTrue();
              expect.bool(len <= Common.MATCH_MAX_SIZE).isTrue();
            };
            case (#literal(_)) {};
          };
        };
      },
    );

    test(
      "stateful encode_byte + flush matches encode()",
      func() {
        let bytes : [Nat8] = [0x41, 0x42, 0x43, 0x41, 0x42, 0x43, 0x41, 0x42, 0x43];
        // encode via convenience function
        let expected = listToArray(EncoderLib.encode(bytes));
        // encode via stateful API
        let enc = EncoderLib.Encoder(#best);
        let buf = List.empty<LzssEntry>();
        let sink : EncoderLib.Sink = { add = func(e) { List.add(buf, e) } };
        enc.encode(bytes, sink);
        enc.flush(sink);
        let got = listToArray(buf);
        // Both paths must produce identical entry sequences.
        expect.bool(got.size() == expected.size()).isTrue();
        var i = 0;
        while (i < got.size()) {
          expect.bool(entryEqual(got[i], expected[i])).isTrue();
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
          let buf = List.empty<LzssEntry>();
          let sink : EncoderLib.Sink = { add = func(e) { List.add(buf, e) } };
          enc.encode(bytes, sink);
          enc.flush(sink);
          let decoded = listToArray(Decoder.decode(buf));
          expect.array(decoded, Nat8.toText, Nat8.equal).equal(bytes);
        };
      },
    );

    test(
      "#best produces <= entries compared to #fast on repeated bytes",
      func() {
        let bytes = Array.tabulate<Nat8>(300, func(_) = 0x41);
        let encFast = EncoderLib.Encoder(#fast);
        let encBest = EncoderLib.Encoder(#best);
        let bufFast = List.empty<LzssEntry>();
        let bufBest = List.empty<LzssEntry>();
        let sinkFast : EncoderLib.Sink = {
          add = func(e) { List.add(bufFast, e) };
        };
        let sinkBest : EncoderLib.Sink = {
          add = func(e) { List.add(bufBest, e) };
        };
        encFast.encode(bytes, sinkFast);
        encFast.flush(sinkFast);
        encBest.encode(bytes, sinkBest);
        encBest.flush(sinkBest);
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
      "#literal entries pass through unchanged",
      func() {
        let entries = List.fromArray<LzssEntry>([#literal(0xAA), #literal(0xBB), #literal(0xCC)]);
        let output = listToArray(Decoder.decode(entries));
        expect.array(output, Nat8.toText, Nat8.equal).equal([0xAA, 0xBB, 0xCC]);
      },
    );

    test(
      "#pointer copies previous bytes",
      func() {
        // Output so far: [A,B,C]; pointer (offset=3, len=3) copies [A,B,C]
        let entries = List.fromArray<LzssEntry>([
          #literal(0x41),
          #literal(0x42),
          #literal(0x43),
          #pointer(3, 3),
        ]);
        let output = listToArray(Decoder.decode(entries));
        expect.array(output, Nat8.toText, Nat8.equal).equal([0x41, 0x42, 0x43, 0x41, 0x42, 0x43]);
      },
    );

    test(
      "#pointer with offset < len expands RLE correctly",
      func() {
        // One literal A followed by pointer(1, 5): should give A A A A A A
        let entries = List.fromArray<LzssEntry>([
          #literal(0x41),
          #pointer(1, 5),
        ]);
        let output = listToArray(Decoder.decode(entries));
        expect.array(output, Nat8.toText, Nat8.equal).equal([0x41, 0x41, 0x41, 0x41, 0x41, 0x41]);
      },
    );

    test(
      "decodeIter matches decode",
      func() {
        let entries = List.fromArray<LzssEntry>([#literal(0x01), #literal(0x02)]);
        let via_decode = listToArray(Decoder.decode(entries));
        let d = Decoder.Decoder();
        let output = List.empty<Nat8>();
        d.decodeIter(output, List.values(entries));
        expect.array(listToArray(output), Nat8.toText, Nat8.equal).equal(via_decode);
      },
    );

  },
);

// ── Round-trip ────────────────────────────────────────────────────────────

suite(
  "LZSS round-trip",
  func() {

    test(
      "empty bytes round-trip",
      func() {
        let decoded = listToArray(LZSS.decode(LZSS.encode([])));
        expect.array(decoded, Nat8.toText, Nat8.equal).equal([]);
      },
    );

    test(
      "single byte round-trip",
      func() {
        let bytes : [Nat8] = [0x42];
        let decoded = listToArray(LZSS.decode(LZSS.encode(bytes)));
        expect.array(decoded, Nat8.toText, Nat8.equal).equal(bytes);
      },
    );

    test(
      "short text round-trip",
      func() {
        // "Hello, World!" as bytes
        let bytes : [Nat8] = [0x48, 0x65, 0x6C, 0x6C, 0x6F, 0x2C, 0x20, 0x57, 0x6F, 0x72, 0x6C, 0x64, 0x21];
        let decoded = listToArray(LZSS.decode(LZSS.encode(bytes)));
        expect.array(decoded, Nat8.toText, Nat8.equal).equal(bytes);
      },
    );

    test(
      "100 repeated bytes round-trip",
      func() {
        let bytes = Array.tabulate<Nat8>(100, func(_) = 0x41);
        let decoded = listToArray(LZSS.decode(LZSS.encode(bytes)));
        expect.array(decoded, Nat8.toText, Nat8.equal).equal(bytes);
      },
    );

    test(
      "alternating pattern round-trip",
      func() {
        let bytes = Array.tabulate<Nat8>(64, func(i) = if (i % 2 == 0) 0xAA else 0xBB);
        let decoded = listToArray(LZSS.decode(LZSS.encode(bytes)));
        expect.array(decoded, Nat8.toText, Nat8.equal).equal(bytes);
      },
    );

    test(
      "random-ish bytes round-trip (pseudo-random via prime step)",
      func() {
        let bytes = Array.tabulate<Nat8>(256, func(i) = Nat8.fromNat((i * 137) % 256));
        let decoded = listToArray(LZSS.decode(LZSS.encode(bytes)));
        expect.array(decoded, Nat8.toText, Nat8.equal).equal(bytes);
      },
    );

  },
);
