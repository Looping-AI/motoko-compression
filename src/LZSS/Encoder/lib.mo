/// LZSS encoder — zlib-style hash-chain implementation.
///
/// Replaces the prior CircularBuffer + 65 536-bucket prefix-table design with:
///   - A single flat byte window of size 2 * window_size (history + lookahead).
///   - `head[hash]` : Nat32  — most recent window position for each 3-byte hash
///                              (stored as position + 1, 0 = none).
///   - `prev[pos & WMASK]` : Nat32 — previous occurrence of the same hash
///                                    (same +1 encoding).
///   - Bounded chain walk in `longestMatch` (depth = `max_chain`,
///     #fast = 8, #balance = 32, #best = 256).
///
/// Output is delivered through a `MatchSink { onLiteral; onPointer }` callback
/// pair — no `LzssEntry` variant is ever allocated.
///
/// References: zlib's `deflate.c` (`fill_window`, `longest_match`, `deflate_slow`).

import Nat8 "mo:core/Nat8";
import Nat32 "mo:core/Nat32";
import Prim "mo:⛔";
import Common "../Common";

module {

  public type MatchSink = Common.MatchSink;

  // ── Per-level tuning ───────────────────────────────────────────────────

  func levelToWindowSize(level : Common.CompressionLevel) : Nat {
    switch level {
      case (#fast) 1_024;
      case (#balance) 8_192;
      case (#best) Common.MATCH_WINDOW_SIZE; // 32_768
    };
  };

  func levelToMaxChain(level : Common.CompressionLevel) : Nat {
    switch level {
      case (#fast) 8;
      case (#balance) 32;
      case (#best) 256;
    };
  };

  // Stop searching once a match this long is found (zlib `nice_match`).
  func levelToNiceLength(level : Common.CompressionLevel) : Nat {
    switch level {
      case (#fast) 16;
      case (#balance) 128;
      case (#best) 258;
    };
  };

  // Once a match this long is found, shorten the remaining chain walk to a
  // quarter (zlib `good_match`).
  func levelToGoodLength(level : Common.CompressionLevel) : Nat {
    switch level {
      case (#fast) 4;
      case (#balance) 8;
      case (#best) 32;
    };
  };

  // ── Constants ──────────────────────────────────────────────────────────

  let MIN_MATCH : Nat = 3;
  let MAX_MATCH : Nat = Common.MATCH_MAX_SIZE; // 258
  // Bytes of lookahead required before steady-state matching can run.
  // Matches zlib's MIN_LOOKAHEAD = MAX_MATCH + MIN_MATCH + 1.
  // (Literal because module-level lets can't combine other lets statically.)
  let MIN_LOOKAHEAD : Nat = 262;

  let HASH_SIZE : Nat = 32_768; // 2^15
  let HASH_MASK : Nat32 = 0x7FFF;
  let HASH_SHIFT : Nat32 = 5;

  // ── Module-level convenience API ───────────────────────────────────────

  public func default() : Encoder { Encoder(#best) };

  // ── Encoder class ──────────────────────────────────────────────────────

  public class Encoder(level : Common.CompressionLevel) {

    // Window: history + lookahead. All level choices use power-of-2 sizes,
    // so WMASK = WSIZE - 1 is a valid mask.
    let WSIZE : Nat = levelToWindowSize(level);
    let WPHYS : Nat = 2 * WSIZE;
    let MAX_CHAIN : Nat = levelToMaxChain(level);
    let NICE_LENGTH : Nat = levelToNiceLength(level);
    let GOOD_LENGTH : Nat = levelToGoodLength(level);
    // WSIZE is always a power of 2, so `p % WSIZE` is the same as `p & (WSIZE-1)`.
    // Motoko's Nat has no bitwise ops; we use modulo.
    let WMASK32 : Nat32 = Nat32.fromNat(WSIZE - 1);

    // Fast `p mod WSIZE` for positions guaranteed to fit in Nat32 (WPHYS < 2^17).
    func pmod(p : Nat) : Nat {
      Nat32.toNat(Nat32.bitand(Nat32.fromNat(p), WMASK32));
    };

    let window : [var Nat8] = Prim.Array_init<Nat8>(WPHYS, 0);
    let head : [var Nat32] = Prim.Array_init<Nat32>(HASH_SIZE, 0);
    let prev : [var Nat32] = Prim.Array_init<Nat32>(WSIZE, 0);

    // Current scan position in `window`.
    var strstart : Nat = 0;
    // Bytes available ahead of `strstart` (i.e. window[strstart..strstart+lookahead-1] valid).
    var lookahead : Nat = 0;

    // ── Internal helpers ─────────────────────────────────────────────────

    // 3-byte hash at window position `p`. Requires p+2 < WPHYS and the
    // three bytes to be valid (i.e. p+2 < strstart + lookahead).
    func hashAt(p : Nat) : Nat {
      let b0 = Nat8.toNat32(window[p]);
      let b1 = Nat8.toNat32(window[p + 1]);
      let b2 = Nat8.toNat32(window[p + 2]);
      let h = (((b0 << HASH_SHIFT) ^ b1) << HASH_SHIFT) ^ b2;
      Nat32.toNat(h & HASH_MASK);
    };

    // Insert the 3-byte string at position `p` into the hash chain.
    // Returns the previous head value (0 = no prior, else prior pos + 1).
    func insertString(p : Nat) : Nat32 {
      let h = hashAt(p);
      let priorHead = head[h];
      prev[pmod(p)] := priorHead;
      head[h] := Nat32.fromNat(p + 1);
      priorHead;
    };

    // Slide window: discard the oldest WSIZE bytes, shift the back half to the
    // front half, and decrement all hash entries. O(WSIZE + HASH_SIZE).
    func slideWindow() {
      var i = 0;
      while (i < WSIZE) { window[i] := window[WSIZE + i]; i += 1 };
      strstart -= WSIZE;
      let cut = Nat32.fromNat(WSIZE);
      i := 0;
      while (i < HASH_SIZE) {
        let v = head[i];
        head[i] := if (v > cut) v - cut else 0;
        i += 1;
      };
      i := 0;
      while (i < WSIZE) {
        let v = prev[i];
        prev[i] := if (v > cut) v - cut else 0;
        i += 1;
      };
    };

    // Find the longest match for window[strstart..] starting from window
    // position `startMatch`. Walks the prev[] chain up to MAX_CHAIN steps.
    // `maxLen` bounds the match length (= min(lookahead, MAX_MATCH)).
    // Returns (bestLen, bestDist); bestLen = 0 means no match >= MIN_MATCH.
    func longestMatch(startMatch : Nat, maxLen : Nat) : (Nat, Nat) {
      var bestLen : Nat = MIN_MATCH - 1; // require strictly greater
      var bestPos : Nat = 0;
      var cur : Nat = startMatch;
      var chainLen : Nat = MAX_CHAIN;
      var shortened : Bool = false;
      let scanStart = strstart;
      // Earliest legal match position (distance must be <= WSIZE).
      let limit : Int = (scanStart : Int) - WSIZE + 1;

      label chain loop {
        // Quick reject: the bestLen'th and 0th/1st bytes must match.
        if (
          window[cur + bestLen] == window[scanStart + bestLen] and window[cur] == window[scanStart] and window[cur + 1] == window[scanStart + 1]
        ) {
          // Compare bytes from offset 2 onwards.
          var k : Nat = 2;
          while (k < maxLen and window[cur + k] == window[scanStart + k]) {
            k += 1;
          };
          if (k > bestLen) {
            bestLen := k;
            bestPos := cur;
            if (k >= maxLen) break chain;
            // Long enough match found: stop searching entirely.
            if (bestLen >= NICE_LENGTH) break chain;
            // Decent match found: walk fewer remaining chain links.
            if (not shortened and bestLen >= GOOD_LENGTH) {
              chainLen /= 4;
              shortened := true;
            };
          };
        };
        chainLen -= 1;
        if (chainLen == 0) break chain;
        let p = prev[pmod(cur)];
        if (p == 0) break chain;
        let nextPos : Nat = Nat32.toNat(p) - 1;
        if (nextPos : Int < limit) break chain;
        cur := nextPos;
      };

      if (bestLen >= MIN_MATCH) {
        (bestLen, scanStart - bestPos);
      } else {
        (0, 0);
      };
    };

    // Process exactly one symbol (literal or pointer) at strstart.
    // Caller guarantees lookahead >= MIN_MATCH so that hashAt is safe.
    // `tailMode = true` means we're in flush; match length is bounded by
    // remaining lookahead instead of MAX_MATCH.
    func processOne(sink : MatchSink, tailMode : Bool) {
      // Insert the current 3-byte string and look up the chain head.
      let priorHead = insertString(strstart);
      var emitted = false;
      if (priorHead != 0) {
        let curMatch : Nat = Nat32.toNat(priorHead) - 1;
        let maxLen = if (tailMode and lookahead < MAX_MATCH) lookahead else MAX_MATCH;
        let (bestLen, bestDist) = longestMatch(curMatch, maxLen);
        if (bestLen >= MIN_MATCH) {
          sink.onPointer(bestDist, bestLen);
          // Insert hashes for positions skipped by the match (so future
          // matches see them). Skip positions whose 3-byte window would
          // run past the current valid lookahead.
          let endLookahead = strstart + lookahead;
          var k : Nat = 1;
          while (k < bestLen) {
            let p = strstart + k;
            if (p + MIN_MATCH <= endLookahead) {
              ignore insertString(p);
            };
            k += 1;
          };
          strstart += bestLen;
          lookahead -= bestLen;
          emitted := true;
        };
      };
      if (not emitted) {
        sink.onLiteral(window[strstart]);
        strstart += 1;
        lookahead -= 1;
      };
    };

    // ── Public encoding interface ────────────────────────────────────────

    /// Feed one byte. May emit zero or more entries once enough lookahead is buffered.
    public func encodeByte(future_byte : Nat8, sink : MatchSink) {
      // Make room in window if we're about to overflow.
      if (strstart + lookahead == WPHYS) slideWindow();
      window[strstart + lookahead] := future_byte;
      lookahead += 1;
      // In steady state, process exactly one symbol once we have full lookahead.
      while (lookahead >= MIN_LOOKAHEAD) {
        processOne(sink, false);
      };
    };

    /// Encode `bytes` by feeding them one at a time.
    public func encode(bytes : [Nat8], sink : MatchSink) {
      for (byte in bytes.vals()) {
        encodeByte(byte, sink);
      };
    };

    /// Drain any bytes still in the lookahead. Must be called once at EOF.
    public func flush(sink : MatchSink) {
      // Tail: lookahead < MIN_LOOKAHEAD. Emit one symbol at a time until empty.
      while (lookahead >= MIN_MATCH) {
        processOne(sink, true);
      };
      // Remaining 0..2 bytes can only be literals.
      while (lookahead > 0) {
        sink.onLiteral(window[strstart]);
        strstart += 1;
        lookahead -= 1;
      };
    };

    /// Reset to initial state.
    public func clear() {
      var i = 0;
      while (i < HASH_SIZE) { head[i] := 0; i += 1 };
      i := 0;
      while (i < WSIZE) { prev[i] := 0; i += 1 };
      strstart := 0;
      lookahead := 0;
    };

  }; // end class Encoder

};
