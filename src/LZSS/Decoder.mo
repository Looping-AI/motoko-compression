/// LZSS decoder.
///
/// Rewrite: dropped the `LzssEntry` variant. The decoder is now a
/// class with two direct methods (`literal`, `pointer`); consumers call them
/// in any order while accumulating bytes into a `List.List<Nat8>`.
///
/// The Deflate/Gzip decode path does not use this module
/// (it inlines literal/copy operations into an `OutByteBuffer` for speed).
/// This decoder remains available for users who want raw LZSS round-tripping.

import List "mo:core/List";
import Runtime "mo:core/Runtime";

module {

  // ── Decoder class ───────────────────────────────────────────────────────

  public class Decoder() {

    /// Append a literal byte to `output`.
    public func literal(output : List.List<Nat8>, byte : Nat8) {
      List.add(output, byte);
    };

    /// Copy `len` bytes from `output[size - backward_offset ..]` to the end
    /// of `output`. Supports RLE (offset < len) because each copied byte is
    /// visible to subsequent reads (mo:core/List is array-backed).
    /// Traps if `backward_offset` is 0 or exceeds the current output size.
    public func pointer(output : List.List<Nat8>, backward_offset : Nat, len : Nat) {
      let curSize = List.size(output);
      if (backward_offset == 0 or backward_offset > curSize) {
        Runtime.trap(
          "LZSS decode(): invalid #pointer (backward_offset="
          # debug_show backward_offset
          # ", output_size="
          # debug_show curSize
          # ")"
        );
      };
      let index = (curSize - backward_offset) : Nat;
      var i = index;
      while (i < index + len) {
        let byte = switch (List.get(output, i)) {
          case (?b) b;
          case null Runtime.unreachable();
        };
        List.add(output, byte);
        i += 1;
      };
    };

  }; // end class Decoder

};
