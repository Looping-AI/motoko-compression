/// Deflate block implementations: compressed blocks (fixed and dynamic Huffman).
///
/// Symbols are stored in two flat pre-allocated [var Nat] arrays rather than a
/// linked List<Symbol>, eliminating one heap allocation per symbol in the hot
/// path.  Discriminant: symV2[i] == 0 → literal (symV1 = byte value);
/// symV2[i] >= 3 → pointer (symV1 = backward_offset, symV2 = length).
/// LZSS guarantees length >= 3 for all pointers, so 0 is a safe sentinel.

import Nat8 "mo:core/Nat8";
import Prim "mo:⛔";
import Runtime "mo:core/Runtime";
import BitBuffer "../internal/BitBuffer";
import LzssCommon "../LZSS/Common";
import LzssEncoder "../LZSS/Encoder/lib";
import CodeTables "CodeTables";
import HuffmanCodec "HuffmanCodec";
import Symbol "Symbol";

module {

  type BitBuffer = BitBuffer.BitBuffer;

  // ── Huffman selection ───────────────────────────────────────────────────────

  /// Per-block Huffman table choice. `null` (auto) compares fixed vs dynamic
  /// cost for each block and picks the smaller; an explicit value forces it.
  public type HuffmanKind = { #fixed; #dynamic };

  // ── Block interface ────────────────────────────────────────────────────────

  public type BlockInterface = {
    size : () -> Nat;
    /// Raw bytes emitted as symbols so far in this block (literals × 1 + pointers × len).
    /// Does NOT include bytes still in the LZSS lookahead; those appear only after the
    /// final flush. Use this to compute how many raw bytes have been committed to output.
    symBytes : () -> Nat;
    add : (Nat8) -> ();
    /// Bulk-feed the slice `data[off ..< off + len]`. Equivalent to calling
    /// `add` on each byte in turn, but routes through the LZSS bulk path.
    addBytes : ([Nat8], Nat, Nat) -> ();
    /// Emit the block payload, including its own BFINAL + BTYPE header.
    /// `is_final` indicates whether this is the last block of the stream —
    /// only then is the underlying LZSS encoder allowed to drain its
    /// lookahead buffer. Calling LZSS flush between non-final blocks would
    /// corrupt cross-block matches.
    flush : (BitBuffer, Bool) -> ();
    clear : () -> ();
  };

  /// Construct a block. `force = null` enables per-block fixed/dynamic auto-select.
  public func block(bitbuffer : BitBuffer, lzss : LzssEncoder.Encoder, force : ?HuffmanKind, block_limit : Nat) : BlockInterface {
    Compress(bitbuffer, lzss, force, block_limit);
  };

  // ── Compressed block ───────────────────────────────────────────────────────

  public class Compress(
    bb : BitBuffer,
    lzss : LzssEncoder.Encoder,
    force : ?HuffmanKind,
    block_limit : Nat,
  ) {
    // Direct-emit fixed path: when the Huffman kind is forced to #fixed, emit
    // DEFLATE bits straight to the bit-buffer as LZSS produces symbols — no
    // symbol buffer, no frequency counting, no second pass. #dynamic and auto
    // still need frequencies first, so they keep the buffered two-pass path.
    let direct : Bool = switch (force) { case (?#fixed) true; case _ false };

    var inputSize : Nat = 0;
    // Bytes represented by symbols emitted so far (literals=1 each, pointers=len each).
    // Excludes bytes still in the LZSS lookahead that haven't been decided yet.
    var symBytesCount : Nat = 0;

    // Flat symbol storage — no per-symbol heap allocation.
    // symV2[i] == 0  → literal:  symV1[i] = byte value (0..255)
    // symV2[i] >= 3  → pointer:  symV1[i] = backward_offset, symV2[i] = length
    // LZSS minimum match length is 3, so 0 is always a safe literal sentinel.
    //
    // The final flush drains the LZSS lookahead (≤ MATCH_MAX_SIZE = 258 bytes
    // that accumulated across non-final blocks), so add that headroom.
    // The direct fixed path never buffers symbols, so allocate nothing for it.
    let symCap : Nat = if (direct) 0 else block_limit + LzssCommon.MATCH_MAX_SIZE;
    let symV1 : [var Nat] = Prim.Array_init<Nat>(symCap, 0);
    let symV2 : [var Nat] = Prim.Array_init<Nat>(symCap, 0);
    var symCount : Nat = 0;

    // Frequency tables accumulated incrementally so buildFromFreqs skips a
    // second pass over the symbol list.
    let litFreqs : [var Nat] = Prim.Array_init<Nat>(286, 0);
    let distFreqs : [var Nat] = Prim.Array_init<Nat>(30, 0);

    // Precomputed RFC 1951 length/distance code tables (built once).
    let tables = CodeTables.CodeTables();

    // Dynamic codec (used for #dynamic and auto). The fixed encoder is
    // frequency-independent, so build it once and reuse across all blocks.
    let dyn = HuffmanCodec.DynamicHuffmanCodec();
    let fixedEnc : Symbol.Encoder = switch (HuffmanCodec.FixedHuffmanCodec().buildFromFreqs(litFreqs, distFreqs)) {
      case (#ok(e)) e;
      case (#err(msg)) Runtime.trap("Deflate.Compress: fixed build failed: " # msg);
    };

    // Fixed-code bitwidth/bits tables hoisted for the direct-emit hot path.
    let fixedLitBw = fixedEnc.literal.bitwidths;
    let fixedLitBv = fixedEnc.literal.bits;
    let fixedDistBw = fixedEnc.distance.bitwidths;
    let fixedDistBv = fixedEnc.distance.bits;

    // ── Direct-emit (fixed) block header state ──────────────────────────────
    // The fixed block header (BFINAL + BTYPE=01) is written lazily at the first
    // symbol of each block. BFINAL is unknown then (finality is only known at
    // flush), so it is written as 0 and patched to 1 on the final block via
    // `bb.setBitTrue(bfinalPos)`.
    var headerWritten : Bool = false;
    var bfinalPos : Nat = 0;

    func writeFixedHeader(is_final : Bool) {
      bfinalPos := bb.writeBitPos();
      bb.addBits(1, if (is_final) 1 else 0); // BFINAL
      bb.addBits(2, 1); // BTYPE = 01 (fixed)
      headerWritten := true;
    };

    // Direct callbacks — no LzssEntry variant alloc per symbol.
    let bufferedSink : LzssCommon.MatchSink = {
      onLiteral = func(b : Nat8) {
        let bnat = Nat8.toNat(b);
        symV1[symCount] := bnat;
        symV2[symCount] := 0; // literal sentinel
        symCount += 1;
        symBytesCount += 1;
        litFreqs[bnat] += 1;
      };
      onPointer = func(offset : Nat, len : Nat) {
        symV1[symCount] := offset;
        symV2[symCount] := len; // len >= 3, never 0
        symCount += 1;
        symBytesCount += len;
        litFreqs[tables.lengthCode[len - 3]] += 1;
        distFreqs[tables.distCodeOf(offset)] += 1;
      };
    };

    // Fixed direct-emit callbacks — write DEFLATE bits straight to `bb`.
    let directSink : LzssCommon.MatchSink = {
      onLiteral = func(b : Nat8) {
        if (not headerWritten) writeFixedHeader(false);
        let s = Nat8.toNat(b);
        bb.addBits(fixedLitBw[s], fixedLitBv[s]);
        symBytesCount += 1;
      };
      onPointer = func(offset : Nat, len : Nat) {
        if (not headerWritten) writeFixedHeader(false);
        let lIdx : Nat = len - 3;
        let lCode = tables.lengthCode[lIdx];
        let dCode = tables.distCodeOf(offset);
        bb.addBits4(
          fixedLitBw[lCode],
          fixedLitBv[lCode],
          tables.lengthExtraBits[lIdx],
          tables.lengthExtraVal[lIdx],
          fixedDistBw[dCode],
          fixedDistBv[dCode],
          tables.distExtraBits[dCode],
          offset - tables.distBase[dCode],
        );
        symBytesCount += len;
      };
    };

    let sink : LzssCommon.MatchSink = if (direct) directSink else bufferedSink;

    public func size() : Nat { inputSize };
    public func symBytes() : Nat { symBytesCount };

    public func add(byte : Nat8) {
      inputSize += 1;
      lzss.encodeByte(byte, sink);
    };

    public func addBytes(data : [Nat8], off : Nat, len : Nat) {
      inputSize += len;
      lzss.encodeRange(data, off, len, sink);
    };

    /// Total payload bits for the buffered symbols under the given code
    /// bitwidths. Length/distance EXTRA bits are identical for fixed and
    /// dynamic codes, so they are omitted — they cancel in the comparison.
    func payloadBits(litBW : [var Nat], distBW : [var Nat]) : Nat {
      var bits : Nat = 0;
      var i = 0;
      while (i < 286) {
        if (litFreqs[i] > 0) bits += litFreqs[i] * litBW[i];
        i += 1;
      };
      i := 0;
      while (i < 30) {
        if (distFreqs[i] > 0) bits += distFreqs[i] * distBW[i];
        i += 1;
      };
      bits;
    };

    // Encode buffered symbols (then EndOfBlock) using `enc`. Reads the
    // precomputed length/distance code tables; emission is a fused `addBits4`
    // per pointer (all four fields in one accumulator merge).
    func emitSymbols(bitbuffer : BitBuffer, enc : Symbol.Encoder) {
      let litBw = enc.literal.bitwidths;
      let litBv = enc.literal.bits;
      let distBw = enc.distance.bitwidths;
      let distBv = enc.distance.bits;

      var i = 0;
      while (i < symCount) {
        let len = symV2[i];
        if (len == 0) {
          // Literal — inline of enc.literal.encode.
          let s = symV1[i];
          bitbuffer.addBits(litBw[s], litBv[s]);
        } else {
          // Pointer: symV1[i] = backward_offset, symV2[i] = length
          let dist = symV1[i];
          // ── Length + distance codes fused into one accumulator merge ────
          let lIdx : Nat = len - 3;
          let lCode = tables.lengthCode[lIdx];
          let dCode = tables.distCodeOf(dist);
          bitbuffer.addBits4(
            litBw[lCode],
            litBv[lCode],
            tables.lengthExtraBits[lIdx],
            tables.lengthExtraVal[lIdx],
            distBw[dCode],
            distBv[dCode],
            tables.distExtraBits[dCode],
            dist - tables.distBase[dCode],
          );
        };
        i += 1;
      };
      // End-of-block marker (code 256) — inline.
      bitbuffer.addBits(litBw[256], litBv[256]);
    };

    // Emit a fixed-Huffman block: BFINAL + BTYPE=01, no header.
    func emitFixed(bitbuffer : BitBuffer, is_final : Bool) {
      bitbuffer.addBits(1, if (is_final) 1 else 0); // BFINAL
      bitbuffer.addBits(2, 1); // BTYPE = 01 (fixed)
      emitSymbols(bitbuffer, fixedEnc);
    };

    public func flush(bitbuffer : BitBuffer, is_final : Bool) {
      if (direct) {
        // Fixed direct-emit: symbols were already written to `bb` as they
        // arrived; only the lazy header (for empty blocks), the BFINAL patch,
        // and the End-of-block marker remain.
        if (is_final) lzss.flush(sink);
        if (not headerWritten) {
          // Empty block — finality is known here, so write BFINAL directly.
          writeFixedHeader(is_final);
        } else if (is_final) {
          bb.setBitTrue(bfinalPos); // promote BFINAL 0 → 1 on the final block
        };
        bb.addBits(fixedLitBw[256], fixedLitBv[256]); // End-of-block (code 256)
        resetState();
        return;
      };

      if (is_final) lzss.flush(sink);

      switch (force) {
        case (?#fixed) emitFixed(bitbuffer, is_final);
        case (?#dynamic) {
          let enc = switch (dyn.buildFromFreqs(litFreqs, distFreqs)) {
            case (#ok(e)) e;
            case (#err(msg)) Runtime.trap("Deflate.Compress.flush: build failed: " # msg);
          };
          bitbuffer.addBits(1, if (is_final) 1 else 0); // BFINAL
          bitbuffer.addBits(2, 2); // BTYPE = 10 (dynamic)
          switch (dyn.prepareSave(enc)) {
            case (#ok(plan)) dyn.emit(bitbuffer, plan);
            case (#err(msg)) Runtime.trap("Deflate.Compress.flush: save failed: " # msg);
          };
          emitSymbols(bitbuffer, enc);
        };
        case null {
          // Auto: build dynamic, compare fixed vs dynamic cost, pick smaller.
          // On any dynamic build/prepare failure, fall back to fixed.
          let chosen = switch (dyn.buildFromFreqs(litFreqs, distFreqs)) {
            case (#ok(enc)) {
              switch (dyn.prepareSave(enc)) {
                case (#ok(plan)) {
                  let dynTotal = payloadBits(enc.literal.bitwidths, enc.distance.bitwidths) + dyn.headerBits(plan);
                  let fixedTotal = payloadBits(fixedEnc.literal.bitwidths, fixedEnc.distance.bitwidths);
                  if (fixedTotal <= dynTotal) { #fixed } else {
                    #dynamic(enc, plan);
                  };
                };
                case (#err(_)) #fixed;
              };
            };
            case (#err(_)) #fixed;
          };
          switch (chosen) {
            case (#fixed) emitFixed(bitbuffer, is_final);
            case (#dynamic(enc, plan)) {
              bitbuffer.addBits(1, if (is_final) 1 else 0); // BFINAL
              bitbuffer.addBits(2, 2); // BTYPE = 10 (dynamic)
              dyn.emit(bitbuffer, plan);
              emitSymbols(bitbuffer, enc);
            };
          };
        };
      };

      resetState();
    };

    func resetState() {
      inputSize := 0;
      symCount := 0;
      symBytesCount := 0;
      headerWritten := false;
      // The direct fixed path never accumulates frequencies, so skip zeroing.
      if (not direct) {
        var k = 0;
        while (k < 286) { litFreqs[k] := 0; k += 1 };
        k := 0;
        while (k < 30) { distFreqs[k] := 0; k += 1 };
      };
    };

    public func clear() {
      lzss.clear();
      resetState();
    };
  };

};
