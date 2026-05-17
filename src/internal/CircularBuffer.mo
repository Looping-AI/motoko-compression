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
import Iter "mo:core/Iter";

module {

  public class CircularBuffer(initCapacity : Nat) {

    if (initCapacity == 0) Runtime.trap("CircularBuffer: capacity must be > 0");

    let cap : Nat = initCapacity;
    let buf : [var Nat8] = Prim.Array_init<Nat8>(cap, (0 : Nat8));
    var head  : Nat = 0; // physical index of the oldest element
    var count : Nat = 0; // number of elements currently stored

    // ── Queries ───────────────────────────────────────────────────────────

    /// Maximum number of elements the buffer can hold.
    public func capacity() : Nat { cap };

    /// Current number of elements in the buffer.
    public func size() : Nat { count };

    /// True iff the buffer holds exactly `capacity()` elements.
    public func isFull() : Bool { count == cap };

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

    /// Reset to empty, zeroing all slots.
    public func clear() {
      var i = 0;
      while (i < cap) { buf[i] := 0; i += 1 };
      head  := 0;
      count := 0;
    };

    // ── Access ────────────────────────────────────────────────────────────

    /// Return the element at logical index `i` (0 = oldest), or null if i >= size.
    public func get(i : Nat) : ?Nat8 {
      if (i >= count) return null;
      ?(buf[(head + i) % cap])
    };

    /// Iterate over all elements from oldest to newest.
    public func values() : Iter.Iter<Nat8> {
      object {
        var i = 0;
        public func next() : ?Nat8 {
          if (i >= count) return null;
          let v = buf[(head + i) % cap];
          i += 1;
          ?v
        }
      }
    };

  }; // end class CircularBuffer

}
