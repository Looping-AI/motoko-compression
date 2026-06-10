/// Deflate decoder — RFC 1951.
///
/// Single-pass fused decoder: one tight loop per block, no per-symbol
/// allocations, Nat64 bit accumulator, [var Nat8] output buffer.
///
/// Public API:
///   fromBytes(inputBytes : [Nat8]) : Decoder
///   fromSlice(src : [var Nat8], start, len) : Decoder   — zero-copy
///   decodeStreamingWithCapacity(initOutCap, consume) : Result<(), Text>
///   bytesConsumed() : Nat   — bytes read from input (for Gzip footer parsing)

import Array "mo:core/Array";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat64 "mo:core/Nat64";
import Prim "mo:⛔";
import Result "mo:core/Result";
import Runtime "mo:core/Runtime";
import BitAccumulator "../internal/BitAccumulator";
import HuffmanDecoder "../Huffman/Decoder";
import OutByteBuffer "../internal/OutByteBuffer";
import Symbol "Symbol";

module {

  type Result<A, B> = Result.Result<A, B>;

  // ── RFC 1951 length/distance decode tables ─────────────────────────────
  // (base, extra_bits) indexed by (length_code - 257) and distance_code.
  // Re-declared here to keep the new decoder self-contained.

  let LENGTH_TABLE : [(Nat64, Nat64)] = [
    (3, 0),
    (4, 0),
    (5, 0),
    (6, 0),
    (7, 0),
    (8, 0),
    (9, 0),
    (10, 0),
    (11, 1),
    (13, 1),
    (15, 1),
    (17, 1),
    (19, 2),
    (23, 2),
    (27, 2),
    (31, 2),
    (35, 3),
    (43, 3),
    (51, 3),
    (59, 3),
    (67, 4),
    (83, 4),
    (99, 4),
    (115, 4),
    (131, 5),
    (163, 5),
    (195, 5),
    (227, 5),
    (258, 0),
  ];

  let DISTANCE_TABLE : [(Nat64, Nat64)] = [
    (1, 0),
    (2, 0),
    (3, 0),
    (4, 0),
    (5, 1),
    (7, 1),
    (9, 2),
    (13, 2),
    (17, 3),
    (25, 3),
    (33, 4),
    (49, 4),
    (65, 5),
    (97, 5),
    (129, 6),
    (193, 6),
    (257, 7),
    (385, 7),
    (513, 8),
    (769, 8),
    (1025, 9),
    (1537, 9),
    (2049, 10),
    (3073, 10),
    (4097, 11),
    (6145, 11),
    (8193, 12),
    (12_289, 12),
    (16_385, 13),
    (24_577, 13),
  ];

  // ── Baked payload mappers (Phase 1) ────────────────────────────────────
  // Fold literal/length and distance semantics directly into the Huffman
  // decode-table entries (via HuffmanDecoder.bakePayloads), so the hot loop
  // needs no secondary LENGTH_TABLE / DISTANCE_TABLE lookup per match.
  //
  // Lit/len payload (the value stored as `entry / 32`):
  //   low 2 bits = kind: 0 literal, 1 length, 2 end-of-block, 3 invalid
  //   literal:  byte  = payload >> 6
  //   length:   extra = (payload >> 2) & 0xF,  base = payload >> 6
  func litLenPayload(sym : Nat) : Nat64 {
    if (sym < 256) {
      Nat64.fromNat(sym) * 64 // (byte << 6) | kind 0
    } else if (sym == 256) {
      2 // end-of-block (kind 2)
    } else if (sym <= 285) {
      let (baseLen, lenExtra) = LENGTH_TABLE[sym - 257];
      baseLen * 64 + lenExtra * 4 + 1 // (base << 6) | (extra << 2) | kind 1
    } else {
      3 // invalid length code (symbols 286, 287)
    };
  };

  // Distance payload: low 4 bits = extra bit count, base = payload >> 4.
  func distPayload(sym : Nat) : Nat64 {
    let (baseDist, distExtra) = DISTANCE_TABLE[sym];
    baseDist * 16 + distExtra // (base << 4) | extra
  };

  // ── Fixed Huffman table builders ───────────────────────────────────────
  // Module-level private functions — bodies can use var/loops freely.
  // Called from the Decoder class constructor (once per decode call).

  func buildFixedLitDecoder() : HuffmanDecoder.FastDecoder {
    // RFC 1951 §3.2.6 bitwidths:
    //   0-143  → 8 bits    144-255 → 9 bits
    //   256-279 → 7 bits   280-287 → 8 bits
    let bws = Prim.Array_init<Nat>(288, 0);
    var s = 0;
    while (s <= 143) { bws[s] := 8; s += 1 };
    while (s <= 255) { bws[s] := 9; s += 1 };
    while (s <= 279) { bws[s] := 7; s += 1 };
    while (s <= 287) { bws[s] := 8; s += 1 };
    switch (HuffmanDecoder.fromBitwidthsFast(Array.fromVarArray(bws))) {
      case (#ok(d)) d;
      case (#err(e)) Runtime.trap("buildFixedLitDecoder: " # e);
    };
  };

  func buildFixedDistDecoder() : HuffmanDecoder.FastDecoder {
    // RFC 1951 §3.2.6: all 30 distance codes have bitwidth 5.
    let bws = Prim.Array_init<Nat>(30, 5);
    switch (HuffmanDecoder.fromBitwidthsFast(Array.fromVarArray(bws))) {
      case (#ok(d)) d;
      case (#err(e)) Runtime.trap("buildFixedDistDecoder: " # e);
    };
  };

  // ── Decoder class ──────────────────────────────────────────────────────

  /// Stateful RFC 1951 Deflate decoder. Feed it a `BitAccumulator` and drive
  /// decompression with `decodeBounded` (suspendable) or `decodeStreamingWithCapacity`.
  public class Decoder(acc : BitAccumulator.BitAccumulator) {

    var err : ?Text = null;
    let fixedLit : HuffmanDecoder.FastDecoder = buildFixedLitDecoder();
    let fixedDist : HuffmanDecoder.FastDecoder = buildFixedDistDecoder();

    // Bake length/distance semantics into the fixed decode tables once, so
    // the hot loop reads base + extra-bit counts straight from the entries.
    do {
      HuffmanDecoder.bakePayloads(fixedLit, litLenPayload);
      HuffmanDecoder.bakePayloads(fixedDist, distPayload);
    };

    // ── Resumable streaming state ─────────────────────────────────────────
    // WINDOW: minimum history to retain so every back-reference (distance
    // <= 32768) still resolves after a flush.
    let WINDOW : Nat = 32768;
    // FLUSH_CHUNK: only compact the buffer when the excess above WINDOW
    // reaches this threshold. This amortizes the dropFront memmove cost:
    // instead of shifting WINDOW bytes once per block (~32 KiB / block), we
    // shift (WINDOW + FLUSH_CHUNK) bytes once per FLUSH_CHUNK of output —
    // roughly 32× fewer shifts.
    let FLUSH_CHUNK : Nat = 1_048_576; // 1 MiB

    // Output buffer + block-loop position persist across `decodeBounded` calls
    // so decoding can suspend at block boundaries and resume on a later message.
    var outBuf : ?OutByteBuffer.OutByteBuffer = null;
    var bfinal : Bool = false;
    var done : Bool = false;

    // ── Public API ────────────────────────────────────────────────────────

    /// Decode blocks until the stream ends, an error occurs, or at least
    /// `maxOutBytes` have been emitted via `consume` during this call, then
    /// return `#more` (suspend) or `#done`. State (output window + accumulator
    /// position) persists between calls, so a large stream can be decompressed
    /// across many bounded messages.
    ///
    /// `initOutCap` pre-sizes the output buffer on the first call (e.g. Gzip
    /// ISIZE), capped at WINDOW + FLUSH_CHUNK; pass 0 for the 64 KiB default.
    /// Ignored on subsequent calls once the buffer exists.
    ///
    /// Retains only a 32 KiB sliding window after each flush so arbitrarily
    /// large streams never materialize the full output.
    public func decodeBounded(
      initOutCap : Nat,
      maxOutBytes : Nat,
      consume : ([Nat8]) -> (),
    ) : Result<{ #more; #done }, Text> {
      switch err { case (?msg) return #err(msg); case null {} };
      if (done) return #ok(#done);

      let maxCap = WINDOW + FLUSH_CHUNK;
      let out = switch (outBuf) {
        case (?o) o;
        case null {
          // Initial capacity: use the caller's hint (e.g. Gzip ISIZE), capped
          // at maxCap so we never over-allocate, 64 KiB floor when no hint.
          let initCap : Nat = if (initOutCap > 0) Nat.min(initOutCap, maxCap) else 65536;
          let o = OutByteBuffer.OutByteBuffer(initCap);
          outBuf := ?o;
          o;
        };
      };
      var emitted : Nat = 0;

      label blocks loop {
        if (bfinal) break blocks;

        if (acc.bitsLeft() == 0) {
          err := ?"Deflate: stream ended before final block";
          break blocks;
        };

        bfinal := acc.readBit(); // BFINAL
        let btype = acc.readBits(2); // BTYPE

        if (btype == 0) {
          decodeStoredBlock(out);
        } else if (btype == 1) {
          decodeCompressedBlock(out, fixedLit, fixedDist);
        } else if (btype == 2) {
          switch (loadDynamicHeader()) {
            case (#ok((ld, dd))) decodeCompressedBlock(out, ld, dd);
            case (#err(msg)) { err := ?msg; break blocks };
          };
        } else {
          err := ?"Deflate: invalid block type 3";
          break blocks;
        };

        if (err != null) break blocks;

        // Emit the accumulated batch once it exceeds WINDOW + FLUSH_CHUNK,
        // retaining exactly the last WINDOW bytes for back-reference resolution.
        let sz = out.size();
        if (sz >= WINDOW + FLUSH_CHUNK) {
          let f : Nat = sz - WINDOW;
          consume(out.copyRange(0, f));
          out.dropFront(f);
          emitted += f;
        };

        // Suspend at a block boundary once the per-call output budget is met,
        // unless this was the final block (then fall through to flush the tail).
        if (not bfinal and emitted >= maxOutBytes) {
          return #ok(#more);
        };
      };

      switch err {
        case (?msg) #err(msg);
        case null {
          // Final block reached: flush the retained tail.
          let sz = out.size();
          if (sz > 0) {
            consume(out.copyRange(0, sz));
            out.dropFront(sz);
          };
          done := true;
          #ok(#done);
        };
      };
    };

    /// Decompress the whole stream in one call, emitting output in bounded
    /// chunks via `consume`. Thin wrapper that drives `decodeBounded` to
    /// completion; see `decodeBounded` for the resumable variant.
    public func decodeStreamingWithCapacity(initOutCap : Nat, consume : ([Nat8]) -> ()) : Result<(), Text> {
      loop {
        switch (decodeBounded(initOutCap, FLUSH_CHUNK, consume)) {
          case (#err(msg)) return #err(msg);
          case (#ok(#more)) {};
          case (#ok(#done)) return #ok(());
        };
      };
    };

    /// Number of input bytes consumed after decode().
    /// Rounded up to the next byte boundary (callers use this to locate
    /// the Gzip footer that follows the deflate data).
    public func bytesConsumed() : Nat {
      (acc.bitPosition() + 7) / 8;
    };

    // ── Stored block (type 0) ─────────────────────────────────────────────

    func decodeStoredBlock(out : OutByteBuffer.OutByteBuffer) {
      acc.byteAlign();
      let len0 = Nat8.toNat(acc.readByte());
      let len1 = Nat8.toNat(acc.readByte());
      let size = len0 + len1 * 256;
      let nlen0 = Nat8.toNat(acc.readByte());
      let nlen1 = Nat8.toNat(acc.readByte());
      let nlen = nlen0 + nlen1 * 256;
      // RFC 1951: NLEN is one's complement of LEN ↔ nlen + size == 0xFFFF
      if (nlen + size != 0xFFFF) {
        err := ?"Deflate: LEN/NLEN mismatch in stored block";
        return;
      };
      var i = 0;
      while (i < size) { out.add(acc.readByte()); i += 1 };
    };

    // ── Compressed block (type 1 or 2) ────────────────────────────────────
    //
    // The accumulator state (hold/bits/pos) is hoisted into Wasm-local var
    // bindings for the duration of this block.  All refill/peek/drop logic
    // is inlined so the hot path contains no cross-object method calls.

    func decodeCompressedBlock(
      out : OutByteBuffer.OutByteBuffer,
      litDec : HuffmanDecoder.FastDecoder,
      distDec : HuffmanDecoder.FastDecoder,
    ) {
      // Pull accumulator state into locals.
      let src = acc.getBytes();
      let srcLen = acc.getBytesLen();
      let (h0, b0, p0) = acc.snapshotAcc();
      var hold : Nat64 = h0;
      var bits : Nat64 = b0;
      var pos : Nat = p0;

      // Pre-compute decoder table references, primary masks, and rootBits as Nat64.
      let litTbl = litDec.table;
      let litRootBits = litDec.rootBits;
      let litRootBits64 : Nat64 = Nat64.fromNat(litRootBits);
      let litMask : Nat64 = ((1 : Nat64) << litRootBits64) - 1;
      let distTbl = distDec.table;
      let distRootBits = distDec.rootBits;
      let distRootBits64 : Nat64 = Nat64.fromNat(distRootBits);
      let distMask : Nat64 = ((1 : Nat64) << distRootBits64) - 1;

      // Hoist the output backing store into locals to remove per-symbol
      // method-call overhead on the hot path. `obuf`/`ocap` are re-fetched
      // whenever the slow path grows the buffer; `olen` is synced back via
      // out.setLen at every exit.
      var obuf = out.store();
      var olen = out.size();
      var ocap = out.capacity();

      label syms loop {
        // ── Inline litDec.decodeRaw ──────────────────────────────────────
        while (bits <= 56 and pos < srcLen) {
          hold := hold | (Nat64.fromNat8(src[pos]) << bits);
          bits += 8;
          pos += 1;
        };
        let lv : Nat64 = litTbl[Nat64.toNat(hold & litMask)];
        let lw : Nat64 = lv & 31;
        var lpayload : Nat64 = 0;
        if (lw > 15) {
          err := ?"Deflate: invalid literal/length Huffman code";
          break syms;
        };
        if (lw <= litRootBits64) {
          hold := hold >> lw;
          bits -= lw;
          lpayload := lv >> 5;
        } else {
          // Overflow: consume rootBits, look up subtable.
          hold := hold >> litRootBits64;
          bits -= litRootBits64;
          let lsub : Nat64 = lw - litRootBits64;
          let loff = Nat64.toNat(lv >> 5);
          // No refill needed: top-of-loop refill guarantees ≥57 bits;
          // a full match consumes ≤48, so we always have enough here.
          let lv2 : Nat64 = litTbl[loff + Nat64.toNat(hold & (((1 : Nat64) << lsub) - 1))];
          let lw2 : Nat64 = lv2 & 31;
          if (lw2 > lsub) {
            err := ?"Deflate: invalid literal/length Huffman code";
            break syms;
          };
          hold := hold >> lw2;
          bits -= lw2;
          lpayload := lv2 >> 5;
        };
        // ────────────────────────────────────────────────────────────────
        // Baked lit/len payload: low 2 bits = kind (0 literal, 1 length,
        // 2 end-of-block, 3 invalid). Literal byte = payload >> 6;
        // length extra = (payload >> 2) & 0xF, length base = payload >> 6.

        let lkind = lpayload & 3;
        if (lkind == 0) {
          // Literal byte.
          let byte = Nat8.fromNat(Nat64.toNat(lpayload >> 6));
          if (olen < ocap) {
            obuf[olen] := byte;
            olen += 1;
          } else {
            // Slow path: grow via OutByteBuffer, then re-fetch the store.
            out.setLen(olen);
            out.add(byte);
            obuf := out.store();
            olen := out.size();
            ocap := out.capacity();
          };
        } else if (lkind == 2) {
          break syms; // end-of-block
        } else if (lkind == 3) {
          err := ?"Deflate: invalid length code";
          break syms;
        } else {
          // Length code: base + extra-bit count baked into the payload.
          let lenExtra : Nat64 = (lpayload >> 2) & 0xF;
          var length : Nat64 = lpayload >> 6;
          if (lenExtra > 0) {
            let lemask : Nat64 = ((1 : Nat64) << lenExtra) - 1;
            length += hold & lemask;
            hold := hold >> lenExtra;
            bits -= lenExtra;
          };

          // ── Inline distDec.decodeRaw ─────────────────────────────────
          let dv : Nat64 = distTbl[Nat64.toNat(hold & distMask)];
          let dw : Nat64 = dv & 31;
          var dpayload : Nat64 = 0;
          if (dw > 15) {
            err := ?"Deflate: invalid distance Huffman code";
            break syms;
          };
          if (dw <= distRootBits64) {
            hold := hold >> dw;
            bits -= dw;
            dpayload := dv >> 5;
          } else {
            hold := hold >> distRootBits64;
            bits -= distRootBits64;
            let dsub : Nat64 = dw - distRootBits64;
            let doff = Nat64.toNat(dv >> 5);
            let dv2 : Nat64 = distTbl[doff + Nat64.toNat(hold & (((1 : Nat64) << dsub) - 1))];
            let dw2 : Nat64 = dv2 & 31;
            if (dw2 > dsub) {
              err := ?"Deflate: invalid distance Huffman code";
              break syms;
            };
            hold := hold >> dw2;
            bits -= dw2;
            dpayload := dv2 >> 5;
          };
          // ────────────────────────────────────────────────────────────
          // Baked distance payload: low 4 bits = extra-bit count,
          // distance base = payload >> 4.

          let distExtra : Nat64 = dpayload & 0xF;
          var distance : Nat64 = dpayload >> 4;
          if (distExtra > 0) {
            let demask : Nat64 = ((1 : Nat64) << distExtra) - 1;
            distance += hold & demask;
            hold := hold >> distExtra;
            bits -= distExtra;
          };

          let d = Nat64.toNat(distance);
          let l = Nat64.toNat(length);
          if (d <= olen and olen + l <= ocap) {
            // Fast path: copy directly into the hoisted backing store.
            if (d == 1) {
              // RLE fast-fill: repeat the last byte, no read inside the loop.
              let b = obuf[olen - 1];
              var i = 0;
              while (i < l) { obuf[olen] := b; olen += 1; i += 1 };
            } else {
              // Two-cursor copy; read follows write to preserve overlap.
              var s : Nat = olen - d;
              var dd : Nat = olen;
              var i = 0;
              while (i < l) { obuf[dd] := obuf[s]; s += 1; dd += 1; i += 1 };
              olen := dd;
            };
          } else {
            // Slow path: let OutByteBuffer validate the distance and grow.
            out.setLen(olen);
            out.copyMatch(d, l);
            obuf := out.store();
            olen := out.size();
            ocap := out.capacity();
          };
        };
      };

      // Sync output length back to the buffer (covers all exit paths).
      out.setLen(olen);
      // Sync accumulator locals back to the accumulator (covers all exit paths).
      acc.restoreAcc(hold, bits, pos);
    };

    // ── Dynamic header (type 2) ───────────────────────────────────────────

    func loadDynamicHeader() : Result<(HuffmanDecoder.FastDecoder, HuffmanDecoder.FastDecoder), Text> {
      let lcc = acc.readBits(5) + 257; // HLIT  + 257 = literal/length code count
      let dcc = acc.readBits(5) + 1; // HDIST + 1   = distance code count
      let bwcc = acc.readBits(4) + 4; // HCLEN + 4   = code-length code count

      if (lcc > 286) return #err("Deflate: HLIT too large: " # debug_show lcc);
      if (dcc > 30) return #err("Deflate: HDIST too large: " # debug_show dcc);

      // Read the meta code-length bitwidths (RFC 1951 §3.2.7 order).
      let bwArr = Prim.Array_init<Nat>(19, 0);
      var i = 0;
      while (i < bwcc) {
        bwArr[Symbol.BITWIDTH_CODE_ORDER[i]] := acc.readBits(3);
        i += 1;
      };

      let metaDec = switch (HuffmanDecoder.fromBitwidthsFast(Array.fromVarArray(bwArr))) {
        case (#ok(d)) d;
        case (#err(msg)) return #err("Deflate: meta-Huffman: " # msg);
      };

      // Expand literal/length bitwidths.
      let litBws = Prim.Array_init<Nat>(lcc, 0);
      var litPos = 0;
      var lastBw : Nat = 0;
      while (litPos < lcc) {
        let code = metaDec.decodeRaw(acc);
        if (code == HuffmanDecoder.DECODE_ERROR) return #err("Deflate: invalid meta-Huffman code in literal section");
        let (bw, cnt) = expandBwCode(code, lastBw);
        lastBw := bw;
        var j = 0;
        while (j < cnt and litPos < lcc) {
          litBws[litPos] := bw;
          litPos += 1;
          j += 1;
        };
      };

      // Expand distance bitwidths (lastBw carries over from literal section).
      let distBws = Prim.Array_init<Nat>(dcc, 0);
      var distPos = 0;
      while (distPos < dcc) {
        let code = metaDec.decodeRaw(acc);
        if (code == HuffmanDecoder.DECODE_ERROR) return #err("Deflate: invalid meta-Huffman code in distance section");
        let (bw, cnt) = expandBwCode(code, lastBw);
        lastBw := bw;
        var j = 0;
        while (j < cnt and distPos < dcc) {
          distBws[distPos] := bw;
          distPos += 1;
          j += 1;
        };
      };

      let ld = switch (HuffmanDecoder.fromBitwidthsFast(Array.fromVarArray(litBws))) {
        case (#ok(d)) d;
        case (#err(msg)) return #err("Deflate: literal decoder: " # msg);
      };
      let dd = switch (HuffmanDecoder.fromBitwidthsFast(Array.fromVarArray(distBws))) {
        case (#ok(d)) d;
        case (#err(msg)) return #err("Deflate: distance decoder: " # msg);
      };

      // Bake length/distance semantics into the per-block decode tables.
      HuffmanDecoder.bakePayloads(ld, litLenPayload);
      HuffmanDecoder.bakePayloads(dd, distPayload);

      #ok((ld, dd));
    };

    // Expand one meta bitwidth code → (bitwidth, repeat_count).
    //   16 = copy previous non-zero length 3+readBits(2) times
    //   17 = produce zeros for 3+readBits(3) times
    //   18 = produce zeros for 11+readBits(7) times
    //   0-15 = literal bitwidth, count 1
    func expandBwCode(code : Nat, lastBw : Nat) : (Nat, Nat) {
      switch code {
        case 16 { (lastBw, acc.readBits(2) + 3) };
        case 17 { (0, acc.readBits(3) + 3) };
        case 18 { (0, acc.readBits(7) + 11) };
        case _ { (code, 1) };
      };
    };

  };

  // ── Constructors ────────────────────────────────────────────────────────

  /// Build a decoder over an immutable compressed-byte array. The bytes are
  /// copied into a fresh mutable buffer; use `fromSlice` to decode in place.
  public func fromBytes(inputBytes : [Nat8]) : Decoder {
    Decoder(BitAccumulator.fromArray(inputBytes));
  };

  /// Build a decoder over the slice `[start, start + len)` of `src` without
  /// copying. The caller must keep `src` unmodified while decoding.
  public func fromSlice(src : [var Nat8], start : Nat, len : Nat) : Decoder {
    Decoder(BitAccumulator.fromSlice(src, start, len));
  };

};
