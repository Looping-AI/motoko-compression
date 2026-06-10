/// Deflate public API.
///
/// Re-exports the Encoder and Decoder types and provides convenience
/// constructors (`buildEncoder`, `buildDecoder`) that wire up the
/// internal BitBuffer automatically.

import BitBufferMod "../internal/BitBuffer";
import Common "../LZSS/Common";
import DeflateEncoder "Encoder";
import DeflateDecoder "Decoder";

module {

  /// Stateful Deflate encoder. Create with `buildEncoder`, feed data with `encode`, finalise with `finish`.
  public type Encoder = DeflateEncoder.Encoder;
  /// Stateful Deflate decoder. Decode compressed data with `decodeStreamingWithCapacity` or `decodeBounded`.
  public type Decoder = DeflateDecoder.Decoder;
  /// Configuration for the Deflate encoder (block size, Huffman mode, LZSS level).
  public type DeflateOptions = DeflateEncoder.DeflateOptions;
  /// LZSS compression level: `#fast`, `#balance`, or `#best`.
  public type CompressionLevel = Common.CompressionLevel;

  /// Create a fresh Deflate encoder backed by a new BitBuffer.
  public func buildEncoder(options : DeflateOptions) : DeflateEncoder.Encoder {
    DeflateEncoder.Encoder(BitBufferMod.new(), options);
  };

  /// Create a Deflate decoder for the given compressed bytes.
  public func buildDecoder(inputBytes : [Nat8]) : DeflateDecoder.Decoder {
    DeflateDecoder.fromBytes(inputBytes);
  };

};
