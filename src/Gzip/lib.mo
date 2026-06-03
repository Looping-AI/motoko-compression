/// Gzip module — public API.
///
/// Consumers import this module to access all Gzip types and classes:
///
///   import Gzip "mo:compression/Gzip";
///
///   let enc = Gzip.EncoderBuilder().lzss(#best).build();
///   enc.encodeText("Hello, world!");
///   let resp = enc.finish();          // EncodedResponse (#single or #chunked)
///
///   let dec = Gzip.Decoder();
///   let data = switch (resp) { case (#single d) d; case (#chunked { chunks }) chunks[0] };
///   ignore dec.decode(data);
///   let collected = List.empty<Nat8>();
///   let result = dec.finishStreaming(func(c) { List.addAll(collected, c.vals()) });

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

  /// Summary returned by `Encoder.finishStreaming()`.
  public type EncodedSummary = Encoder_.EncodedSummary;

  /// Fluent builder for Gzip.Encoder.
  public type EncoderBuilder = Encoder_.EncoderBuilder;
  public let EncoderBuilder = Encoder_.EncoderBuilder;

  // ── Decoder ──────────────────────────────────────────────────────────────

  /// Summary returned by `Decoder.finishStreaming()`.
  public type StreamedSummary = Decoder_.StreamedSummary;

  /// Gzip decoder.  Feed chunks with `decode()`, retrieve result with `finish()`.
  public let Decoder = Decoder_.Decoder;

};
