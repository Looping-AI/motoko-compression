/// Prefix table for LZSS encoding: maps 3-byte prefixes to the most recent
/// position where that prefix was seen in the input stream.
///
/// Implementation: flat array of 65 536 buckets indexed by the first two bytes
/// of the prefix (256 × 256 distinct two-byte pairs).  Each bucket is a lazily-
/// allocated [var Nat] of exactly 256 slots, indexed directly by the third byte.
/// Positions are stored as `pos + 1`; 0 means "absent".
///
/// This replaces the previous List<(Nat8, Nat)> bucket design, which required
/// a linear scan for the third byte and allocated a heap tuple on every new
/// prefix.  The new design is O(1) per insert/lookup with no heap allocation
/// in the hot path.

import List "mo:core/List";
import Nat8 "mo:core/Nat8";
import Prim "mo:⛔";

module {

  public class PrefixTable() {

    // Number of distinct ordered pairs (b0, b1) of Nat8 values: 256 × 256.
    let TABLE_SIZE : Nat = 65_536;

    // Each slot holds a lazily-allocated 256-element array indexed by b2.
    // bucket[b2] = pos + 1  (0 = absent).
    let table : [var ?([var Nat])] = Prim.Array_init<?([var Nat])>(TABLE_SIZE, null);

    // Indices of slots that have been allocated, for O(used) clear().
    let created = List.empty<Nat>();

    /// Insert a 3-byte prefix `(b0, b1, b2)` into the table and record
    /// `index` as its latest position.
    ///
    /// Returns the previous insertion index for this exact prefix if one
    /// existed, or `null` if this is the first occurrence.
    public func insert(b0 : Nat8, b1 : Nat8, b2 : Nat8, index : Nat) : ?Nat {
      let ti : Nat = Nat8.toNat(b0) * 256 + Nat8.toNat(b1);
      let b2i : Nat = Nat8.toNat(b2);

      let bucket : [var Nat] = switch (table[ti]) {
        case (?b) b;
        case null {
          let b = Prim.Array_init<Nat>(256, 0);
          table[ti] := ?b;
          List.add(created, ti);
          b;
        };
      };

      let prev = bucket[b2i];
      bucket[b2i] := index + 1;
      if (prev == 0) null else ?(prev - 1);
    };

    /// Reset the table, discarding all recorded prefix positions.
    /// Only touches slots that were actually allocated.
    public func clear() {
      for (ti in List.values(created)) {
        table[ti] := null;
      };
      List.clear(created);
    };

  };

};
