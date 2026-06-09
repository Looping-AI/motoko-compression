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
import Common "Common";

module {
  type Result<A, B> = Result.Result<A, B>;
  type BitBuffer = BitBuffer.BitBuffer;

  let { reverseCodeBits } = Common;

  public type Code = Common.Code;

  public func fromBitwidths(bitwidths : [Nat]) : Result<Encoder, Text> {
    if (bitwidths.size() == 0) return #err("bitwidths is empty");

    var symbolCount = bitwidths.size() : Nat;
    while (symbolCount > 0 and bitwidths[symbolCount - 1] == 0) {
      symbolCount -= 1;
    };

    let builder = Builder(symbolCount + 1);

    Common.restoreHuffmanCodes<Encoder>(builder, bitwidths);
  };

  public func fromFrequencies(
    frequencies : [Nat],
    bitwidth : Nat,
  ) : Result<Encoder, Text> {
    let maxBitwidth = Nat.min(
      bitwidth,
      HuffmanCodes.calcMaxBitwidth(frequencies),
    );

    let bitwidths : [Nat] = HuffmanCodes.calcBitwidths(maxBitwidth, frequencies);

    fromBitwidths(bitwidths);
  };

  public class Builder(symbols_count : Nat) : Common.BuilderInterface<Encoder> {
    let table : [var Code] = Prim.Array_init(
      symbols_count,
      { bitwidth = 0; bits = 0 : Nat16 },
    );

    public let setMapping = func(symbol : Nat, code : Code) : Result<(), Text> {
      let prevCode = table[symbol];

      if (prevCode.bitwidth != 0 or prevCode.bits != 0) {
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

    // Parallel flat arrays for the hot symbol-emit path.  These mirror
    // `table` but use raw `Nat` values so callers can do indexed reads
    // and feed `BitBuffer.addBits` / `addBits4` directly — avoiding the
    // `Code` record lookup and per-symbol `Nat16.toNat` conversion that
    // `encode` performs.
    let n : Nat = table.size();
    public let bitwidths : [var Nat] = Prim.Array_init<Nat>(n, 0);
    public let bits : [var Nat] = Prim.Array_init<Nat>(n, 0);
    var i : Nat = 0;
    while (i < n) {
      bitwidths[i] := table[i].bitwidth;
      bits[i] := Nat16.toNat(table[i].bits);
      i += 1;
    };

    public func encode(bitbuffer : BitBuffer, symbol : Nat) {
      let code = table[symbol];
      assert code.bitwidth != 0;
      bitbuffer.addBits(code.bitwidth, Nat16.toNat(code.bits));
    };

    public func lookup(symbol : Nat) : Code {
      assert symbol < table.size();
      table[symbol];
    };

    public func maxSymbol() : Nat {
      var maxIndex = 0;

      label for_loop {
        var i = table.size();
        while (i > 0) {
          i -= 1;
          if (table[i].bitwidth > 0) {
            maxIndex := i;
            break for_loop;
          };
        };
      };

      maxIndex;
    };
  };

  module HuffmanCodes {
    public func calcMaxBitwidth(frequencies : [Nat]) : Nat {
      // Invert compare for min-heap: PriorityQueue is max-first.
      // Inline the tuple comparison to avoid two levels of closure indirection.
      let minCmp = func(a : (Nat, Nat), b : (Nat, Nat)) : Order.Order {
        let d = Nat.compare(b.0, a.0);
        if (d == #equal) Nat.compare(b.1, a.1) else d;
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

      let maxBitwidth = switch (PriorityQueue.pop(heap, minCmp)) {
        case (?(_, bitwidth)) bitwidth;
        case (_) 0;
      };

      Nat.max(maxBitwidth, 1);
    };

    public func calcBitwidths(maxBitwidth : Nat, frequencies : [Nat]) : [Nat] {
      LengthLimited.calcBitwidths(maxBitwidth, frequencies);
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

      public func calcBitwidths(maxBitwidth : Nat, frequencies : [Nat]) : [Nat] {
        let nodes = List.empty<Node>();

        func deepCopy(src : List.List<Node>) : List.List<Node> {
          let newNodes = List.empty<Node>();
          for (node in List.values(src)) {
            let newNode = {
              var weight = node.weight;
              symbols = List.clone(node.symbols);
            };
            List.add(newNodes, newNode);
          };
          newNodes;
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

        var weightedNodes = deepCopy(nodes);

        // Run maxBitwidth - 1 iterations (Itertools.range(0, maxBitwidth-1) was exclusive)
        var j = 1;
        while (j < maxBitwidth) {
          package(weightedNodes);
          weightedNodes := merge(weightedNodes, deepCopy(nodes));
          j += 1;
        };

        package(weightedNodes);

        let codeBitwidths = Prim.Array_init<Nat>(frequencies.size(), 0);

        for (node in List.values(weightedNodes)) {
          for (symbol in List.values(node.symbols)) {
            codeBitwidths[symbol] += 1;
          };
        };

        Array.fromVarArray(codeBitwidths);
      };

      func getU(l : List.List<Node>, i : Nat) : Node {
        switch (List.get(l, i)) {
          case (?v) v;
          case null Runtime.unreachable();
        };
      };

      public func merge(
        buffer_a : List.List<Node>,
        buffer_b : List.List<Node>,
      ) : List.List<Node> {
        var i = 0;
        var j = 0;

        let buffer = List.empty<Node>();

        while (i < List.size(buffer_a) and j < List.size(buffer_b)) {
          let a = getU(buffer_a, i);
          let b = getU(buffer_b, j);

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
            List.add(buffer, getU(buffer_a, idx));
            idx += 1;
          };
        } else {
          var idx = j;
          while (idx < List.size(buffer_b)) {
            List.add(buffer, getU(buffer_b, idx));
            idx += 1;
          };
        };

        buffer;
      };

      public func package(nodes : List.List<Node>) {
        if (List.size(nodes) < 2) return;

        let newSize = List.size(nodes) / 2;

        var i = 0;

        while (i < newSize) {
          let j = i * 2 + 1;

          if (j < List.size(nodes)) {
            Node.merge(getU(nodes, i * 2), getU(nodes, j));
          };

          List.put(nodes, i, getU(nodes, i * 2));

          i += 1;
        };

        while (List.size(nodes) > newSize) {
          ignore List.removeLast(nodes);
        };
      };
    };
  };
};
