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
import Symbol "Symbol";
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

    let sink : LzssEncoder.Sink = {
      add = func(entry : LzssCommon.LzssEntry) {
        switch entry {
          case (#literal(b)) {
            let bnat = Nat8.toNat(b);
            sym_v1[sym_count] := bnat;
            sym_v2[sym_count] := 0; // literal sentinel
            sym_count += 1;
            lit_freqs[bnat] += 1;
          };
          case (#pointer(offset, len)) {
            sym_v1[sym_count] := offset;
            sym_v2[sym_count] := len; // len >= 3, never 0
            sym_count += 1;
            lit_freqs[Symbol.lenCode(len)] += 1;
            dist_freqs[Symbol.distCode(offset)] += 1;
          };
        };
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
      var i = 0;
      while (i < sym_count) {
        let len = sym_v2[i];
        if (len == 0) {
          // Literal
          symbol_encoder.literal.encode(bitbuffer, sym_v1[i]);
        } else {
          // Pointer: sym_v1[i] = backward_offset, sym_v2[i] = length
          let dist = sym_v1[i];
          // ── Length code (RFC 1951, inlined — no variant alloc) ──────────
          var lCode : Nat = 0;
          var lBits : Nat = 0;
          var lVal : Nat = 0;
          if (len <= 10) {
            lCode := 257 + (len - 3);
          } else if (len <= 18) {
            lCode := 265 + (len - 11) / 2;
            lBits := 1;
            lVal := (len - 11) % 2;
          } else if (len <= 34) {
            lCode := 269 + (len - 19) / 4;
            lBits := 2;
            lVal := (len - 19) % 4;
          } else if (len <= 66) {
            lCode := 273 + (len - 35) / 8;
            lBits := 3;
            lVal := (len - 35) % 8;
          } else if (len <= 130) {
            lCode := 277 + (len - 67) / 16;
            lBits := 4;
            lVal := (len - 67) % 16;
          } else if (len < 258) {
            lCode := 281 + (len - 131) / 32;
            lBits := 5;
            lVal := (len - 131) % 32;
          } else {
            lCode := 285;
          };
          symbol_encoder.literal.encode(bitbuffer, lCode);
          if (lBits > 0) { bitbuffer.addBits(lBits, lVal) };
          // ── Distance code (RFC 1951, inlined — no variant alloc) ────────
          if (dist <= 4) {
            symbol_encoder.distance.encode(bitbuffer, dist - 1);
          } else {
            var dBits = 1;
            var dBase = 4;
            while (dBase * 2 < dist) { dBits += 1; dBase *= 2 };
            let dHalf = dBase / 2;
            symbol_encoder.distance.encode(bitbuffer, 2 * dBits + 2 + (if (dist < dBase + dHalf + 1) 0 else 1));
            if (dBits > 0) {
              bitbuffer.addBits(dBits, (dist - dBase - 1) % dHalf);
            };
          };
        };
        i += 1;
      };
      // End-of-block marker (code 256)
      symbol_encoder.literal.encode(bitbuffer, 256);

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
