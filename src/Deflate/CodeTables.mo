/// Precomputed RFC 1951 length/distance code lookup tables.
///
/// Replaces the per-symbol if-else length cascade and the O(log d) distance
/// while-loop in the encoder hot path (`Block.Compress`) with O(1) indexed
/// loads. Mirrors zlib's `tr_static_init` (`_length_code`, `_dist_code`,
/// `base_dist`).
///
/// Motoko forbids non-static expressions (loops, function applications) at
/// module scope, so these tables are built once inside the class constructor
/// and reused for the lifetime of the encoder (one instance per compress op).

import Prim "mo:⛔";

module {

  public class CodeTables() {

    // ── Source extra-bit counts (literal arrays, written at module scope) ──

    // Extra-bit counts for length codes 257..284 (indices 0..27). Length code
    // 285 (length 258) has 0 extra bits and is patched in after the loop.
    let lengthExtra : [Nat] = [
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      1,
      1,
      1,
      1,
      2,
      2,
      2,
      2,
      3,
      3,
      3,
      3,
      4,
      4,
      4,
      4,
      5,
      5,
      5,
      5,
    ];

    // Extra-bit counts for distance codes 0..29.
    let distExtra : [Nat] = [
      0,
      0,
      0,
      0,
      1,
      1,
      2,
      2,
      3,
      3,
      4,
      4,
      5,
      5,
      6,
      6,
      7,
      7,
      8,
      8,
      9,
      9,
      10,
      10,
      11,
      11,
      12,
      12,
      13,
      13,
    ];

    // ── Public lookup tables ───────────────────────────────────────────────

    // Indexed by `len - 3` (len ∈ 3..258).
    public let lengthCode : [var Nat] = Prim.Array_init<Nat>(256, 0);
    public let lengthExtraBits : [var Nat] = Prim.Array_init<Nat>(256, 0);
    public let lengthExtraVal : [var Nat] = Prim.Array_init<Nat>(256, 0);

    // Indexed by distance code (0..29).
    public let distExtraBits : [var Nat] = Prim.Array_init<Nat>(30, 0);
    public let distBase : [var Nat] = Prim.Array_init<Nat>(30, 0);

    // zlib two-tier `_dist_code`: [0..255] = zero-based distance direct;
    // [256..511] indexed by `256 + (zeroDist >> 7)`.
    let distCodeTbl : [var Nat] = Prim.Array_init<Nat>(512, 0);

    // ── Helpers ─────────────────────────────────────────────────────────────

    func pow2(k : Nat) : Nat {
      var r = 1;
      var i = 0;
      while (i < k) { r *= 2; i += 1 };
      r;
    };

    // ── Table construction (constructor body) ──────────────────────────────

    // Length tables: codes 0..27 (actual 257..284) fill len 3..257; index = len - 3.
    var li = 0; // index = len - 3
    var lc = 0; // length-code offset 0..27
    while (lc < 28) {
      let extra = lengthExtra[lc];
      let cnt = pow2(extra);
      var n = 0;
      while (n < cnt) {
        lengthCode[li] := 257 + lc;
        lengthExtraBits[li] := extra;
        lengthExtraVal[li] := n;
        li += 1;
        n += 1;
      };
      lc += 1;
    };
    // Patch the final entry (len 258) → code 285, no extra bits.
    lengthCode[255] := 285;
    lengthExtraBits[255] := 0;
    lengthExtraVal[255] := 0;

    // Distance extra-bit table.
    var de = 0;
    while (de < 30) { distExtraBits[de] := distExtra[de]; de += 1 };

    // Two-tier `_dist_code` + actual base distances.
    // Low part: codes 0..15, zero-based distance index 0..255.
    var d = 0; // zero-based distance
    var code = 0;
    while (code < 16) {
      distBase[code] := d + 1; // actual base = zero-based + 1
      let cnt = pow2(distExtra[code]);
      var n = 0;
      while (n < cnt) { distCodeTbl[d] := code; d += 1; n += 1 };
      code += 1;
    };
    // High part: codes 16..29, indexed by 256 + (zero >> 7). `d` is now 256,
    // so the high-tier cursor starts at 256 / 128 = 2.
    var hd = d / 128;
    while (code < 30) {
      distBase[code] := (hd * 128) + 1; // actual base
      let cnt = pow2(distExtra[code] - 7);
      var n = 0;
      while (n < cnt) { distCodeTbl[256 + hd] := code; hd += 1; n += 1 };
      code += 1;
    };

    // ── Lookup ───────────────────────────────────────────────────────────────

    /// Distance code (0..29) for an actual back-reference distance (1..32768).
    public func distCodeOf(distance : Nat) : Nat {
      if (distance <= 256) {
        distCodeTbl[distance - 1];
      } else {
        distCodeTbl[256 + (distance - 1) / 128];
      };
    };
  };
};
