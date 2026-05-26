/// Fixed-capacity ring buffer of Nat8, intended as a sliding-window for LZSS.
///
/// Semantics:
///   - `push` is O(1). When the buffer is full the oldest element is silently
///     evicted (head advances) before the new element is written.
///   - `get(i)` is O(1): index 0 is the oldest element, `size()-1` is the newest.
///   - Capacity is fixed at construction time and never changes.
///
/// Performance note: capacity MUST be a power of 2.  Internal state (`head`,
/// `count`) is stored as Nat32 so hot operations (push, getUnchecked,
/// popFrontUnchecked) perform pure Nat32 arithmetic with a single bitmask wrap
/// (`& mask32`).  The only Nat32→Nat conversion per operation is at the
/// `buf[...]` array-index boundary, which Motoko requires to be `Nat`.
/// Passing a non-power-of-2 capacity traps at construction time.
///
/// Typical usage: `CircularBuffer(32768)` as an LZSS back-reference window,
/// `CircularBuffer(512)` as the encoder lookahead buffer.

import Prim "mo:⛔";
import Runtime "mo:core/Runtime";
import Nat32 "mo:core/Nat32";

module {

  public class CircularBuffer(cap : Nat) {
    if (cap == 0) Runtime.trap("CircularBuffer: capacity must be > 0");

    let cap32 = Nat32.fromNat(cap);
    if (cap32 & (cap32 - 1) != 0) Runtime.trap("CircularBuffer: capacity must be a power of 2");

    let buf : [var Nat8] = Prim.Array_init<Nat8>(cap, (0 : Nat8));
    // Bitmask for O(1) index wrapping: equivalent to % cap when cap is a power of 2.
    let mask32 : Nat32 = cap32 - 1;
    var head : Nat32 = 0;
    var count : Nat32 = 0;

    // ── Queries ───────────────────────────────────────────────────────────

    /// Current number of elements in the buffer.
    public func size() : Nat { Nat32.toNat(count) };

    // ── Mutation ──────────────────────────────────────────────────────────

    /// Append `b`. If the buffer is full the oldest element is evicted first.
    public func push(b : Nat8) {
      buf[Nat32.toNat((head + count) & mask32)] := b;
      if (count < cap32) {
        count += 1;
      } else {
        // Buffer full: oldest element is now overwritten; advance head.
        head := (head + 1) & mask32;
      };
    };

    /// Reset to empty. Existing slots are left untouched; count gates access.
    public func clear() {
      head := 0;
      count := 0;
    };

    // ── Access ────────────────────────────────────────────────────────────

    /// Return the element at logical index `i` (0 = oldest) without bounds
    /// checking and without allocating an option wrapper.
    ///
    /// Caller MUST ensure `i < size()`; passing an out-of-range index returns
    /// stale or zero data instead of trapping. Intended for hot paths where
    /// the caller has already verified the index is in range.
    public func getUnchecked(i : Nat32) : Nat8 {
      buf[Nat32.toNat((head + i) & mask32)];
    };

    /// Remove and return the oldest element (head) without bounds checking.
    ///
    /// Caller MUST ensure `size() > 0`; calling on an empty buffer returns
    /// stale or zero data instead of trapping. Intended for hot paths where
    /// the caller has already verified the buffer is non-empty.
    public func popFrontUnchecked() : Nat8 {
      let v = buf[Nat32.toNat(head)];
      head := (head + 1) & mask32;
      count -= 1;
      v;
    };

  }; // end class CircularBuffer

};
