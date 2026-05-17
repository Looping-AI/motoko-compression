/// LZSS encoder.
///
/// Migrated from edjcase/motoko_compression, replacing mo:base + external
/// packages with mo:core only.
///
/// Key changes from original:
///   - Encoder(opt_window_size : ?Nat) → Encoder(level : CompressionLevel),
///     mapping #fast → 1 024, #balance → 8 192, #best → 32 768.
///   - mo:buffer-deque/BufferDeque (byte_buffer) → CircularBuffer + popFront().
///   - mo:circular-buffer (search_buffer, cache_buffer) → CircularBuffer.
///   - Itertools.range → Utils.range (both exclusive).
///   - Prelude.unreachable() → Runtime.unreachable().
///   - Dead code removed: encode_v1, longest_prefix_length.

import List "mo:core/List";
import Option "mo:core/Option";
import Nat8 "mo:core/Nat8";
import Runtime "mo:core/Runtime";
import CircularBuffer "../../internal/CircularBuffer";
import Common "../Common";
import PrefixTable "PrefixTable/lib";
import Utils "../../utils";

module {

  type LzssEntry = Common.LzssEntry;

  /// Caller-supplied consumer for encoded entries.
  public type Sink = {
    add : (entry : LzssEntry) -> ();
  };

  // ── Window size per compression level ──────────────────────────────────

  func levelToWindowSize(level : Common.CompressionLevel) : Nat {
    switch level {
      case (#fast)    1_024;
      case (#balance) 8_192;
      case (#best)    Common.MATCH_WINDOW_SIZE; // 32_768
    }
  };

  // ── Public API ──────────────────────────────────────────────────────────

  /// Create an encoder at the best (highest ratio) compression level.
  public func Default() : Encoder { Encoder(#best) };

  /// Encode `bytes` at the best compression level and return the entry list.
  public func encode(bytes : [Nat8]) : List.List<LzssEntry> {
    let lzss = Default();
    let buffer = List.empty<LzssEntry>();
    let sink : Sink = { add = func(e) { List.add(buffer, e) } };
    lzss.encode(bytes, sink);
    lzss.flush(sink);
    buffer
  };

  // ── Encoder class ───────────────────────────────────────────────────────

  public class Encoder(level : Common.CompressionLevel) {

    let window_size : Nat = levelToWindowSize(level);

    // Sliding back-reference window (oldest element evicted on overflow).
    let search_buffer = CircularBuffer.CircularBuffer(window_size);

    // 3-byte prefix index for fast match lookup.
    let prefix_table = PrefixTable.PrefixTable();

    // Lookahead buffer: holds the next up-to-MATCH_MAX_SIZE unprocessed bytes.
    // Capacity is MATCH_MAX_SIZE + 1; the encoder always emits before reaching
    // that limit, so push never actually overwrites.
    let byte_buffer = CircularBuffer.CircularBuffer(Common.MATCH_MAX_SIZE + 1);

    // Tracks the last 1-2 emitted bytes for prefix-table seeding after a match.
    // Capacity = 2; push-on-full intentionally overwrites oldest (keeps last 2).
    let cache_buffer = CircularBuffer.CircularBuffer(2);

    var match_index : ?Nat = null;
    var input_size  : Nat  = 0;

    // ── Queries ────────────────────────────────────────────────────────────

    public func compressionLevel() : Common.CompressionLevel = level;
    public func size()             : Nat = input_size;
    public func windowSize()       : Nat = window_size;

    // ── Internals ──────────────────────────────────────────────────────────

    /// Unwrap get() from a CircularBuffer, trapping if out of bounds.
    func getUnsafe(buf : CircularBuffer.CircularBuffer, i : Nat) : Nat8 {
      switch (buf.get(i)) {
        case (?v) v;
        case null Runtime.unreachable();
      }
    };

    /// Emit `n` bytes from the front of byte_buffer as literals.
    func encode_as_literals(n : Nat, sink : Sink) {
      for (_ in Utils.range(0, n)) {
        let ?byte = byte_buffer.popFront() else Runtime.unreachable();
        search_buffer.push(byte);
        sink.add(#literal(byte));
        input_size += 1;
      };
    };

    // ── Public encoding interface ──────────────────────────────────────────

    /// Feed one future byte into the streaming encoder.
    public func encode_byte(future_byte : Nat8, sink : Sink) {
      byte_buffer.push(future_byte);

      // Seed the prefix table using bytes recently emitted during a match.
      // cache_buffer holds the last 1-2 emitted bytes; combined with the
      // front of byte_buffer they form new 3-byte prefixes to record.
      if (cache_buffer.size() == 2) {
        ignore prefix_table.insert(
          [getUnsafe(cache_buffer, 0), getUnsafe(cache_buffer, 1), getUnsafe(byte_buffer, 0)],
          0, 3, input_size - 2,
        );
        ignore cache_buffer.popFront();
      } else if (cache_buffer.size() == 1 and byte_buffer.size() >= 2) {
        ignore prefix_table.insert(
          [getUnsafe(cache_buffer, 0), getUnsafe(byte_buffer, 0), getUnsafe(byte_buffer, 1)],
          0, 3, input_size - 1,
        );
        ignore cache_buffer.popFront();
      };

      if (byte_buffer.size() < 3) return;

      if (byte_buffer.size() == 3) {
        // Try to start a new match at the current lookahead position.
        let opt_prefix_index = prefix_table.insert(
          [getUnsafe(byte_buffer, 0), getUnsafe(byte_buffer, 1), getUnsafe(byte_buffer, 2)],
          0, 3, input_size,
        );
        switch (opt_prefix_index) {
          case (null) {
            encode_as_literals(1, sink);
            match_index := null;
          };
          case (?prefix_index) {
            let backward_offset = (input_size - prefix_index) : Nat;
            if (backward_offset > search_buffer.size()) {
              // The match is outside the current window; emit literal instead.
              encode_as_literals(1, sink);
              match_index := null;
            } else {
              match_index := opt_prefix_index;
            };
          };
        };
      } else {
        // byte_buffer.size() > 3: we are extending an existing match.
        let ?prefix_index = match_index else Runtime.unreachable();
        let backward_offset  = (input_size - prefix_index) : Nat;
        let start_index      = (search_buffer.size() - backward_offset) : Nat;
        let future_byte_index = start_index + (byte_buffer.size() - 1) : Nat;

        let mismatch = future_byte_index >= search_buffer.size()
          or future_byte != getUnsafe(search_buffer, future_byte_index);
        let too_long = byte_buffer.size() >= Common.MATCH_MAX_SIZE;

        if (mismatch or too_long) {
          // Emit the accumulated match (all but the last buffered byte).
          let len = (byte_buffer.size() - 1) : Nat;

          for (i in Utils.range(0, len)) {
            // While 3+ bytes remain, record the current 3-byte prefix.
            if (byte_buffer.size() >= 3) {
              ignore prefix_table.insert(
                [getUnsafe(byte_buffer, 0), getUnsafe(byte_buffer, 1), getUnsafe(byte_buffer, 2)],
                0, 3, i + input_size,
              );
            };
            let ?byte = byte_buffer.popFront() else Runtime.unreachable();
            search_buffer.push(byte);
            // When fewer than 3 bytes remain, seed cache_buffer for the next
            // encode_byte call to complete the prefix table entry.
            if (byte_buffer.size() < 3) {
              cache_buffer.push(byte);
            };
          };

          sink.add(#pointer(backward_offset, len));
          input_size += len;
          match_index := null;
        };
      };
    };

    /// Encode all of `bytes` by feeding them one at a time.
    public func encode(bytes : [Nat8], sink : Sink) {
      for (byte in bytes.vals()) {
        encode_byte(byte, sink);
      };
    };

    /// Flush any bytes remaining in the lookahead buffer.
    /// Must be called after `encode` to emit the final entries.
    public func flush(sink : Sink) {
      let len = byte_buffer.size();
      if (len == 0) return;

      if (Option.isSome(match_index) and len >= 3) {
        let ?prefix_index = match_index else Runtime.unreachable();
        let backward_offset = (input_size - prefix_index) : Nat;
        sink.add(#pointer(backward_offset, len));
      } else {
        for (_ in Utils.range(0, len)) {
          let ?byte = byte_buffer.popFront() else Runtime.unreachable();
          sink.add(#literal(byte));
        };
      };
    };

    /// Flush remaining bytes then reset the encoder to its initial state.
    public func finish(sink : Sink) {
      flush(sink);
      clear();
    };

    /// Reset the encoder to its initial state without emitting anything.
    public func clear() {
      search_buffer.clear();
      prefix_table.clear();
      byte_buffer.clear();
      cache_buffer.clear();
      input_size  := 0;
      match_index := null;
    };

  }; // end class Encoder

}
