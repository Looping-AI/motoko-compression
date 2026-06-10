import Nat "mo:core/Nat";
import Nat16 "mo:core/Nat16";
import Nat64 "mo:core/Nat64";
import Result "mo:core/Result";
import Prim "mo:⛔";

import BitAccumulator "../internal/BitAccumulator";
import Common "Common";

module {
  type Result<A, B> = Result.Result<A, B>;

  let { MAX_BITWIDTH } = Common;

  /// Sentinel returned by `decodeRaw` / `FastDecoder.decodeRaw` when the bit
  /// stream contains an unrecognised pattern.  Callers must check for this
  /// value and propagate an error.
  public let DECODE_ERROR : Nat = 0xFFFF_FFFF;

  // ── Two-level (zlib-style) fast decoder ────────────────────────────────
  //
  // A single flat `[var Nat64]` table whose first 2^rootBits entries form the
  // primary table and the rest are subtables.  Each entry packs two fields:
  //   value = (payload * 32) + tag        where 0 ≤ tag ≤ MAX_BITWIDTH
  //
  // Primary table entry interpretation (low 5 bits = w = entry % 32):
  //   • w ≤ rootBits  → direct symbol;        payload = symbol; consume w bits
  //   • rootBits < w  → overflow pointer;     payload = subtable offset;
  //                       consume rootBits bits, then look up subtable at
  //                       (offset + peek(w - rootBits)).
  //
  // Subtable entry: payload = symbol; tag = code_length − rootBits
  //                 (i.e. additional bits to consume after the primary drop).
  //
  // Sentinel `SENTINEL = MAX_BITWIDTH + 1` (= 16) marks uninitialised slots
  // and is detected as an error (tag > MAX_BITWIDTH).

  let SENTINEL : Nat64 = 16; // = MAX_BITWIDTH + 1 (inlined to keep static)
  let FAST_ROOT_BITS : Nat = 10;
  let POW2 : [Nat] = [1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536];

  /// Two-level (zlib-style) fast Huffman decoder backed by a single flat table.
  /// Use `fromBitwidthsFast` to construct; decode symbols with `decodeRaw`.
  public class FastDecoder(tbl : [var Nat64], initRootBits : Nat) {

    /// Number of bits used for the primary table index (≤ `MAX_BITWIDTH`).
    public let rootBits = initRootBits;
    /// Flat packed decode table. Each entry packs a symbol/offset and a consume count.
    public let table = tbl;

    /// Decode one symbol from the bit accumulator.  Returns `DECODE_ERROR`
    /// on corrupt input (unrecognised pattern).  The accumulator state on
    /// error is unspecified — the caller must not continue decoding.
    public func decodeRaw(acc : BitAccumulator.BitAccumulator) : Nat {
      acc.refill();
      let v = tbl[acc.peekNat(rootBits)];
      let w = v & 31;
      if (w > Nat64.fromNat(MAX_BITWIDTH)) return DECODE_ERROR; // sentinel
      let wNat = Nat64.toNat(w);
      if (wNat <= rootBits) {
        acc.drop(wNat);
        return Nat64.toNat(v >> 5);
      };
      // Overflow path — w is the max code length of this subtable.
      acc.drop(rootBits);
      let subBits : Nat = wNat - rootBits;
      let subOffset = Nat64.toNat(v >> 5);
      acc.refill();
      let v2 = tbl[subOffset + acc.peekNat(subBits)];
      let w2 = v2 & 31;
      if (Nat64.toNat(w2) > subBits) return DECODE_ERROR; // sentinel or overlong
      acc.drop(Nat64.toNat(w2));
      Nat64.toNat(v2 >> 5);
    };
  };

  /// Build a two-level fast Huffman decoder from a per-symbol bitwidth array.
  /// `rootBits = min(max_bitwidth, FAST_ROOT_BITS)`, so trees whose codes
  /// all fit in `FAST_ROOT_BITS` bits get a single flat table (no overflow).
  public func fromBitwidthsFast(bitwidths : [Nat]) : Result<FastDecoder, Text> {
    if (bitwidths.size() == 0) {
      return #err("Cannot generate huffman codes from empty bitwidth array");
    };

    // Pass 1: find max bitwidth.
    var maxBw : Nat = 0;
    for (bw in bitwidths.vals()) {
      if (bw > maxBw) maxBw := bw;
    };

    if (maxBw > MAX_BITWIDTH) {
      return #err("Bitwidth " # debug_show maxBw # " exceeds MAX_BITWIDTH");
    };

    // No codes at all (all-zero bitwidths) — return a sentinel-only decoder.
    if (maxBw == 0) {
      let empty = Prim.Array_init<Nat64>(2, SENTINEL);
      return #ok(FastDecoder(empty, 1));
    };

    let rootBits = if (maxBw < FAST_ROOT_BITS) maxBw else FAST_ROOT_BITS;
    let primarySize : Nat = POW2[rootBits];

    // Pass 2: count non-zero entries, then collect and sort by bw.
    var pairsSize : Nat = 0;
    for (bw in bitwidths.vals()) {
      if (bw > 0) pairsSize += 1;
    };
    let pairs = Prim.Array_init<(Nat, Nat)>(pairsSize, (0, 0));
    var pIdx : Nat = 0;
    var i = 0;
    for (bw in bitwidths.vals()) {
      if (bw > 0) {
        pairs[pIdx] := (i, bw);
        pIdx += 1;
      };
      i += 1;
    };
    // Insertion sort by bitwidth — max 288 elements, negligible cost.
    var s = 1;
    while (s < pairsSize) {
      let tmp = pairs[s];
      var j = s;
      while (j > 0 and pairs[j - 1].1 > tmp.1) {
        pairs[j] := pairs[j - 1];
        j -= 1;
      };
      pairs[j] := tmp;
      s += 1;
    };

    // Pass 3: assign canonical codes; store reversed (LSB-first) bits.
    // entries: (symbol, bitwidth, reversed_bits_as_Nat)
    let entries = Prim.Array_init<(Nat, Nat, Nat)>(pairsSize, (0, 0, 0));
    var bits : Nat = 0;
    var prevBw : Nat = 0;
    var eIdx : Nat = 0;
    for ((sym, bw) in pairs.vals()) {
      bits *= POW2[bw - prevBw];
      let code : Common.Code = { bitwidth = bw; bits = Nat16.fromNat(bits) };
      let beCode = Common.reverseCodeBits(code);
      entries[eIdx] := (sym, bw, Nat16.toNat(beCode.bits));
      eIdx += 1;
      prevBw := bw;
      bits += 1;
    };

    // Pass 4: per primary-prefix, find max code length of codes that overflow.
    let subMaxBw = Prim.Array_init<Nat>(primarySize, 0);
    for ((_, bw, beBits) in entries.vals()) {
      if (bw > rootBits) {
        let prefix = beBits % primarySize;
        if (bw > subMaxBw[prefix]) subMaxBw[prefix] := bw;
      };
    };

    // Pass 5: assign subtable offsets, compute total table size.
    let subOffset = Prim.Array_init<Nat>(primarySize, 0);
    var total : Nat = primarySize;
    var k = 0;
    while (k < primarySize) {
      if (subMaxBw[k] > 0) {
        subOffset[k] := total;
        total += POW2[subMaxBw[k] - rootBits];
      };
      k += 1;
    };

    let tbl = Prim.Array_init<Nat64>(total, SENTINEL);

    // Pass 6a: install primary overflow pointers.
    k := 0;
    while (k < primarySize) {
      if (subMaxBw[k] > 0) {
        // tag = max_bw (> rootBits, ≤ MAX_BITWIDTH) — encodes "this is overflow"
        // AND the number of extra bits to peek (= tag - rootBits).
        tbl[k] := (Nat64.fromNat(subOffset[k]) << 5) | Nat64.fromNat(subMaxBw[k]);
      };
      k += 1;
    };

    // Pass 6b: fill direct entries (primary) and subtable entries.
    for ((sym, bw, beBits) in entries.vals()) {
      let value : Nat64 = (Nat64.fromNat(sym) << 5) | Nat64.fromNat(bw);
      if (bw <= rootBits) {
        let step = POW2[bw];
        let padCount : Nat = POW2[rootBits - bw];
        var p = 0;
        while (p < padCount) {
          tbl[beBits + p * step] := value;
          p += 1;
        };
      } else {
        let prefix = beBits % primarySize;
        let off = subOffset[prefix];
        let mbw = subMaxBw[prefix];
        let extraBw : Nat = bw - rootBits;
        let extraBits = beBits / primarySize;
        let step = POW2[extraBw];
        let padCount : Nat = POW2[mbw - bw];
        let value64 : Nat64 = (Nat64.fromNat(sym) << 5) | Nat64.fromNat(extraBw);
        var p = 0;
        while (p < padCount) {
          tbl[off + extraBits + p * step] := value64;
          p += 1;
        };
      };
    };

    #ok(FastDecoder(tbl, rootBits));
  };

  /// Rewrite the payload field (`entry / 32`) of every *resolved-symbol*
  /// table slot using `mapPayload`, leaving the consume tag (`entry % 32`),
  /// overflow pointers, and sentinel/pad slots untouched.
  ///
  /// This lets a caller fold symbol-specific semantics (e.g. DEFLATE
  /// length/distance base + extra-bit counts) directly into the decode
  /// table so the hot loop needs no secondary lookup. The mapped payload
  /// replaces the symbol; the caller's hot loop is responsible for decoding
  /// the new payload layout. Must be applied at most once per table.
  ///
  /// Resolved slots are: primary entries with tag ≤ rootBits, and all
  /// non-sentinel subtable entries. Overflow-pointer primary entries (tag in
  /// (rootBits, MAX_BITWIDTH]) carry a subtable offset, not a symbol, and
  /// are skipped. Sentinel/pad slots (tag = MAX_BITWIDTH + 1) are skipped.
  public func bakePayloads(dec : FastDecoder, mapPayload : Nat -> Nat64) {
    let tbl = dec.table;
    let rootBits64 = Nat64.fromNat(dec.rootBits);
    let maxBw64 = Nat64.fromNat(MAX_BITWIDTH);
    let primarySize = POW2[dec.rootBits];
    let n = tbl.size();
    var i = 0;
    while (i < n) {
      let v = tbl[i];
      let w = v % 32;
      // Resolved symbol slot iff: non-sentinel (w ≤ MAX_BITWIDTH), and either
      // in a subtable (i ≥ primarySize) or a direct primary entry (w ≤ root).
      if (w >= 1 and w <= maxBw64 and (i >= primarySize or w <= rootBits64)) {
        let sym = Nat64.toNat(v >> 5);
        tbl[i] := (mapPayload(sym) << 5) | w;
      };
      i += 1;
    };
  };
};
