/// Gzip module — public API.
///
/// Consumers import this module to access all Gzip types and classes:
///
///   import Gzip "mo:compression/Gzip";
///
///   let enc = Gzip.EncoderBuilder().lzss(#best).build();
///   enc.encodeText("Hello, world!");
///   let resp = enc.finish();          // EncodedResponse
///
///   let dec = Gzip.Decoder();
///   ignore dec.decode(resp.chunks[0]);
///   let result = dec.finish();        // Result<DecodedResponse, Text>

import Header_ "Header";
import Encoder_ "Encoder";
import Decoder_ "Decoder";

module {

  // ── Header ───────────────────────────────────────────────────────────────

  public type ExtraField = Header_.ExtraField;
  public type Os = Header_.Os;
  public type Header = Header_.Header;

  public let defaultHeader = Header_.defaultHeader;
  public let osToByte = Header_.osToByte;
  public let byteToOs = Header_.byteToOs;

  // ── Encoder ──────────────────────────────────────────────────────────────

  public type EncodedResponse = Encoder_.EncodedResponse;

  /// Fluent builder for Gzip.Encoder.
  public type EncoderBuilder = Encoder_.EncoderBuilder;
  public let EncoderBuilder = Encoder_.EncoderBuilder;

  // ── Decoder ──────────────────────────────────────────────────────────────

  public type DecodedResponse = Decoder_.DecodedResponse;

  /// Gzip decoder.  Feed chunks with `decode()`, retrieve result with `finish()`.
  public let Decoder = Decoder_.Decoder;

};
