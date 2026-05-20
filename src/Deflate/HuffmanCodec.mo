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
import HuffmanDecoder "../Huffman/Decoder";
import BitBuffer "../internal/BitBuffer";
import BitReader "../internal/BitReader";
import Symbol "Symbol";
import Utils "../internal/utils";

module {

  type BitBuffer = BitBuffer.BitBuffer;
  type BitReader = BitReader.BitReader;
  type Result<A, B> = Result.Result<A, B>;

  // ── Codec interface ────────────────────────────────────────────────────

  /// Common interface for fixed and dynamic Huffman codecs.
  public type HuffmanCodec = {
    build : ({ next : () -> ?Symbol.Symbol }) -> Result<Symbol.Encoder, Text>;
    save : (BitBuffer, Symbol.Encoder) -> Result<(), Text>;
    load : BitReader -> Result<Symbol.Decoder, Text>;
  };

  // ── Fixed Huffman codec ────────────────────────────────────────────────

  public class FixedHuffmanCodec() {

    public func build(_ : { next : () -> ?Symbol.Symbol }) : Result<Symbol.Encoder, Text> {
      // Build literal/length encoder from fixed codes
      let lb = HuffmanEncoder.Builder(288);
      for ({ bitwidth; symbol_start; symbol_end; base_code } in Symbol.FIXED_LENGTH_CODES.vals()) {
        for (sym in Utils.range(symbol_start, symbol_end + 1)) {
          let code = {
            bitwidth;
            bits = base_code + Nat16.fromNat(sym - symbol_start);
          };
          switch (lb.setMapping(sym, code)) {
            case (#ok(_)) {};
            case (#err(msg)) return #err("FixedHuffmanCodec: literal " # msg);
          };
        };
      };
      let le = lb.build();

      // Build distance encoder: 5-bit codes 0-29
      let db = HuffmanEncoder.Builder(30);
      for (sym in Utils.range(0, 30)) {
        let code = { bitwidth = 5; bits = Nat16.fromNat(sym) };
        switch (db.setMapping(sym, code)) {
          case (#ok(_)) {};
          case (#err(msg)) return #err("FixedHuffmanCodec: distance " # msg);
        };
      };
      #ok(Symbol.Encoder(le, db.build()));
    };

    public func save(_ : BitBuffer, _ : Symbol.Encoder) : Result<(), Text> = #ok();

    public func load(reader : BitReader) : Result<Symbol.Decoder, Text> {
      // Build literal/length decoder
      let lb = HuffmanDecoder.Builder(9);
      for ({ bitwidth; symbol_start; symbol_end; base_code } in Symbol.FIXED_LENGTH_CODES.vals()) {
        for (sym in Utils.range(symbol_start, symbol_end + 1)) {
          let code = {
            bitwidth;
            bits = base_code + Nat16.fromNat(sym - symbol_start);
          };
          switch (lb.setMapping(sym, code)) {
            case (#ok(_)) {};
            case (#err(msg)) return #err("FixedHuffmanCodec load: literal " # msg);
          };
        };
      };

      // Build distance decoder: 5-bit codes 0-29
      let db = HuffmanDecoder.Builder(5);
      for (sym in Utils.range(0, 30)) {
        let code = { bitwidth = 5; bits = Nat16.fromNat(sym) };
        switch (db.setMapping(sym, code)) {
          case (#ok(_)) {};
          case (#err(msg)) return #err("FixedHuffmanCodec load: distance " # msg);
        };
      };
      ignore reader; // fixed codec reads nothing from the stream
      #ok(Symbol.Decoder(lb.build(), db.build()));
    };
  };

  // ── Dynamic Huffman codec ──────────────────────────────────────────────

  public class DynamicHuffmanCodec() {

    public func build(symbols_iter : { next : () -> ?Symbol.Symbol }) : Result<Symbol.Encoder, Text> {
      let literal_freq = Prim.Array_init<Nat>(286, 0);
      let distance_freq = Prim.Array_init<Nat>(30, 0);
      var empty_distance = true;

      for (symbol in symbols_iter) {
        let (marker, _, _) = Symbol.lengthCode(symbol);
        literal_freq[Nat16.toNat(marker)] += 1;
        switch (Symbol.distanceCode(symbol)) {
          case (?(m, _, _)) {
            distance_freq[m] += 1;
            empty_distance := false;
          };
          case null {};
        };
      };
      // EndOfBlock is always emitted, even if not in the iterator
      literal_freq[256] += 1;
      // Need at least one distance code
      if (empty_distance) { distance_freq[0] := 1 };

      let le = switch (HuffmanEncoder.fromFrequencies(Array.fromVarArray(literal_freq), 15)) {
        case (#ok(e)) e;
        case (#err(msg)) return #err("DynamicHuffmanCodec build literal: " # msg);
      };
      let de = switch (HuffmanEncoder.fromFrequencies(Array.fromVarArray(distance_freq), 15)) {
        case (#ok(e)) e;
        case (#err(msg)) return #err("DynamicHuffmanCodec build distance: " # msg);
      };
      #ok(Symbol.Encoder(le, de));
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
        case (#err(msg)) return #err("DynamicHuffmanCodec save bwe: " # msg);
      };

      // Find the last non-trivial entry in BITWIDTH_CODE_ORDER
      var bw_max_idx = 0;
      label search for (i in Utils.revRange(Symbol.BITWIDTH_CODE_ORDER.size(), 0)) {
        let idx = Symbol.BITWIDTH_CODE_ORDER[i];
        if (sym_freq[idx] > 0 and bwe.lookup(idx).bitwidth > 0) {
          bw_max_idx := i;
          break search;
        };
      };
      let bwcc = Nat.max(4, bw_max_idx + 1);

      // HLIT, HDIST, HCLEN
      bitbuffer.addBits(5, lcc - 257);
      bitbuffer.addBits(5, dcc - 1);
      bitbuffer.addBits(4, bwcc - 4);

      // Code lengths for meta-Huffman tree
      for (i in Utils.range(0, bwcc)) {
        let idx = Symbol.BITWIDTH_CODE_ORDER[i];
        bitbuffer.addBits(3, if (sym_freq[idx] != 0) bwe.lookup(idx).bitwidth else 0);
      };

      // Compressed code-length sequences
      for ({ symbol; count; bitwidth } in List.values(codes)) {
        bwe.encode(bitbuffer, symbol);
        if (bitwidth > 0) { bitbuffer.addBits(bitwidth, count) };
      };
      #ok();
    };

    // ── Internal: run-length encode bitwidths ──────────────────────────

    type BitwidthCode = { symbol : Nat; count : Nat; bitwidth : Nat };
    let ZERO_CODE : BitwidthCode = { symbol = 0; count = 0; bitwidth = 0 };

    func buildBitwidthCodes(codec : Symbol.Encoder, lcc : Nat, dcc : Nat) : List.List<BitwidthCode> {
      type Run = { value : Nat; var count : Nat };

      // Collect run-length encoding of bitwidths
      let runs = List.empty<Run>();

      func rle(enc : HuffmanEncoder.Encoder, code_count : Nat) {
        for (sym in Utils.range(0, code_count)) {
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
        };
      };
      rle(codec.literal, lcc);
      rle(codec.distance, dcc);

      let codes = List.empty<BitwidthCode>();

      for (run in List.values(runs)) {
        if (run.value != 0) {
          // Emit one literal, then try to compress repeats with code 16
          List.add(codes, { ZERO_CODE with symbol = run.value });
          run.count -= 1;
          while (run.count >= 3) {
            let n = Nat.min(6, run.count);
            List.add(codes, { symbol = 16; count = n - 3; bitwidth = 2 });
            run.count -= n;
          };
          for (_ in Utils.range(0, run.count)) {
            List.add(codes, { ZERO_CODE with symbol = run.value });
          };
        } else {
          // Zeros: use code 18 (11-138) then code 17 (3-10) then literals
          while (run.count >= 11) {
            let n = Nat.min(138, run.count);
            List.add(codes, { symbol = 18; count = n - 11; bitwidth = 7 });
            run.count -= n;
          };
          if (run.count >= 3) {
            List.add(codes, { symbol = 17; count = run.count - 3; bitwidth = 3 });
          } else {
            for (_ in Utils.range(0, run.count)) {
              List.add(codes, ZERO_CODE);
            };
          };
        };
      };
      codes;
    };

    // ── Internal: load bitwidths helper ───────────────────────────────

    func loadBitwidths(
      reader : BitReader,
      bws : List.List<Nat>,
      code : Nat,
      last_opt : ?Nat,
    ) : Result<(), Text> {
      let (item, cnt) = switch code {
        case 16 {
          let cnt = reader.readBits(2) + 3;
          let last = switch last_opt {
            case null return #err("Deflate: code 16 with no previous value");
            case (?v) v;
          };
          (last, cnt);
        };
        case 17 { (0, reader.readBits(3) + 3) };
        case 18 { (0, reader.readBits(7) + 11) };
        case _ {
          if (code <= 15) (code, 1) else return #err("Deflate: invalid bitwidth code " # debug_show code);
        };
      };
      for (_ in Utils.range(0, cnt)) { List.add(bws, item) };
      #ok();
    };

    public func load(reader : BitReader) : Result<Symbol.Decoder, Text> {
      let lcc = reader.readBits(5) + 257; // HLIT  + 257
      let dcc = reader.readBits(5) + 1; // HDIST + 1
      let bwcc = reader.readBits(4) + 4; // HCLEN + 4

      if (lcc > 286) return #err("HLIT too large: " # debug_show lcc);
      if (dcc > 30) return #err("HDIST too large: " # debug_show dcc);

      // Read meta code lengths in BITWIDTH_CODE_ORDER
      let bw_arr = Prim.Array_init<Nat>(19, 0);
      for (i in Utils.range(0, bwcc)) {
        bw_arr[Symbol.BITWIDTH_CODE_ORDER[i]] := reader.readBits(3);
      };
      let bwd = switch (HuffmanDecoder.fromBitwidths(Array.fromVarArray(bw_arr))) {
        case (#ok(d)) d;
        case (#err(msg)) return #err("DynamicHuffmanCodec load bwd: " # msg);
      };

      // Decode literal/length code bitwidths
      let lit_bws = List.empty<Nat>();
      while (List.size(lit_bws) < lcc) {
        let code = switch (bwd.decode(reader)) {
          case (#ok(c)) c;
          case (#err(msg)) return #err(msg);
        };
        let prev = List.last(lit_bws);
        switch (loadBitwidths(reader, lit_bws, code, prev)) {
          case (#ok(_)) {};
          case (#err(msg)) return #err(msg);
        };
      };
      if (List.size(lit_bws) > lcc) {
        return #err("Literal bitwidths overflow: " # debug_show (List.size(lit_bws)));
      };

      // Decode distance code bitwidths
      let dist_bws = List.empty<Nat>();
      while (List.size(dist_bws) < dcc) {
        let code = switch (bwd.decode(reader)) {
          case (#ok(c)) c;
          case (#err(msg)) return #err(msg);
        };
        // Code 16 copies the last value seen (from lit_bws if dist_bws is empty)
        let prev = switch (List.last(dist_bws)) {
          case null List.last(lit_bws);
          case item item;
        };
        switch (loadBitwidths(reader, dist_bws, code, prev)) {
          case (#ok(_)) {};
          case (#err(msg)) return #err(msg);
        };
      };
      if (List.size(dist_bws) > dcc) {
        return #err("Distance bitwidths overflow: " # debug_show (List.size(dist_bws)));
      };

      let ld = switch (HuffmanDecoder.fromBitwidths(List.toArray(lit_bws))) {
        case (#ok(d)) d;
        case (#err(msg)) return #err("DynamicHuffmanCodec load literal: " # msg);
      };
      let dd = switch (HuffmanDecoder.fromBitwidths(List.toArray(dist_bws))) {
        case (#ok(d)) d;
        case (#err(msg)) return #err("DynamicHuffmanCodec load distance: " # msg);
      };
      #ok(Symbol.Decoder(ld, dd));
    };
  };

};
