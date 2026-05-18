/// Deflate encoder.
///
/// Wraps a BitBuffer and a block implementation. Calling `finish` flushes
/// the final (BFINAL=1) block and returns the filled BitBuffer.

import Runtime     "mo:core/Runtime";
import BitBuffer    "../internal/BitBuffer";
import Block        "Block";
import LzssEncoder  "../LZSS/Encoder/lib";
import Common       "../LZSS/Common";

module {

  type BitBuffer = BitBuffer.BitBuffer;

  // ── Options ────────────────────────────────────────────────────────────

  public type DeflateOptions = {
    /// Maximum number of uncompressed bytes per block.
    block_size      : Nat;
    /// Use dynamic Huffman tables (true) or fixed tables (false).
    dynamic_huffman : Bool;
    /// LZSS compression level, or `null` for raw (non-compressed) blocks.
    lzss            : ?Common.CompressionLevel;
  };

  // ── Encoder class ──────────────────────────────────────────────────────

  public class Encoder(bitbuffer : BitBuffer, options : DeflateOptions) {

    let block_type = switch (options.lzss) {
      case null {
        if (options.block_size > Block.NO_COMPRESSION_MAX_BLOCK_SIZE) {
          Runtime.trap(
            "Deflate.Encoder: block_size " # debug_show options.block_size
            # " exceeds raw-block maximum "
            # debug_show Block.NO_COMPRESSION_MAX_BLOCK_SIZE
          );
        };
        #Raw;
      };
      case (?level) {
        if (options.dynamic_huffman) {
          #Dynamic({ lzss = LzssEncoder.Encoder(level); block_limit = options.block_size });
        } else {
          #Fixed({   lzss = LzssEncoder.Encoder(level); block_limit = options.block_size });
        };
      };
    };

    let block = Block.Block(block_type);

    /// Encode a single byte, flushing a non-final block if needed.
    public func encode_byte(byte : Nat8) {
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
      bitbuffer.addBit(is_final);                         // BFINAL
      bitbuffer.addBits(2, Block.blockToNat(block_type)); // BTYPE
      block.flush(bitbuffer, is_final);
    };

    /// Reset the encoder state (does not touch the underlying BitBuffer).
    public func clear() { block.clear() };

    /// Flush the final block, byte-align the buffer, and return it.
    public func finish() : BitBuffer {
      flush(true);
      bitbuffer.byteAlign();
      clear();
      bitbuffer;
    };
  };

}
