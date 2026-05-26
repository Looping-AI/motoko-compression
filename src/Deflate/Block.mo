/// Deflate block implementations: compressed blocks (fixed and dynamic Huffman).
///
/// Migrated from edjcase/motoko_compression.
/// Buffer<Symbol> → mo:core/List.

import List "mo:core/List";
import Prim "mo:⛔";
import Runtime "mo:core/Runtime";
import BitBuffer "../internal/BitBuffer";
import LzssCommon "../LZSS/Common";
import LzssEncoder "../LZSS/Encoder/lib";
import Symbol "Symbol";
import HuffmanCodec "HuffmanCodec";

module {

  type BitBuffer = BitBuffer.BitBuffer;

  // ── Block type ─────────────────────────────────────────────────────────

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

  // ── Block interface ────────────────────────────────────────────────────

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

  // ── Compressed block ───────────────────────────────────────────────────

  public class Compress(
    lzss : LzssEncoder.Encoder,
    huffman : HuffmanCodec.HuffmanCodec,
    _ : Nat, // block_limit (unused here; enforced by Encoder)
  ) {
    var input_size : Nat = 0;
    let compressed = List.empty<Symbol.Symbol>();

    // Frequency tables accumulated incrementally in the sink so that
    // buildFromFreqs can skip a full second pass over `compressed`.
    let lit_freqs : [var Nat] = Prim.Array_init<Nat>(286, 0);
    let dist_freqs : [var Nat] = Prim.Array_init<Nat>(30, 0);

    let sink : LzssEncoder.Sink = {
      add = func(entry : LzssCommon.LzssEntry) {
        List.add(compressed, entry);
        lit_freqs[Symbol.lengthMarker(entry)] += 1;
        let dm = Symbol.distanceMarker(entry);
        if (dm != Symbol.NO_DISTANCE) dist_freqs[dm] += 1;
      };
    };

    public func size() : Nat { input_size };

    public func add(byte : Nat8) {
      input_size += 1;
      lzss.encodeByte(byte, sink);
    };

    public func flush(bitbuffer : BitBuffer, is_final : Bool) {
      // Drain the LZSS lookahead buffer ONLY on the final block. For
      // non-final blocks, pending bytes stay in the LZSS encoder so that
      // matches may span across block boundaries (legal per RFC 1951 — the
      // decoder maintains a single 32 KB sliding window across all blocks).
      if (is_final) lzss.flush(sink);

      // Build the Huffman codec using pre-accumulated frequencies (no second
      // pass over `compressed`). buildFromFreqs mutates lit_freqs/dist_freqs
      // to apply the EndOfBlock fixup; we reset them below.
      let symbol_encoder = switch (huffman.buildFromFreqs(lit_freqs, dist_freqs)) {
        case (#ok(e)) e;
        case (#err(msg)) Runtime.trap("Deflate.Compress.flush: build failed: " # msg);
      };

      // Write the codec header (no-op for fixed, code lengths for dynamic)
      switch (huffman.save(bitbuffer, symbol_encoder)) {
        case (#ok(_)) {};
        case (#err(msg)) Runtime.trap("Deflate.Compress.flush: save failed: " # msg);
      };

      // Encode each compressed symbol
      for (sym in List.values(compressed)) {
        symbol_encoder.encode(bitbuffer, sym);
      };
      // End-of-block marker
      symbol_encoder.encode(bitbuffer, #EndOfBlock);

      // Reset state for next block
      input_size := 0;
      List.clear(compressed);
      var k = 0;
      while (k < 286) { lit_freqs[k] := 0; k += 1 };
      k := 0;
      while (k < 30) { dist_freqs[k] := 0; k += 1 };
    };

    public func clear() {
      lzss.clear();
      List.clear(compressed);
      input_size := 0;
      var k = 0;
      while (k < 286) { lit_freqs[k] := 0; k += 1 };
      k := 0;
      while (k < 30) { dist_freqs[k] := 0; k += 1 };
    };
  };

};
