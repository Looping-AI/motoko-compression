/// Deflate encoder.
///
/// Wraps a BitBuffer and a block implementation. Calling `finish` flushes
/// the final (BFINAL=1) block and returns the filled BitBuffer.

import BitBuffer "../internal/BitBuffer";
import Block "Block";
import LzssEncoder "../LZSS/Encoder/lib";
import Common "../LZSS/Common";

module {

  type BitBuffer = BitBuffer.BitBuffer;

  // ── Options ────────────────────────────────────────────────────────────

  public type DeflateOptions = {
    /// Maximum number of uncompressed bytes per Deflate block.
    /// Controls compression ratio (Huffman table overhead) and per-block
    /// working memory. Does NOT affect LZSS back-reference reach (the
    /// 32 KiB sliding window persists across blocks). Recommended: 32 KiB.
    deflate_block_size : Nat;
    /// Huffman table selection. `null` (the default) auto-selects fixed or
    /// dynamic per block by comparing their exact bit cost and picking the
    /// smaller. `?#fixed` / `?#dynamic` force a specific kind for every block.
    force_huffman_kind : ?Block.HuffmanKind;
    /// LZSS compression level.
    lzss : Common.CompressionLevel;
  };

  // ── Encoder class ──────────────────────────────────────────────────────

  public class Encoder(bitbuffer : BitBuffer, options : DeflateOptions) {

    let block = Block.block(
      LzssEncoder.Encoder(options.lzss),
      options.force_huffman_kind,
      options.deflate_block_size,
    );

    /// Optional callback: called with the bitbuffer's byte size after each
    /// block is flushed. Used by the Gzip encoder to track block boundaries.
    var on_block_flushed : ?(Nat -> ()) = null;

    public func setOnBlockFlushed(cb : (Nat) -> ()) {
      on_block_flushed := ?cb;
    };

    /// Encode a single byte, flushing a non-final block if needed.
    public func encodeByte(byte : Nat8) {
      if (block.size() >= options.deflate_block_size) flush(false);
      block.add(byte);
    };

    /// Encode a slice of bytes.
    public func encode(data : [Nat8]) {
      for (byte in data.vals()) {
        if (block.size() >= options.deflate_block_size) flush(false);
        block.add(byte);
      };
    };

    /// Flush the current block.
    public func flush(is_final : Bool) {
      // BFINAL + BTYPE are written by the block itself (it chooses its own
      // Huffman kind), so the header always precedes the block content.
      block.flush(bitbuffer, is_final);
      switch (on_block_flushed) {
        case (?cb) cb(bitbuffer.byteSize());
        case null {};
      };
    };

    /// Reset the encoder state (does not touch the underlying BitBuffer).
    public func clear() {
      block.clear();
    };

    /// Flush the final block, byte-align the buffer, and return it.
    public func finish() : BitBuffer {
      flush(true);
      bitbuffer.byteAlign();
      clear();
      return bitbuffer;
    };
  };

};
