/// Growable `[var Nat8]` output buffer that doubles as the LZSS sliding window.
///
/// This replaces `List.List<Nat8>` on the decode hot path, eliminating:
///   - `?Nat8` option wrappers on every List.get call
///   - bignum-index overhead from List internals
///   - per-element allocation from List.add
///
/// The backing store doubles in capacity when full (amortised O(1) add).
/// `copyMatch` handles overlapping back-references (distance < length),
/// which produce repeating-pattern runs — the read-while-writing loop is
/// intentional and matches zlib inflate behaviour.

import Array "mo:core/Array";
import Int "mo:core/Int";
import Prim "mo:⛔";
import Runtime "mo:core/Runtime";

module {

  public class OutByteBuffer(initCap : Nat) {
    var cap : Nat = if (initCap > 0) initCap else 4096;
    var buf : [var Nat8] = Prim.Array_init<Nat8>(cap, (0 : Nat8));
    var len : Nat = 0;

    // ── Internal growth ───────────────────────────────────────────────────

    func grow() {
      let newCap = cap * 2;
      let newBuf = Prim.Array_init<Nat8>(newCap, (0 : Nat8));
      var i = 0;
      while (i < len) { newBuf[i] := buf[i]; i += 1 };
      cap := newCap;
      buf := newBuf;
    };

    func ensureRoom(extra : Nat) {
      while (len + extra > cap) grow();
    };

    // ── Hot path writes ───────────────────────────────────────────────────

    /// Append one byte. Amortised O(1).
    public func add(b : Nat8) {
      if (len == cap) grow();
      buf[len] := b;
      len += 1;
    };

    /// Append all bytes from an immutable array. O(n) with one pre-grow.
    public func addBytes(bs : [Nat8]) {
      let n = bs.size();
      if (n == 0) return;
      ensureRoom(n);
      var i = 0;
      while (i < n) {
        buf[len] := bs[i];
        len += 1;
        i += 1;
      };
    };

    /// Copy `length` bytes from `distance` bytes back in the output buffer.
    ///
    /// Handles the overlapping case (distance < length): because we advance
    /// `len` with each write, later iterations can read bytes written in
    /// earlier iterations. For example, distance=1 with length=100 copies the
    /// same byte 100 times (RLE expansion).
    ///
    /// Traps if `distance == 0` or `distance > size()`.
    public func copyMatch(distance : Nat, length : Nat) {
      if (distance == 0 or distance > len) {
        Runtime.trap(
          "OutByteBuffer.copyMatch: invalid distance " # debug_show distance
          # " (output size=" # debug_show len # ")"
        );
      };
      ensureRoom(length);
      // len ≥ distance is proved by the guard above;
      let start : Nat = len - distance;
      var i = 0;
      while (i < length) {
        buf[len] := buf[start + i];
        len += 1;
        i += 1;
      };
    };

    // ── Queries ───────────────────────────────────────────────────────────

    /// Number of bytes currently in the buffer.
    public func size() : Nat { len };

    /// Copy all bytes into a fresh immutable array. O(n).
    public func toArray() : [Nat8] {
      Array.tabulate<Nat8>(len, func(i) { buf[i] });
    };

  };

};
