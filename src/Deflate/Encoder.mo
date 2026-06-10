/// Deflate encoder.
///
/// Wraps a BitBuffer and a block implementation. Calling `finish` flushes
/// the final (BFINAL=1) block and returns the filled BitBuffer.

import BitBuffer "../internal/BitBuffer";
import Block "Block";
import LzssEncoder "../LZSS/Encoder";
import Common "../LZSS/Common";

module {

  type BitBuffer = BitBuffer.BitBuffer;

  // ── Options ────────────────────────────────────────────────────────────

  /// Configuration for the Deflate encoder.
  public type DeflateOptions = {
    /// Maximum number of uncompressed bytes per Deflate block.
    /// Controls compression ratio (Huffman table overhead) and per-block
    /// working memory. Does NOT affect LZSS back-reference reach (the
    /// 32 KiB sliding window persists across blocks). Recommended: 32 KiB.
    deflate_block_size : Nat;
    /// Huffman table selection. `null` auto-selects fixed or dynamic per block
    /// by comparing their exact bit cost and picking the smaller.
    /// `?#fixed` / `?#dynamic` force a specific kind for every block.
    force_huffman_kind : ?Block.HuffmanKind;
    /// LZSS compression level.
    lzss : Common.CompressionLevel;
  };

  // ── Encoder class ──────────────────────────────────────────────────────

  /// Stateful Deflate encoder. Write compressed data into `bitbuffer` by calling
  /// `encode` for each input slice, then `finish` to flush the final block.
  public class Encoder(bitbuffer : BitBuffer, options : DeflateOptions) {

    let block = Block.block(
      bitbuffer,
      LzssEncoder.Encoder(options.lzss),
      options.force_huffman_kind,
      options.deflate_block_size,
    );

    /// Optional callback: called with the bitbuffer's byte size after each
    /// block is flushed. Used by the Gzip encoder to track block boundaries.
    var onBlockFlushed : ?(Nat -> ()) = null;

    // sym_bytes captured from the block just before each flush (block resets after flush).
    var prevFlushedSymBytes : Nat = 0;

    /// Register a callback invoked with the buffer's byte size after each block flush.
    public func setOnBlockFlushed(cb : (Nat) -> ()) {
      onBlockFlushed := ?cb;
    };

    /// Encode a single byte, flushing a non-final block if needed.
    public func encodeByte(byte : Nat8) {
      if (block.size() >= options.deflate_block_size) flush(false);
      block.add(byte);
    };

    /// Encode a slice of bytes.
    public func encode(data : [Nat8]) {
      let n = data.size();
      var off = 0;
      // Feed in bulk, splitting only at Deflate block boundaries. Each chunk
      // is bounded by the block's remaining capacity so input_size never
      // exceeds deflate_block_size (matching the per-byte flush trigger).
      while (off < n) {
        if (block.size() >= options.deflate_block_size) flush(false);
        let room : Nat = options.deflate_block_size - block.size();
        let avail : Nat = n - off;
        let take = if (room < avail) room else avail;
        block.addBytes(data, off, take);
        off += take;
      };
    };

    /// Flush the current block.
    public func flush(is_final : Bool) {
      // Capture sym_bytes before block.flush() calls resetState() and zeroes it.
      prevFlushedSymBytes := block.symBytes();
      // BFINAL + BTYPE are written by the block itself (it chooses its own
      // Huffman kind), so the header always precedes the block content.
      block.flush(bitbuffer, is_final);
      switch (onBlockFlushed) {
        case (?cb) cb(bitbuffer.byteSize());
        case null {};
      };
    };

    /// Raw bytes committed by the most recently flushed block.
    /// Reflects sym_bytes captured just before the flush (before resetState clears it).
    public func lastFlushedSymBytes() : Nat { prevFlushedSymBytes };

    /// Reset the encoder state (does not touch the underlying BitBuffer).
    public func clear() {
      block.clear();
    };

    /// Bytes accumulated in the current (not-yet-flushed) Deflate block.
    /// Must be called before `finish()` — finish() flushes and clears the block.
    public func currentBlockSize() : Nat { block.size() };

    /// Flush the final block and byte-align the buffer.
    public func finish() {
      flush(true);
      bitbuffer.byteAlign();
    };

    /// Get the number of bytes in the compressed output.
    public func byteSize() : Nat {
      bitbuffer.byteSize();
    };

    /// Get all compressed bytes.
    public func getCompressedBytes() : [Nat8] {
      bitbuffer.getBytes(0, bitbuffer.byteSize());
    };
  };

};
