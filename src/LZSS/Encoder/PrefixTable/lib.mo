/// Prefix table for LZSS encoding: maps 3-byte prefixes to the most recent
/// position where that prefix was seen in the input stream.
///
/// Implementation: flat array of 65 536 buckets indexed by the first two bytes
/// of the prefix (256 × 256 distinct two-byte pairs).  Each bucket is a
/// lazily-allocated List that maps the third byte to the insertion index.
///
/// Improvements over the original edjcase implementation:
///   - Dropped the dead #small/HashValueTrieMap path (it was commented out).
///   - Fixed LARGE_TABLE_SIZE: the original used 258^2 = 66 564 (incorrect);
///     the correct value is 256 × 256 = 65 536 (all two-byte Nat8 pairs).
///   - Uses mo:core/List instead of mo:base/Buffer.

import List "mo:core/List";
import Nat8 "mo:core/Nat8";
import Runtime "mo:core/Runtime";
import Prim "mo:⛔";

module {

  public class PrefixTable() {

    // Number of distinct ordered pairs (b0, b1) of Nat8 values: 256 × 256.
    let TABLE_SIZE : Nat = 65_536;

    // Slot i holds a list of (third_byte, insertion_index) pairs for all
    // 3-byte prefixes whose first two bytes hash to i.
    let table : [var ?List.List<(Nat8, Nat)>] = Prim.Array_init<?List.List<(Nat8, Nat)>>(TABLE_SIZE, null);

    /// Insert a 3-byte prefix starting at `bytes[start]` into the table and
    /// record `index` as its latest position.
    ///
    /// Returns the previous insertion index for this exact prefix if one
    /// existed, or `null` if this is the first occurrence.
    public func insert(bytes : [Nat8], start : Nat, len : Nat, index : Nat) : ?Nat {
      if (bytes.size() < start + len) {
        Runtime.trap("PrefixTable.insert: bytes.size() < start + len");
      };
      // Two-byte big-endian index into the table.
      let table_index : Nat = Nat8.toNat(bytes[start]) * 256 + Nat8.toNat(bytes[start + 1]);
      let third_byte = bytes[start + 2];

      let bucket : List.List<(Nat8, Nat)> = switch (table[table_index]) {
        case (?b) b;
        case null {
          let b = List.empty<(Nat8, Nat)>();
          table[table_index] := ?b;
          b;
        };
      };

      // Search existing entries for a matching third byte.
      let sz = List.size(bucket);
      var i = 0;
      while (i < sz) {
        let (byte, prev_index) = switch (List.get(bucket, i)) {
          case (?v) v;
          case null Runtime.unreachable();
        };
        if (byte == third_byte) {
          List.put(bucket, i, (byte, index));
          return ?prev_index;
        };
        i += 1;
      };

      // No existing entry for this third byte: add a new one.
      List.add(bucket, (third_byte, index));
      null;
    };

    /// Reset the table, discarding all recorded prefix positions.
    public func clear() {
      var i = 0;
      while (i < TABLE_SIZE) {
        table[i] := null;
        i += 1;
      };
    };

  };

};
