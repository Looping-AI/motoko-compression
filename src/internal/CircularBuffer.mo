/// Fixed-capacity ring buffer of Nat8, intended as a sliding-window for LZSS.
///
/// Semantics:
///   - `push` is O(1). When the buffer is full the oldest element is silently
///     evicted (head advances) before the new element is written.
///   - `get(i)` is O(1): index 0 is the oldest element, `size()-1` is the newest.
///   - Capacity is fixed at construction time and never changes.
///
/// Typical usage: `CircularBuffer(32768)` as an LZSS back-reference window.

import Prim "mo:⛔";
import Runtime "mo:core/Runtime";

module {

  public class CircularBuffer(initCapacity : Nat) {

    if (initCapacity == 0) Runtime.trap("CircularBuffer: capacity must be > 0");

    let cap : Nat = initCapacity;
    let buf : [var Nat8] = Prim.Array_init<Nat8>(cap, (0 : Nat8));
    var head : Nat = 0; // physical index of the oldest element
    var count : Nat = 0; // number of elements currently stored

    // ── Queries ───────────────────────────────────────────────────────────

    /// Current number of elements in the buffer.
    public func size() : Nat { count };

    // ── Mutation ──────────────────────────────────────────────────────────

    /// Append `b`. If the buffer is full the oldest element is evicted first.
    public func push(b : Nat8) {
      let pos = (head + count) % cap;
      buf[pos] := b;
      if (count < cap) {
        count += 1;
      } else {
        // Buffer full: oldest element is now overwritten; advance head.
        head := (head + 1) % cap;
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
    public func getUnchecked(i : Nat) : Nat8 {
      buf[(head + i) % cap];
    };

    /// Remove and return the oldest element (head) without bounds checking.
    ///
    /// Caller MUST ensure `size() > 0`; calling on an empty buffer returns
    /// stale or zero data instead of trapping. Intended for hot paths where
    /// the caller has already verified the buffer is non-empty.
    public func popFrontUnchecked() : Nat8 {
      let v = buf[head];
      head := (head + 1) % cap;
      count -= 1;
      v;
    };

  }; // end class CircularBuffer

};
