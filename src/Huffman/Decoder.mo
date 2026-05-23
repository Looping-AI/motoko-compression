import Array "mo:core/Array";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Nat16 "mo:core/Nat16";
import Option "mo:core/Option";
import Order "mo:core/Order";
import Result "mo:core/Result";
import Prim "mo:⛔";

import Runtime "mo:core/Runtime";

import BitAccumulator "../internal/BitAccumulator";
import Common "Common";
import BitReader "../internal/BitReader";

module {
  type Result<A, B> = Result.Result<A, B>;
  type BitReader = BitReader.BitReader;

  type Code = Common.Code;
  type BuilderInterface<A> = Common.BuilderInterface<A>;

  let { MAX_BITWIDTH; reverseCodeBits; restoreHuffmanCodes } = Common;

  public type DecoderOptions = {
    max_bitwidth : Nat;
  };

  public class Builder(max_bitwidth : Nat) : BuilderInterface<Decoder> {
    let table_size = 2 ** max_bitwidth;
    let table = Prim.Array_init<Nat>(table_size, MAX_BITWIDTH + 1);

    public func setMapping(symbol : Nat, code : Code) : Result<(), Text> {
      if (code.bitwidth > max_bitwidth) {
        return #err("Code bitwidth is greater than max bitwidth");
      };

      let value = (Nat16.fromNat(symbol) << (5 : Nat16)) | Nat16.fromNat(code.bitwidth);

      let code_be = reverseCodeBits(code);

      let possible_mappings = (2 ** (max_bitwidth - code.bitwidth)) - 1 : Nat;

      var p = 0;
      while (p < possible_mappings + 1) {
        let padding = Nat16.fromNat(p);
        let i = Nat16.toNat((padding << Nat16.fromNat(code.bitwidth)) | code_be.bits);

        if (i >= table.size()) {
          return #err(
            "Index out of bounds at i = " # debug_show i
            # " | table size = " # debug_show table.size()
            # " | padding = " # debug_show padding
            # " | code_be.bits = " # debug_show (code_be.bits)
            # " | code_be.bitwidth = " # debug_show (code.bitwidth)
          );
        };

        if (table[i] != MAX_BITWIDTH + 1) {
          return #err("Bit region conflict");
        };

        table[i] := Nat16.toNat(value);
        p += 1;
      };

      #ok();
    };

    public func build() : Decoder {
      Decoder(table, max_bitwidth);
    };
  };

  public func fromBitwidths(bitwidths : [Nat]) : Result<Decoder, Text> {
    let max_bitwidth = Array.foldRight<Nat, Nat>(bitwidths, 0, func(a, b) = Nat.max(a, b));
    let builder = Builder(max_bitwidth);

    restoreHuffmanCodes(builder, bitwidths);
  };

  /// Sentinel returned by `decodeRaw` when the bit stream contains an
  /// unrecognised pattern.  Callers must check for this and propagate an error.
  public let DECODE_ERROR : Nat = 0xFFFF_FFFF;

  public class Decoder(table : [var Nat], max_bitwidth : Nat) {

    var min_bitwidth : ?Nat = null;

    public func decode(reader : BitReader) : Result<Nat, Text> {
      var value = 0;
      var bitwidth = 0;
      var peek_bitwidth = Option.get(min_bitwidth, 1);

      label _loop loop {
        let code = reader.peekBits(peek_bitwidth);
        value := table[code];
        bitwidth := value % 32; // last 5 bits

        if (bitwidth <= peek_bitwidth) {
          break _loop;
        };

        if (bitwidth > max_bitwidth) {
          return #err(
            "Invalid bitwidth " # debug_show bitwidth
            # " at position " # debug_show reader.getPosition()
            # " (max bitwidth is " # debug_show max_bitwidth
            # ") peeked: " # debug_show (peek_bitwidth)
            # " code: " # debug_show (code)
            # " value: " # debug_show (value)
            # " table size: " # debug_show (table.size())
          );
        };

        peek_bitwidth := bitwidth;
      };

      reader.skipBits(bitwidth);

      switch (min_bitwidth) {
        case (null) min_bitwidth := ?bitwidth;
        case (?n) min_bitwidth := ?Nat.min(n, bitwidth);
      };

      let decoded = value / 32; // == value >> 5
      #ok(decoded);
    };

    /// Sentinel returned by `decodeRaw` when the bit stream contains an
    /// unrecognised pattern (i.e. the table entry is the initialisation
    /// sentinel).  Callers must check for this value and propagate an error.
    ///
    /// Returns `DECODE_ERROR` on corrupt input (unrecognised bit pattern).
    /// The accumulator position is NOT advanced in the error case.
    public func decodeRaw(acc : BitAccumulator.BitAccumulator) : Nat {
      acc.refill();
      let v = table[acc.peekNat(max_bitwidth)];
      let w = v % 32; // bitwidth stored in low 5 bits
      if (w > max_bitwidth) {
        return DECODE_ERROR;
      };
      acc.drop(w);
      v / 32 // symbol stored in high bits
    };
  };

  // ── Two-level (zlib-style) fast decoder ────────────────────────────────
  //
  // A single flat `[var Nat]` table whose first 2^root_bits entries form the
  // primary table and the rest are subtables.  Each entry packs two fields:
  //   value = (payload * 32) + tag        where 0 ≤ tag ≤ MAX_BITWIDTH
  //
  // Primary table entry interpretation (low 5 bits = w = entry % 32):
  //   • w ≤ root_bits  → direct symbol;        payload = symbol; consume w bits
  //   • root_bits < w  → overflow pointer;     payload = subtable offset;
  //                       consume root_bits bits, then look up subtable at
  //                       (offset + peek(w - root_bits)).
  //
  // Subtable entry: payload = symbol; tag = code_length − root_bits
  //                 (i.e. additional bits to consume after the primary drop).
  //
  // Sentinel `SENTINEL = MAX_BITWIDTH + 1` (= 16) marks uninitialised slots
  // and is detected as an error (tag > MAX_BITWIDTH).

  let SENTINEL : Nat = 16; // = MAX_BITWIDTH + 1 (inlined to keep static)
  let FAST_ROOT_BITS : Nat = 9;

  public class FastDecoder(tbl : [var Nat], rootBits : Nat) {

    public let root_bits = rootBits;

    /// Decode one symbol from the bit accumulator.  Returns `DECODE_ERROR`
    /// on corrupt input (unrecognised pattern).  The accumulator state on
    /// error is unspecified — the caller must not continue decoding.
    public func decodeRaw(acc : BitAccumulator.BitAccumulator) : Nat {
      acc.refill();
      let v = tbl[acc.peekNat(rootBits)];
      let w = v % 32;
      if (w > MAX_BITWIDTH) return DECODE_ERROR; // sentinel
      if (w <= rootBits) {
        acc.drop(w);
        return v / 32;
      };
      // Overflow path — w is the max code length of this subtable.
      acc.drop(rootBits);
      let sub_bits : Nat = w - rootBits;
      let sub_offset = v / 32;
      acc.refill();
      let v2 = tbl[sub_offset + acc.peekNat(sub_bits)];
      let w2 = v2 % 32;
      if (w2 > sub_bits) return DECODE_ERROR; // sentinel or overlong
      acc.drop(w2);
      v2 / 32;
    };
  };

  /// Build a two-level fast Huffman decoder from a per-symbol bitwidth array.
  /// `root_bits = min(max_bitwidth, FAST_ROOT_BITS)`, so trees whose codes
  /// all fit in `FAST_ROOT_BITS` bits get a single flat table (no overflow).
  public func fromBitwidthsFast(bitwidths : [Nat]) : Result<FastDecoder, Text> {
    if (bitwidths.size() == 0) {
      return #err("Cannot generate huffman codes from empty bitwidth array");
    };

    // Pass 1: find max bitwidth.
    var maxBw : Nat = 0;
    for (bw in bitwidths.vals()) {
      if (bw > maxBw) maxBw := bw;
    };

    if (maxBw > MAX_BITWIDTH) {
      return #err("Bitwidth " # debug_show maxBw # " exceeds MAX_BITWIDTH");
    };

    // No codes at all (all-zero bitwidths) — return a sentinel-only decoder.
    if (maxBw == 0) {
      let empty = Prim.Array_init<Nat>(2, SENTINEL);
      return #ok(FastDecoder(empty, 1));
    };

    let rootBits = if (maxBw < FAST_ROOT_BITS) maxBw else FAST_ROOT_BITS;
    let primary_size : Nat = 2 ** rootBits;

    // Pass 2: collect (symbol, bw) pairs and sort by bw for canonical assignment.
    let pairs = List.empty<(Nat, Nat)>();
    var i = 0;
    for (bw in bitwidths.vals()) {
      if (bw > 0) List.add(pairs, (i, bw));
      i += 1;
    };
    List.sortInPlace(
      pairs,
      func(a : (Nat, Nat), b : (Nat, Nat)) : Order.Order = Nat.compare(a.1, b.1),
    );

    // Pass 3: assign canonical codes; store reversed (LSB-first) bits.
    // entries: (symbol, bitwidth, reversed_bits_as_Nat)
    let entries = List.empty<(Nat, Nat, Nat)>();
    var bits : Nat = 0;
    var prevBw : Nat = 0;
    for ((sym, bw) in List.values(pairs)) {
      bits *= 2 ** (bw - prevBw);
      let code : Common.Code = { bitwidth = bw; bits = Nat16.fromNat(bits) };
      let beCode = Common.reverseCodeBits(code);
      List.add(entries, (sym, bw, Nat16.toNat(beCode.bits)));
      prevBw := bw;
      bits += 1;
    };

    // Pass 4: per primary-prefix, find max code length of codes that overflow.
    let subMaxBw = Prim.Array_init<Nat>(primary_size, 0);
    for ((_, bw, beBits) in List.values(entries)) {
      if (bw > rootBits) {
        let prefix = beBits % primary_size;
        if (bw > subMaxBw[prefix]) subMaxBw[prefix] := bw;
      };
    };

    // Pass 5: assign subtable offsets, compute total table size.
    let subOffset = Prim.Array_init<Nat>(primary_size, 0);
    var total : Nat = primary_size;
    var k = 0;
    while (k < primary_size) {
      if (subMaxBw[k] > 0) {
        subOffset[k] := total;
        total += 2 ** (subMaxBw[k] - rootBits);
      };
      k += 1;
    };

    let tbl = Prim.Array_init<Nat>(total, SENTINEL);

    // Pass 6a: install primary overflow pointers.
    k := 0;
    while (k < primary_size) {
      if (subMaxBw[k] > 0) {
        // tag = max_bw (> rootBits, ≤ MAX_BITWIDTH) — encodes "this is overflow"
        // AND the number of extra bits to peek (= tag - rootBits).
        tbl[k] := subOffset[k] * 32 + subMaxBw[k];
      };
      k += 1;
    };

    // Pass 6b: fill direct entries (primary) and subtable entries.
    for ((sym, bw, beBits) in List.values(entries)) {
      if (bw <= rootBits) {
        let step = 2 ** bw;
        let padCount : Nat = 2 ** (rootBits - bw);
        let value = sym * 32 + bw;
        var p = 0;
        while (p < padCount) {
          tbl[beBits + p * step] := value;
          p += 1;
        };
      } else {
        let prefix = beBits % primary_size;
        let off = subOffset[prefix];
        let mbw = subMaxBw[prefix];
        let extraBw : Nat = bw - rootBits; // bits to consume after primary drop
        let extraBits = beBits / primary_size; // high bits beyond root
        let step = 2 ** extraBw;
        let padCount : Nat = 2 ** (mbw - bw);
        let value = sym * 32 + extraBw;
        var p = 0;
        while (p < padCount) {
          tbl[off + extraBits + p * step] := value;
          p += 1;
        };
      };
    };

    #ok(FastDecoder(tbl, rootBits));
  };
};
