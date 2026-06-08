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

import HeaderFile "Header";
import EncoderFile "Encoder";
import DecoderFile "Decoder";

module {

  // ── Header ───────────────────────────────────────────────────────────────

  public type ExtraField = HeaderFile.ExtraField;
  public type Os = HeaderFile.Os;
  public type Header = HeaderFile.Header;

  public let defaultHeader = HeaderFile.defaultHeader;
  public let osToByte = HeaderFile.osToByte;
  public let byteToOs = HeaderFile.byteToOs;

  // ── Encoder ──────────────────────────────────────────────────────────────

  public type EncodedResponse = EncoderFile.EncodedResponse;

  /// Summary returned by `Encoder.finishStreaming()`.
  public type EncodedSummary = EncoderFile.EncodedSummary;

  /// Fluent builder for Gzip.Encoder.
  public type EncoderBuilder = EncoderFile.EncoderBuilder;
  public let EncoderBuilder = EncoderFile.EncoderBuilder;

  /// Stateful Gzip encoder (built via `EncoderBuilder().build()`).
  public type Encoder = EncoderFile.Encoder;

  // ── Decoder ──────────────────────────────────────────────────────────────

  /// Summary returned by `Decoder.finishStreaming()` / `Decoder.step()`.
  public type StreamedSummary = DecoderFile.StreamedSummary;

  /// Gzip decoder. Feed chunks with `decode()`, then either drive the whole
  /// stream with `finishStreaming()`, or decode incrementally across messages
  /// with `start()` + repeated `step(maxOutBytes, consume)`.
  public let Decoder = DecoderFile.Decoder;

  /// Stateful Gzip decoder type (constructed via `Decoder()`).
  public type Decoder = DecoderFile.Decoder;

};
