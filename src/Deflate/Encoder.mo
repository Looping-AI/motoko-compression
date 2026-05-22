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
    /// Maximum number of uncompressed bytes per block.
    block_size : Nat;
    /// Use dynamic Huffman tables (true) or fixed tables (false).
    dynamic_huffman : Bool;
    /// LZSS compression level.
    lzss : Common.CompressionLevel;
  };

  // ── Encoder class ──────────────────────────────────────────────────────

  public class Encoder(bitbuffer : BitBuffer, options : DeflateOptions) {

    let block_type = if (options.dynamic_huffman) {
      #Dynamic({
        lzss = LzssEncoder.Encoder(options.lzss);
        block_limit = options.block_size;
      });
    } else {
      #Fixed({
        lzss = LzssEncoder.Encoder(options.lzss);
        block_limit = options.block_size;
      });
    };

    let block = Block.block(block_type);

    /// Optional callback: called with the bitbuffer's byte size after each
    /// block is flushed. Used by the Gzip encoder to track block boundaries.
    var on_block_flushed : ?(Nat -> ()) = null;

    public func setOnBlockFlushed(cb : (Nat) -> ()) {
      on_block_flushed := ?cb;
    };

    /// Encode a single byte, flushing a non-final block if needed.
    public func encodeByte(byte : Nat8) {
      if (block.size() >= options.block_size) flush(false);
      block.add(byte);
    };

    /// Encode a slice of bytes.
    public func encode(data : [Nat8]) {
      for (byte in data.vals()) {
        if (block.size() >= options.block_size) flush(false);
        block.add(byte);
      };
    };

    /// Flush the current block.
    public func flush(is_final : Bool) {
      bitbuffer.addBit(is_final); // BFINAL
      bitbuffer.addBits(2, Block.blockToNat(block_type)); // BTYPE
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
