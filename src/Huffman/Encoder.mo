import Array "mo:core/Array";
import Nat "mo:core/Nat";
import Nat16 "mo:core/Nat16";
import List "mo:core/List";
import Iter "mo:core/Iter";
import Order "mo:core/Order";
import Result "mo:core/Result";
import PriorityQueue "mo:core/PriorityQueue";
import Runtime "mo:core/Runtime";
import Prim "mo:⛔";

import BitBuffer "../internal/BitBuffer";
import BitReader "../internal/BitReader";
import Common "Common";

module {
  type Result<A, B> = Result.Result<A, B>;
  type BitBuffer = BitBuffer.BitBuffer;
  type BitReader = BitReader.BitReader;

  let { reverseCodeBits } = Common;

  public type Code = Common.Code;

  public func fromBitwidths(bitwidths : [Nat]) : Result<Encoder, Text> {
    if (bitwidths.size() == 0) return #err("bitwidths is empty");

    var symbol_count = bitwidths.size() : Nat;
    while (symbol_count > 0 and bitwidths[symbol_count - 1] == 0) {
      symbol_count -= 1;
    };

    let builder = Builder(symbol_count + 1);

    Common.restoreHuffmanCodes<Encoder>(builder, bitwidths);
  };

  public func fromFrequencies(
    frequencies : [Nat],
    bitwidth : Nat,
  ) : Result<Encoder, Text> {
    let max_bitwidth = Nat.min(
      bitwidth,
      HuffmanCodes.calcMaxBitwidth(frequencies),
    );

    let bitwidths : [Nat] = HuffmanCodes.calcBitwidths(max_bitwidth, frequencies);

    fromBitwidths(bitwidths);
  };

  public class Builder(symbols_count : Nat) : Common.BuilderInterface<Encoder> {
    let table : [var Code] = Prim.Array_init(
      symbols_count,
      { bitwidth = 0; bits = 0 : Nat16 },
    );

    public let setMapping = func(symbol : Nat, code : Code) : Result<(), Text> {
      let prev_code = table[symbol];

      if (prev_code.bitwidth != 0 or prev_code.bits != 0) {
        return #err("symbol has already been mapped");
      };

      table[symbol] := reverseCodeBits(code);
      #ok;
    };

    public func build() : Encoder {
      Encoder(table);
    };
  };

  public class Encoder(table : [var Code]) {

    public func encode(bitbuffer : BitBuffer, symbol : Nat) {
      let code = table[symbol];
      assert code != { bitwidth = 0; bits = 0 : Nat16 };
      bitbuffer.addBits(code.bitwidth, Nat16.toNat(code.bits));
    };

    public func lookup(symbol : Nat) : Code {
      assert symbol < table.size();
      table[symbol];
    };

    public func maxSymbol() : Nat {
      var max_index = 0;

      label for_loop {
        var i = table.size();
        while (i > 0) {
          i -= 1;
          if (table[i].bitwidth > 0) {
            max_index := i;
            break for_loop;
          };
        };
      };

      max_index;
    };
  };

  type Tuple<A, B> = (A, B);

  type CompareFn<A> = (A, A) -> Order.Order;

  func tupleCompare<A, B>(
    cmp1 : CompareFn<A>,
    cmp2 : CompareFn<B>,
  ) : CompareFn<Tuple<A, B>> {
    func(a : Tuple<A, B>, b : Tuple<A, B>) : Order.Order {
      let (a1, a2) = a;
      let (b1, b2) = b;

      let res1 = cmp1(a1, b1);
      if (res1 == #equal) {
        return cmp2(a2, b2);
      } else {
        return res1;
      };
    };
  };

  module HuffmanCodes {
    public func calcMaxBitwidth(frequencies : [Nat]) : Nat {
      let cmp = tupleCompare(Nat.compare, Nat.compare);
      // Invert compare for min-heap: PriorityQueue is max-first
      let minCmp = func(a : (Nat, Nat), b : (Nat, Nat)) : Order.Order {
        cmp(b, a);
      };
      let heap = PriorityQueue.empty<(Nat, Nat)>();

      for (freq in frequencies.vals()) {
        if (freq > 0) {
          PriorityQueue.push(heap, minCmp, (freq, 0));
        };
      };

      while (PriorityQueue.size(heap) > 1) {
        let ?(freq1, bitwidth1) = PriorityQueue.pop(heap, minCmp) else Runtime.unreachable();
        let ?(freq2, bitwidth2) = PriorityQueue.pop(heap, minCmp) else Runtime.unreachable();

        PriorityQueue.push(
          heap,
          minCmp,
          (freq1 + freq2, Nat.max(bitwidth1, bitwidth2) + 1),
        );
      };

      let max_bitwidth = switch (PriorityQueue.pop(heap, minCmp)) {
        case (?(_, bitwidth)) bitwidth;
        case (_) 0;
      };

      Nat.max(max_bitwidth, 1);
    };

    public func calcBitwidths(max_bitwidth : Nat, frequencies : [Nat]) : [Nat] {
      LengthLimited.calcBitwidths(max_bitwidth, frequencies);
    };

    public module LengthLimited {

      type Node = {
        var weight : Nat;
        symbols : List.List<Nat>;
      };

      public module Node {
        public func merge(self : Node, other : Node) {
          self.weight += other.weight;
          List.append(self.symbols, other.symbols);
        };
      };

      public func calcBitwidths(max_bitwidth : Nat, frequencies : [Nat]) : [Nat] {
        let nodes = List.empty<Node>();

        func deepCopy(src : List.List<Node>) : List.List<Node> {
          let new_nodes = List.empty<Node>();
          for (node in List.values(src)) {
            let new_node = {
              var weight = node.weight;
              symbols = List.clone(node.symbols);
            };
            List.add(new_nodes, new_node);
          };
          new_nodes;
        };

        for ((symbol, weight) in Iter.enumerate(frequencies.vals())) {
          if (weight > 0) {
            let node = {
              var weight = weight;
              symbols = List.fromArray<Nat>([symbol]);
            };
            List.add(nodes, node);
          };
        };

        let cmp = func(a : Node, b : Node) : Order.Order {
          Nat.compare(a.weight, b.weight);
        };

        List.sortInPlace(nodes, cmp);

        var weighted_nodes = deepCopy(nodes);

        // Run max_bitwidth - 1 iterations (Itertools.range(0, max_bitwidth-1) was exclusive)
        var _j = 1;
        while (_j < max_bitwidth) {
          package(weighted_nodes);
          weighted_nodes := merge(weighted_nodes, deepCopy(nodes));
          _j += 1;
        };

        package(weighted_nodes);

        let code_bitwidths = Prim.Array_init<Nat>(frequencies.size(), 0);

        for (node in List.values(weighted_nodes)) {
          for (symbol in List.values(node.symbols)) {
            code_bitwidths[symbol] += 1;
          };
        };

        Array.fromVarArray(code_bitwidths);
      };

      public func merge(
        buffer_a : List.List<Node>,
        buffer_b : List.List<Node>,
      ) : List.List<Node> {
        var i = 0;
        var j = 0;

        let buffer = List.empty<Node>();

        while (i < List.size(buffer_a) and j < List.size(buffer_b)) {
          let a = switch (List.get(buffer_a, i)) {
            case (?v) v;
            case null Runtime.unreachable();
          };
          let b = switch (List.get(buffer_b, j)) {
            case (?v) v;
            case null Runtime.unreachable();
          };

          if (a.weight < b.weight) {
            i += 1;
            List.add(buffer, a);
          } else {
            j += 1;
            List.add(buffer, b);
          };
        };

        if (i < List.size(buffer_a)) {
          var idx = i;
          while (idx < List.size(buffer_a)) {
            let v = switch (List.get(buffer_a, idx)) {
              case (?v) v;
              case null Runtime.unreachable();
            };
            List.add(buffer, v);
            idx += 1;
          };
        } else {
          var idx = j;
          while (idx < List.size(buffer_b)) {
            let v = switch (List.get(buffer_b, idx)) {
              case (?v) v;
              case null Runtime.unreachable();
            };
            List.add(buffer, v);
            idx += 1;
          };
        };

        buffer;
      };

      public func package(nodes : List.List<Node>) {
        if (List.size(nodes) < 2) return;

        let new_size = List.size(nodes) / 2;

        var i = 0;

        while (i < new_size) {
          let j = i * 2 + 1;

          if (j < List.size(nodes)) {
            let a = switch (List.get(nodes, i * 2)) {
              case (?v) v;
              case null Runtime.unreachable();
            };
            let b = switch (List.get(nodes, j)) {
              case (?v) v;
              case null Runtime.unreachable();
            };
            Node.merge(a, b);
          };

          let merged = switch (List.get(nodes, i * 2)) {
            case (?v) v;
            case null Runtime.unreachable();
          };
          List.put(nodes, i, merged);

          i += 1;
        };

        while (List.size(nodes) > new_size) {
          ignore List.removeLast(nodes);
        };
      };
    };
  };
};
