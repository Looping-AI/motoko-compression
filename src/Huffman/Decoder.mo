import Array "mo:core/Array";
import Nat "mo:core/Nat";
import Nat16 "mo:core/Nat16";
import Option "mo:core/Option";
import Result "mo:core/Result";
import Prim "mo:⛔";

import Common "Common";
import BitReader "../internal/BitReader";
import BitBuffer "../internal/BitBuffer";

module {
  type Result<A, B> = Result.Result<A, B>;
  type BitBuffer = BitBuffer.BitBuffer;
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
  };
};
