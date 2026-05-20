/// Deflate public API.
///
/// Re-exports the Encoder and Decoder types and provides convenience
/// constructors (`buildEncoder`, `buildDecoder`) that wire up the
/// internal BitBuffer / BitReader automatically.

import List "mo:core/List";
import BitBufferMod "../internal/BitBuffer";
import BitReader "../internal/BitReader";
import Common "../LZSS/Common";
import DeflateEncoder "Encoder";
import DeflateDecoder "Decoder";

module {

  public type Encoder = DeflateEncoder.Encoder;
  public let Encoder = DeflateEncoder.Encoder;
  public type Decoder = DeflateDecoder.Decoder;
  public let Decoder = DeflateDecoder.Decoder;
  public type DeflateOptions = DeflateEncoder.DeflateOptions;
  public type CompressionLevel = Common.CompressionLevel;

  /// Create a fresh Deflate encoder backed by a new BitBuffer.
  public func buildEncoder(options : DeflateOptions) : DeflateEncoder.Encoder {
    DeflateEncoder.Encoder(BitBufferMod.new(), options);
  };

  /// Create a fresh Deflate decoder with an internal output buffer.
  /// Call `decoder.finish()` and read results with `decoder.toArray()`.
  public func buildDecoder(buffer : ?List.List<Nat8>) : DeflateDecoder.Decoder {
    DeflateDecoder.Decoder(BitReader.BitReader(), buffer);
  };

};
