/// LZSS decoder.
///
/// Migrated from edjcase/motoko_compression, replacing mo:base + mo:itertools
/// with mo:core only.
///
/// Key changes from original:
///   - Buffer<Nat8> output → List.List<Nat8> (mo:core, array-backed, O(1) get).
///   - Buffer<LzssEntry> input → List.List<LzssEntry>.
///   - It.range(a, b) → Utils.range(a, b) (both exclusive — same semantics).
///   - Debug.trap → Runtime.trap.
///   - buffer.get(i) returns T directly in mo:base vs ?T in mo:core/List;
///     unwrapped with `else Runtime.unreachable()`.
///   - Removed the dead RLE branch: since mo:core/List.get is O(1) and the
///     buffer always grows at least as fast as the loop index advances, the
///     `i >= buffer.size()` guard in the original can never trigger.

import Iter "mo:core/Iter";
import List "mo:core/List";
import Runtime "mo:core/Runtime";
import Common "Common";
import Utils "../utils";

module {

  type LzssEntry = Common.LzssEntry;

  // ── Top-level convenience function ─────────────────────────────────────

  /// Decode a list of LZSS entries and return the decompressed bytes.
  public func decode(lzss_entries : List.List<LzssEntry>) : List.List<Nat8> {
    let output = List.empty<Nat8>();
    let d = Decoder();
    d.decode(output, lzss_entries);
    output
  };

  // ── Decoder class ───────────────────────────────────────────────────────

  public class Decoder() {

    /// Decode a single entry into `output`.
    public func decodeEntry(output : List.List<Nat8>, entry : LzssEntry) {
      switch entry {
        case (#literal(byte)) {
          List.add(output, byte);
        };
        case (#pointer(backward_offset, len)) {
          let cur_size = List.size(output);
          if (backward_offset == 0 or backward_offset > cur_size) {
            Runtime.trap("LZSS decode(): Invalid LZSS #pointer (backward_offset > decompressed data size)");
          };
          // `index` is the position of the first byte to copy.
          // As we append bytes, mo:core/List.get sees them immediately (array-backed),
          // so the copy loop handles both normal and RLE (offset < len) cases uniformly.
          let index = (cur_size - backward_offset) : Nat;
          for (i in Utils.range(index, index + len)) {
            let byte = switch (List.get(output, i)) {
              case (?b) b;
              case null Runtime.unreachable();
            };
            List.add(output, byte);
          };
        };
      };
    };

    /// Decode all entries produced by an iterator into `output`.
    public func decodeIter(output : List.List<Nat8>, lzss_iter : Iter.Iter<LzssEntry>) {
      for (entry in lzss_iter) {
        decodeEntry(output, entry);
      };
    };

    /// Decode all entries in `lzss_entries` into `output`.
    public func decode(output : List.List<Nat8>, lzss_entries : List.List<LzssEntry>) {
      decodeIter(output, List.values(lzss_entries));
    };

  }; // end class Decoder

}
