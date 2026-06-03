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

  public type Encoder = DeflateEncoder.Encoder;
  public let Encoder = DeflateEncoder.Encoder;
  public type Decoder = DeflateDecoder.Decoder;
  /// Construct a Deflate decoder from an immutable compressed-byte array.
  public func Decoder(inputBytes : [Nat8]) : DeflateDecoder.Decoder {
    DeflateDecoder.fromBytes(inputBytes);
  };
  public type DeflateOptions = DeflateEncoder.DeflateOptions;
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
