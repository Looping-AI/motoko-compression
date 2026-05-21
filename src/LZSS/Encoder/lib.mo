/// LZSS encoder.
///
/// Migrated from edjcase/motoko_compression, replacing mo:base + external
/// packages with mo:core only.
///
/// Key changes from original:
///   - Encoder(opt_window_size : ?Nat) → Encoder(level : CompressionLevel),
///     mapping #fast → 1 024, #balance → 8 192, #best → 32 768.
///   - mo:buffer-deque/BufferDeque (byte_buffer) → CircularBuffer + popFront().
///   - mo:circular-buffer (search_buffer) → CircularBuffer; cache_buffer → two ?Nat8 scalars.
///   - Hot Itertools.range loops → direct while loops.
///   - Prelude.unreachable() → Runtime.unreachable().
///   - Dead code removed: encode_v1, longest_prefix_length.

import List "mo:core/List";
import Option "mo:core/Option";
import Nat8 "mo:core/Nat8";
import Runtime "mo:core/Runtime";
import CircularBuffer "../../internal/CircularBuffer";
import Common "../Common";
import PrefixTable "PrefixTable/lib";

module {

  type LzssEntry = Common.LzssEntry;

  /// Caller-supplied consumer for encoded entries.
  public type Sink = {
    add : (entry : LzssEntry) -> ();
  };

  // ── Window size per compression level ──────────────────────────────────

  func levelToWindowSize(level : Common.CompressionLevel) : Nat {
    switch level {
      case (#fast) 1_024;
      case (#balance) 8_192;
      case (#best) Common.MATCH_WINDOW_SIZE; // 32_768
    };
  };

  // ── Public API ──────────────────────────────────────────────────────────

  /// Create an encoder at the best (highest ratio) compression level.
  public func default() : Encoder { Encoder(#best) };

  /// Encode `bytes` at the best compression level and return the entry list.
  public func encode(bytes : [Nat8]) : List.List<LzssEntry> {
    let lzss = default();
    let buffer = List.empty<LzssEntry>();
    let sink : Sink = { add = func(e) { List.add(buffer, e) } };
    lzss.encode(bytes, sink);
    lzss.flush(sink);
    buffer;
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
    // Two scalar slots; push-on-full evicts the oldest (keeps last 2 bytes).
    var cache0 : ?Nat8 = null; // oldest cached byte, null if cache is empty
    var cache1 : ?Nat8 = null; // newest cached byte, null if ≤1 entry

    var match_index : ?Nat = null;
    var input_size : Nat = 0;

    // ── Internals ──────────────────────────────────────────────────────────

    /// Emit `n` bytes from the front of byte_buffer as literals.
    func encodeAsLiterals(n : Nat, sink : Sink) {
      var emitted = 0;
      while (emitted < n) {
        let byte = byte_buffer.popFrontUnchecked();
        search_buffer.push(byte);
        sink.add(#literal(byte));
        input_size += 1;
        emitted += 1;
      };
    };

    // ── Public encoding interface ──────────────────────────────────────────

    /// Feed one future byte into the streaming encoder.
    public func encodeByte(future_byte : Nat8, sink : Sink) {
      byte_buffer.push(future_byte);

      // Seed the prefix table using bytes recently emitted during a match.
      // cache_buffer holds the last 1-2 emitted bytes; combined with the
      // front of byte_buffer they form new 3-byte prefixes to record.
      switch (cache0, cache1) {
        case (?c0, ?c1) {
          ignore prefix_table.insert(c0, c1, byte_buffer.getUnchecked(0), input_size - 2);
          cache0 := ?c1;
          cache1 := null;
        };
        case (?c0, null) {
          if (byte_buffer.size() >= 2) {
            ignore prefix_table.insert(c0, byte_buffer.getUnchecked(0), byte_buffer.getUnchecked(1), input_size - 1);
            cache0 := null;
          };
        };
        case _ {};
      };

      if (byte_buffer.size() < 3) return;

      if (byte_buffer.size() == 3) {
        // Try to start a new match at the current lookahead position.
        let opt_prefix_index = prefix_table.insert(
          byte_buffer.getUnchecked(0),
          byte_buffer.getUnchecked(1),
          byte_buffer.getUnchecked(2),
          input_size,
        );
        switch (opt_prefix_index) {
          case (null) {
            encodeAsLiterals(1, sink);
            match_index := null;
          };
          case (?prefix_index) {
            let backward_offset = (input_size - prefix_index) : Nat;
            if (backward_offset > search_buffer.size()) {
              // The match is outside the current window; emit literal instead.
              encodeAsLiterals(1, sink);
              match_index := null;
            } else {
              match_index := opt_prefix_index;
            };
          };
        };
      } else {
        // byte_buffer.size() > 3: we are extending an existing match.
        let ?prefix_index = match_index else Runtime.unreachable();
        let backward_offset = (input_size - prefix_index) : Nat;
        let start_index = (search_buffer.size() - backward_offset) : Nat;
        let future_byte_index = start_index + (byte_buffer.size() - 1) : Nat;

        let mismatch = future_byte_index >= search_buffer.size() or future_byte != search_buffer.getUnchecked(future_byte_index);
        let too_long = byte_buffer.size() >= Common.MATCH_MAX_SIZE;

        if (mismatch or too_long) {
          // Emit the accumulated match (all but the last buffered byte).
          let len = (byte_buffer.size() - 1) : Nat;

          var emitted = 0;
          while (emitted < len) {
            // While 3+ bytes remain, record the current 3-byte prefix.
            if (byte_buffer.size() >= 3) {
              ignore prefix_table.insert(
                byte_buffer.getUnchecked(0),
                byte_buffer.getUnchecked(1),
                byte_buffer.getUnchecked(2),
                emitted + input_size,
              );
            };
            let byte = byte_buffer.popFrontUnchecked();
            search_buffer.push(byte);
            // When fewer than 3 bytes remain, seed cache for the next
            // encodeByte call to complete the prefix table entry.
            if (byte_buffer.size() < 3) {
              switch (cache0, cache1) {
                case (_, ?_) { cache0 := cache1; cache1 := ?byte };
                case (?_, null) { cache1 := ?byte };
                case _ { cache0 := ?byte };
              };
            };
            emitted += 1;
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
        encodeByte(byte, sink);
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
        var emitted = 0;
        while (emitted < len) {
          let byte = byte_buffer.popFrontUnchecked();
          sink.add(#literal(byte));
          emitted += 1;
        };
      };
    };

    /// Reset the encoder to its initial state without emitting anything.
    public func clear() {
      search_buffer.clear();
      prefix_table.clear();
      byte_buffer.clear();
      cache0 := null;
      cache1 := null;
      input_size := 0;
      match_index := null;
    };

  }; // end class Encoder

};
