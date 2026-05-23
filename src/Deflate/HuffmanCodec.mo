/// Deflate Huffman codec implementations: Fixed and Dynamic.
///
/// Each codec provides three operations:
///   build – scan a symbol stream and build an encoder
///   save  – write the codec header into a bit-buffer (dynamic only)
///   load  – read the codec header from a bit-reader and build a decoder
///
/// Migrated from edjcase/motoko_compression; Buffer → List, Deque → Queue,
/// Itertools/Buffer helpers replaced with mo:core equivalents.

import Array "mo:core/Array";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Nat16 "mo:core/Nat16";
import Result "mo:core/Result";
import Runtime "mo:core/Runtime";
import Prim "mo:⛔";

import HuffmanEncoder "../Huffman/Encoder";
import BitBuffer "../internal/BitBuffer";
import Symbol "Symbol";

module {

  type BitBuffer = BitBuffer.BitBuffer;
  type Result<A, B> = Result.Result<A, B>;

  // ── Codec interface ────────────────────────────────────────────────────

  /// Common interface for fixed and dynamic Huffman codecs.
  public type HuffmanCodec = {
    build : ({ next : () -> ?Symbol.Symbol }) -> Result<Symbol.Encoder, Text>;
    save : (BitBuffer, Symbol.Encoder) -> Result<(), Text>;
  };

  // ── Dynamic Huffman codec ──────────────────────────────────────────────

  public class DynamicHuffmanCodec() {

    public func build(symbols_iter : { next : () -> ?Symbol.Symbol }) : Result<Symbol.Encoder, Text> {
      let literal_freq = Prim.Array_init<Nat>(286, 0);
      let distance_freq = Prim.Array_init<Nat>(30, 0);
      var empty_distance = true;

      for (symbol in symbols_iter) {
        literal_freq[Symbol.lengthMarker(symbol)] += 1;
        let dm = Symbol.distanceMarker(symbol);
        if (dm != Symbol.NO_DISTANCE) {
          distance_freq[dm] += 1;
          empty_distance := false;
        };
      };
      // EndOfBlock is always emitted, even if not in the iterator
      literal_freq[256] += 1;
      // Need at least one distance code
      if (empty_distance) { distance_freq[0] := 1 };

      let le = switch (HuffmanEncoder.fromFrequencies(Array.fromVarArray(literal_freq), 15)) {
        case (#ok(e)) e;
        case (#err(msg)) {
          return #err("DynamicHuffmanCodec build literal: " # msg);
        };
      };
      let de = switch (HuffmanEncoder.fromFrequencies(Array.fromVarArray(distance_freq), 15)) {
        case (#ok(e)) e;
        case (#err(msg)) {
          return #err("DynamicHuffmanCodec build distance: " # msg);
        };
      };

      return #ok(Symbol.Encoder(le, de));
    };

    public func save(bitbuffer : BitBuffer, codec : Symbol.Encoder) : Result<(), Text> {
      let lcc = Nat.max(257, codec.literal.maxSymbol() + 1);
      let dcc = Nat.max(1, codec.distance.maxSymbol() + 1);

      let codes = buildBitwidthCodes(codec, lcc, dcc);

      // Count how often each bitwidth-meta symbol appears
      let sym_freq = Prim.Array_init<Nat>(19, 0);
      for ({ symbol; count = _; bitwidth = _ } in List.values(codes)) {
        sym_freq[symbol] += 1;
      };

      // Build Huffman encoder for the bitwidth-meta symbols
      let bwe = switch (HuffmanEncoder.fromFrequencies(Array.fromVarArray(sym_freq), 7)) {
        case (#ok(e)) e;
        case (#err(msg)) {
          return #err("DynamicHuffmanCodec save bwe: " # msg);
        };
      };

      // Find the last non-trivial entry in BITWIDTH_CODE_ORDER
      var bw_max_idx = 0;
      label search {
        var i = Symbol.BITWIDTH_CODE_ORDER.size();
        while (i > 0) {
          i -= 1;
          let idx = Symbol.BITWIDTH_CODE_ORDER[i];
          if (sym_freq[idx] > 0 and bwe.lookup(idx).bitwidth > 0) {
            bw_max_idx := i;
            break search;
          };
        };
      };
      let bwcc = Nat.max(4, bw_max_idx + 1);

      // HLIT, HDIST, HCLEN
      bitbuffer.addBits(5, lcc - 257);
      bitbuffer.addBits(5, dcc - 1);
      bitbuffer.addBits(4, bwcc - 4);

      // Code lengths for meta-Huffman tree
      var i = 0;
      while (i < bwcc) {
        let idx = Symbol.BITWIDTH_CODE_ORDER[i];
        bitbuffer.addBits(3, if (sym_freq[idx] != 0) bwe.lookup(idx).bitwidth else 0);
        i += 1;
      };

      // Compressed code-length sequences
      for ({ symbol; count; bitwidth } in List.values(codes)) {
        bwe.encode(bitbuffer, symbol);
        if (bitwidth > 0) { bitbuffer.addBits(bitwidth, count) };
      };

      return #ok();
    };

    // ── Internal: run-length encode bitwidths ──────────────────────────

    type BitwidthCode = { symbol : Nat; count : Nat; bitwidth : Nat };
    type Run = { value : Nat; var count : Nat };

    let ZERO_CODE : BitwidthCode = { symbol = 0; count = 0; bitwidth = 0 };

    func rle(enc : HuffmanEncoder.Encoder, code_count : Nat, runs : List.List<Run>) {
      var sym = 0;
      while (sym < code_count) {
        let bw = enc.lookup(sym).bitwidth;
        let extend = switch (List.last(runs)) {
          case (?last) last.value == bw;
          case null false;
        };
        if (extend) {
          let ?last = List.last(runs) else Runtime.unreachable();
          last.count += 1;
        } else {
          List.add(runs, { value = bw; var count = 1 });
        };
        sym += 1;
      };
    };

    func buildBitwidthCodes(codec : Symbol.Encoder, lcc : Nat, dcc : Nat) : List.List<BitwidthCode> {
      // Collect run-length encoding of bitwidths
      let runs = List.empty<Run>();

      rle(codec.literal, lcc, runs);
      rle(codec.distance, dcc, runs);

      let codes = List.empty<BitwidthCode>();

      for (run in List.values(runs)) {
        if (run.value != 0) {
          // Emit one literal, then try to compress repeats with code 16
          List.add(codes, { ZERO_CODE with symbol = run.value });
          run.count -= 1;
          while (run.count >= 3) {
            let n = Nat.min(6, run.count);
            List.add(codes, { symbol = 16; count = (n - 3 : Nat); bitwidth = 2 });
            run.count -= n;
          };
          var _j = 0;
          while (_j < run.count) {
            List.add(codes, { ZERO_CODE with symbol = run.value });
            _j += 1;
          };
        } else {
          // Zeros: use code 18 (11-138) then code 17 (3-10) then literals
          while (run.count >= 11) {
            let n = Nat.min(138, run.count);
            List.add(codes, { symbol = 18; count = (n - 11 : Nat); bitwidth = 7 });
            run.count -= n;
          };
          if (run.count >= 3) {
            List.add(codes, { symbol = 17; count = (run.count - 3 : Nat); bitwidth = 3 });
          } else {
            var _j = 0;
            while (_j < run.count) {
              List.add(codes, ZERO_CODE);
              _j += 1;
            };
          };
        };
      };

      return codes;
    };

  };

  // ── Fixed Huffman codec ────────────────────────────────────────────────

  public class FixedHuffmanCodec() {

    public func build(_ : { next : () -> ?Symbol.Symbol }) : Result<Symbol.Encoder, Text> {
      // Build literal/length encoder from fixed codes
      let lb = HuffmanEncoder.Builder(288);
      for ({ bitwidth; symbol_start; symbol_end; base_code } in Symbol.FIXED_LENGTH_CODES.vals()) {
        var sym = symbol_start;
        while (sym < symbol_end + 1) {
          let code = {
            bitwidth;
            bits = base_code + Nat16.fromNat(sym - symbol_start);
          };
          switch (lb.setMapping(sym, code)) {
            case (#ok(_)) {};
            case (#err(msg)) {
              return #err("FixedHuffmanCodec: literal " # msg);
            };
          };
          sym += 1;
        };
      };
      let le = lb.build();

      // Build distance encoder: 5-bit codes 0-29
      let db = HuffmanEncoder.Builder(30);
      var sym = 0;
      while (sym < 30) {
        let code = { bitwidth = 5; bits = Nat16.fromNat(sym) };
        switch (db.setMapping(sym, code)) {
          case (#ok(_)) {};
          case (#err(msg)) {
            return #err("FixedHuffmanCodec: distance " # msg);
          };
        };
        sym += 1;
      };

      return #ok(Symbol.Encoder(le, db.build()));
    };

    public func save(_ : BitBuffer, _ : Symbol.Encoder) : Result<(), Text> {
      return #ok();
    };
  };

};
