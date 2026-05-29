/// Deflate block implementations: compressed blocks (fixed and dynamic Huffman).
///
/// Symbols are stored in two flat pre-allocated [var Nat] arrays rather than a
/// linked List<Symbol>, eliminating one heap allocation per symbol in the hot
/// path.  Discriminant: sym_v2[i] == 0 → literal (sym_v1 = byte value);
/// sym_v2[i] >= 3 → pointer (sym_v1 = backward_offset, sym_v2 = length).
/// LZSS guarantees length >= 3 for all pointers, so 0 is a safe sentinel.

import Nat8 "mo:core/Nat8";
import Prim "mo:⛔";
import Runtime "mo:core/Runtime";
import BitBuffer "../internal/BitBuffer";
import LzssCommon "../LZSS/Common";
import LzssEncoder "../LZSS/Encoder/lib";
import CodeTables "CodeTables";
import HuffmanCodec "HuffmanCodec";

module {

  type BitBuffer = BitBuffer.BitBuffer;

  // ── Block type ─────────────────────────────────────────────────────────────

  public type BlockType = {
    #Fixed : { lzss : LzssEncoder.Encoder; block_limit : Nat };
    #Dynamic : { lzss : LzssEncoder.Encoder; block_limit : Nat };
  };

  /// BTYPE value for each block kind (RFC 1951 §3.2.3).
  public func blockToNat(bt : BlockType) : Nat {
    switch bt {
      case (#Fixed(_)) 1;
      case (#Dynamic(_)) 2;
    };
  };

  // ── Block interface ────────────────────────────────────────────────────────

  public type BlockInterface = {
    size : () -> Nat;
    add : (Nat8) -> ();
    /// Emit the block payload. `is_final` indicates whether this is the
    /// last block of the stream — only then is the underlying LZSS
    /// encoder allowed to drain its lookahead buffer. Calling LZSS flush
    /// between non-final blocks would corrupt cross-block matches.
    flush : (BitBuffer, Bool) -> ();
    clear : () -> ();
  };

  /// Construct a block of the given type.
  public func block(bt : BlockType) : BlockInterface {
    switch bt {
      case (#Fixed({ lzss; block_limit })) {
        Compress(lzss, HuffmanCodec.FixedHuffmanCodec(), block_limit);
      };
      case (#Dynamic({ lzss; block_limit })) {
        Compress(lzss, HuffmanCodec.DynamicHuffmanCodec(), block_limit);
      };
    };
  };

  // ── Compressed block ───────────────────────────────────────────────────────

  public class Compress(
    lzss : LzssEncoder.Encoder,
    huffman : HuffmanCodec.HuffmanCodec,
    block_limit : Nat,
  ) {
    var input_size : Nat = 0;

    // Flat symbol storage — no per-symbol heap allocation.
    // sym_v2[i] == 0  → literal:  sym_v1[i] = byte value (0..255)
    // sym_v2[i] >= 3  → pointer:  sym_v1[i] = backward_offset, sym_v2[i] = length
    // LZSS minimum match length is 3, so 0 is always a safe literal sentinel.
    //
    // The final flush drains the LZSS lookahead (≤ MATCH_MAX_SIZE = 258 bytes
    // that accumulated across non-final blocks), so add that headroom.
    let sym_cap : Nat = block_limit + LzssCommon.MATCH_MAX_SIZE;
    let sym_v1 : [var Nat] = Prim.Array_init<Nat>(sym_cap, 0);
    let sym_v2 : [var Nat] = Prim.Array_init<Nat>(sym_cap, 0);
    var sym_count : Nat = 0;

    // Frequency tables accumulated incrementally so buildFromFreqs skips a
    // second pass over the symbol list.
    let lit_freqs : [var Nat] = Prim.Array_init<Nat>(286, 0);
    let dist_freqs : [var Nat] = Prim.Array_init<Nat>(30, 0);

    // Precomputed RFC 1951 length/distance code tables (built once).
    let tables = CodeTables.CodeTables();

    // Direct callbacks — no LzssEntry variant alloc per symbol.
    let sink : LzssCommon.MatchSink = {
      onLiteral = func(b : Nat8) {
        let bnat = Nat8.toNat(b);
        sym_v1[sym_count] := bnat;
        sym_v2[sym_count] := 0; // literal sentinel
        sym_count += 1;
        lit_freqs[bnat] += 1;
      };
      onPointer = func(offset : Nat, len : Nat) {
        sym_v1[sym_count] := offset;
        sym_v2[sym_count] := len; // len >= 3, never 0
        sym_count += 1;
        lit_freqs[tables.lengthCode[len - 3]] += 1;
        dist_freqs[tables.distCodeOf(offset)] += 1;
      };
    };

    public func size() : Nat { input_size };

    public func add(byte : Nat8) {
      input_size += 1;
      lzss.encodeByte(byte, sink);
    };

    public func flush(bitbuffer : BitBuffer, is_final : Bool) {
      if (is_final) lzss.flush(sink);

      let symbol_encoder = switch (huffman.buildFromFreqs(lit_freqs, dist_freqs)) {
        case (#ok(e)) e;
        case (#err(msg)) Runtime.trap("Deflate.Compress.flush: build failed: " # msg);
      };

      switch (huffman.save(bitbuffer, symbol_encoder)) {
        case (#ok(_)) {};
        case (#err(msg)) Runtime.trap("Deflate.Compress.flush: save failed: " # msg);
      };

      // Encode symbols directly from flat arrays — no Symbol variant construction.
      // Hoist the precomputed Huffman code tables out of the inner loop so
      // emission is a pair of indexed reads + a fused `addBits2` per pointer.
      let lit_bw = symbol_encoder.literal.bitwidths;
      let lit_bv = symbol_encoder.literal.bits;
      let dist_bw = symbol_encoder.distance.bitwidths;
      let dist_bv = symbol_encoder.distance.bits;

      var i = 0;
      while (i < sym_count) {
        let len = sym_v2[i];
        if (len == 0) {
          // Literal — inline of symbol_encoder.literal.encode.
          let s = sym_v1[i];
          bitbuffer.addBits(lit_bw[s], lit_bv[s]);
        } else {
          // Pointer: sym_v1[i] = backward_offset, sym_v2[i] = length
          let dist = sym_v1[i];
          // ── Length code (table lookup, index = len - 3) ─────────────────
          let lIdx : Nat = len - 3;
          let lCode = tables.lengthCode[lIdx];
          // Fused literal-code + length-extra emit.
          bitbuffer.addBits2(lit_bw[lCode], lit_bv[lCode], tables.lengthExtraBits[lIdx], tables.lengthExtraVal[lIdx]);

          // ── Distance code (table lookup) ────────────────────────────────
          let dCode = tables.distCodeOf(dist);
          // Fused distance-code + distance-extra emit.
          bitbuffer.addBits2(dist_bw[dCode], dist_bv[dCode], tables.distExtraBits[dCode], dist - tables.distBase[dCode]);
        };
        i += 1;
      };
      // End-of-block marker (code 256) — inline.
      bitbuffer.addBits(lit_bw[256], lit_bv[256]);

      // Reset state for next block
      input_size := 0;
      sym_count := 0;
      var k = 0;
      while (k < 286) { lit_freqs[k] := 0; k += 1 };
      k := 0;
      while (k < 30) { dist_freqs[k] := 0; k += 1 };
    };

    public func clear() {
      lzss.clear();
      sym_count := 0;
      input_size := 0;
      var k = 0;
      while (k < 286) { lit_freqs[k] := 0; k += 1 };
      k := 0;
      while (k < 30) { dist_freqs[k] := 0; k += 1 };
    };
  };

};
