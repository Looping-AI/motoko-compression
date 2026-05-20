import Nat "mo:core/Nat";
import Nat16 "mo:core/Nat16";
import List "mo:core/List";
import Order "mo:core/Order";
import Result "mo:core/Result";

import Utils "../utils";

module {
  type Result<A, B> = Result.Result<A, B>;

  public let MAX_BITWIDTH : Nat = 15;

  public type Code = {
    bitwidth : Nat;
    bits : Nat16;
  };

  /// Reverses the bit order of a `Code`'s `bits` field within its `bitwidth`.
  public func reverseCodeBits(code : Code) : Code {
    var prev = code.bits;
    var curr = 0 : Nat16;

    for (_ in Utils.range(1, code.bitwidth + 1)) {
      curr <<= (1 : Nat16);
      curr |= prev & (1 : Nat16);
      prev >>= (1 : Nat16);
    };

    {
      bitwidth = code.bitwidth;
      bits = curr;
    };
  };

  public type BuilderInterface<A> = {
    setMapping : (Nat, Code) -> Result<(), Text>;
    build : () -> A;
  };

  /// Restores canonical Huffman codes from an array of per-symbol bitwidths.
  /// Returns `#err` if the bitwidth array is empty or a mapping conflict occurs.
  public func restoreHuffmanCodes<A>(
    builder : BuilderInterface<A>,
    bitwidth_arr : [Nat],
  ) : Result<A, Text> {
    if (bitwidth_arr.size() == 0) {
      return #err("Cannot generate huffman codes from empty bitwidth array");
    };

    let bitwidth_buffer = List.empty<(Nat, Nat)>();

    var i = 0;
    for (bitwidth in bitwidth_arr.vals()) {
      if (bitwidth > 0) {
        List.add(bitwidth_buffer, (i, bitwidth));
      };
      i += 1;
    };

    List.sortInPlace(
      bitwidth_buffer,
      func(a : (Nat, Nat), b : (Nat, Nat)) : Order.Order {
        Nat.compare(a.1, b.1);
      },
    );

    var bits = 0 : Nat;
    var prev_width = 0 : Nat;

    for ((symbol, bitwidth) in List.values(bitwidth_buffer)) {
      bits *= (2 ** (bitwidth - prev_width));

      let code : Code = { bitwidth; bits = Nat16.fromNat(bits) };

      switch (builder.setMapping(symbol, code)) {
        case (#ok()) {};
        case (#err(msg)) {
          return #err(if (msg.size() > 0) msg else "Failed to set mapping");
        };
      };

      bits += 1;
      prev_width := bitwidth;
    };

    #ok(builder.build());
  };
};
