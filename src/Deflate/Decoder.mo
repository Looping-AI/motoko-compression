/// Deflate decoder — RFC 1951.
///
/// Single-pass fused decoder: one tight loop per block, no per-symbol
/// allocations, Nat64 bit accumulator, [var Nat8] output buffer.
///
/// Public API:
///   Decoder(inputBytes : [Nat8])
///   decode() : Result<[Nat8], Text>
///   bytesConsumed() : Nat   — bytes read from input (for Gzip footer parsing)

import Array "mo:core/Array";
import Nat8 "mo:core/Nat8";
import Nat32 "mo:core/Nat32";
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

  let LENGTH_TABLE : [(Nat, Nat)] = [
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

  let DISTANCE_TABLE : [(Nat, Nat)] = [
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

  public class Decoder(inputBytes : [Nat8]) {

    let acc = BitAccumulator.BitAccumulator(inputBytes);
    var err : ?Text = null;
    let fixedLit : HuffmanDecoder.FastDecoder = buildFixedLitDecoder();
    let fixedDist : HuffmanDecoder.FastDecoder = buildFixedDistDecoder();

    // ── Public API ────────────────────────────────────────────────────────

    /// Decompress the full deflate stream and return the decoded bytes.
    public func decode() : Result<[Nat8], Text> {
      let out = OutByteBuffer.OutByteBuffer(65536);
      var bfinal = false;

      label _blocks loop {
        if (bfinal) break _blocks;

        if (acc.bitsLeft() == 0) {
          err := ?"Deflate: stream ended before final block";
          break _blocks;
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
            case (#err(msg)) { err := ?msg; break _blocks };
          };
        } else {
          err := ?"Deflate: invalid block type 3";
          break _blocks;
        };

        if (err != null) break _blocks;
      };

      let resp = switch err {
        case (?msg) #err(msg);
        case null #ok(out.toArray());
      };
      return resp;
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

      // Pre-compute decoder table references and primary masks.
      let litTbl = litDec.table;
      let litRootBits = litDec.root_bits;
      let litMask : Nat64 = ((1 : Nat64) << Nat64.fromNat(litRootBits)) - 1;
      let distTbl = distDec.table;
      let distRootBits = distDec.root_bits;
      let distMask : Nat64 = ((1 : Nat64) << Nat64.fromNat(distRootBits)) - 1;

      label _syms loop {
        // ── Inline litDec.decodeRaw ──────────────────────────────────────
        while (bits <= 56 and pos < srcLen) {
          hold := hold | (Nat64.fromNat32(Nat32.fromNat8(src[pos])) << bits);
          bits += 8;
          pos += 1;
        };
        let lv = litTbl[Nat64.toNat(hold & litMask)];
        let lw = lv % 32;
        var sym : Nat = 0;
        if (lw > 15) {
          err := ?"Deflate: invalid literal/length Huffman code";
          break _syms;
        };
        if (lw <= litRootBits) {
          hold := hold >> Nat64.fromNat(lw);
          bits -= Nat64.fromNat(lw);
          sym := lv / 32;
        } else {
          // Overflow: consume root_bits, look up subtable.
          hold := hold >> Nat64.fromNat(litRootBits);
          bits -= Nat64.fromNat(litRootBits);
          let lsub = lw - litRootBits;
          let loff = lv / 32;
          while (bits <= 56 and pos < srcLen) {
            hold := hold | (Nat64.fromNat32(Nat32.fromNat8(src[pos])) << bits);
            bits += 8;
            pos += 1;
          };
          let lv2 = litTbl[loff + Nat64.toNat(hold & (((1 : Nat64) << Nat64.fromNat(lsub)) - 1))];
          let lw2 = lv2 % 32;
          if (lw2 > lsub) {
            err := ?"Deflate: invalid literal/length Huffman code";
            break _syms;
          };
          hold := hold >> Nat64.fromNat(lw2);
          bits -= Nat64.fromNat(lw2);
          sym := lv2 / 32;
        };
        // ────────────────────────────────────────────────────────────────

        if (sym < 256) {
          out.add(Nat8.fromNat(sym));
        } else if (sym == 256) {
          break _syms; // end-of-block
        } else {
          // Length code 257..285
          let lenIdx : Nat = sym - 257;
          if (lenIdx >= 29) {
            err := ?("Deflate: invalid length code " # debug_show sym);
            break _syms;
          };
          let (baseLen, lenExtra) = LENGTH_TABLE[lenIdx];
          var length = baseLen;
          if (lenExtra > 0) {
            while (bits <= 56 and pos < srcLen) {
              hold := hold | (Nat64.fromNat32(Nat32.fromNat8(src[pos])) << bits);
              bits += 8;
              pos += 1;
            };
            let lemask : Nat64 = ((1 : Nat64) << Nat64.fromNat(lenExtra)) - 1;
            length += Nat64.toNat(hold & lemask);
            hold := hold >> Nat64.fromNat(lenExtra);
            bits -= Nat64.fromNat(lenExtra);
          };

          // ── Inline distDec.decodeRaw ─────────────────────────────────
          while (bits <= 56 and pos < srcLen) {
            hold := hold | (Nat64.fromNat32(Nat32.fromNat8(src[pos])) << bits);
            bits += 8;
            pos += 1;
          };
          let dv = distTbl[Nat64.toNat(hold & distMask)];
          let dw = dv % 32;
          var dc : Nat = 0;
          if (dw > 15) {
            err := ?"Deflate: invalid distance Huffman code";
            break _syms;
          };
          if (dw <= distRootBits) {
            hold := hold >> Nat64.fromNat(dw);
            bits -= Nat64.fromNat(dw);
            dc := dv / 32;
          } else {
            hold := hold >> Nat64.fromNat(distRootBits);
            bits -= Nat64.fromNat(distRootBits);
            let dsub = dw - distRootBits;
            let doff = dv / 32;
            while (bits <= 56 and pos < srcLen) {
              hold := hold | (Nat64.fromNat32(Nat32.fromNat8(src[pos])) << bits);
              bits += 8;
              pos += 1;
            };
            let dv2 = distTbl[doff + Nat64.toNat(hold & (((1 : Nat64) << Nat64.fromNat(dsub)) - 1))];
            let dw2 = dv2 % 32;
            if (dw2 > dsub) {
              err := ?"Deflate: invalid distance Huffman code";
              break _syms;
            };
            hold := hold >> Nat64.fromNat(dw2);
            bits -= Nat64.fromNat(dw2);
            dc := dv2 / 32;
          };
          // ────────────────────────────────────────────────────────────

          if (dc >= 30) {
            err := ?("Deflate: invalid distance code " # debug_show dc);
            break _syms;
          };
          let (baseDist, distExtra) = DISTANCE_TABLE[dc];
          var distance = baseDist;
          if (distExtra > 0) {
            while (bits <= 56 and pos < srcLen) {
              hold := hold | (Nat64.fromNat32(Nat32.fromNat8(src[pos])) << bits);
              bits += 8;
              pos += 1;
            };
            let demask : Nat64 = ((1 : Nat64) << Nat64.fromNat(distExtra)) - 1;
            distance += Nat64.toNat(hold & demask);
            hold := hold >> Nat64.fromNat(distExtra);
            bits -= Nat64.fromNat(distExtra);
          };

          out.copyMatch(distance, length);
        };
      };

      // Sync locals back to the accumulator (covers all exit paths).
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

};
