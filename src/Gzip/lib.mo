/// Gzip module — recommended API entry point.
///
/// Import this module to access all Gzip types, classes, and helpers:
///
///   import Gzip "mo:compression/Gzip";
///
/// ─────────────────────────────────────────────────────────────────────────
/// FLOW 1 — One-shot helpers  (caller owns the encoder)
/// ─────────────────────────────────────────────────────────────────────────
///
///   // Keep as `transient let` in your canister for efficient reuse.
///   let enc = Gzip.EncoderBuilder().build();
///
///   let compressed : [Nat8] = Gzip.compress(enc, input);
///   let result = Gzip.decompress(compressed);   // Result<[Nat8], Text>
///
/// ─────────────────────────────────────────────────────────────────────────
/// FLOW 2 — Multi-step encoding  (any size, single or multi-call)
/// ─────────────────────────────────────────────────────────────────────────
///
///   let enc = Gzip.EncoderBuilder().build();
///   enc.encode(slice1);
///   enc.encode(slice2);
///   enc.finish();
///   let compressed = enc.compressed(); // [Nat8]
///   enc.clear();
///
///   // Decode — feed compressed bytes to the decoder.
///   let dec = Gzip.Decoder();
///   ignore dec.decode(compressed);
///   switch (dec.finish()) {
///     case (#ok(_))    { let output = dec.decompressed() };
///     case (#err(msg)) Runtime.trap(msg);
///   };
///
/// ─────────────────────────────────────────────────────────────────────────
/// FLOW 3 — ICP streaming  (spread work across canister self-calls)
/// ─────────────────────────────────────────────────────────────────────────
///
/// Use when data exceeds the ~40B-instruction per-call budget.
/// Each self-call processes enc.outputChunkSize() bytes of input (default 6 MiB).
/// The encoder accumulates output internally across calls; call finish() once
/// all input has been fed.
///
///   // ── Encoding side (one canister message per input slice) ─────────────
///   let enc = Gzip.EncoderBuilder().build();
///
///   // Each self-call: feed exactly outputChunkSize() bytes of raw input.
///   enc.encode(nextSlice(enc.outputChunkSize()));
///
///   // Final self-call once all input is consumed:
///   enc.finish();
///   let compressed = enc.compressed(); // [Nat8]
///   enc.clear();
///
///   // ── Decoding side (one canister message per step) ─────────────────────
///   let dec = Gzip.Decoder();
///   ignore dec.decode(compressed);
///
///   switch (dec.start()) {
///     case (#err(msg)) Runtime.trap(msg);
///     case (#ok(_))    {};
///   };
///
///   // Each self-call: budget maxOutBytes of decompressed output per step.
///   switch (dec.step(6_000_000)) {
///     case (#ok(#more))           selfCallAgain();
///     case (#ok(#done(summary)))  { let output = dec.decompressed(); finalize(summary) };
///     case (#err(msg))            Runtime.trap(msg);
///   };

import Blob "mo:core/Blob";
import Result "mo:core/Result";
import Text "mo:core/Text";

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

  /// Fluent builder for `Gzip.Encoder` (see `EncoderBuilder().build()`).
  public type EncoderBuilder = EncoderFile.EncoderBuilder;
  public let EncoderBuilder = EncoderFile.EncoderBuilder;

  /// Stateful Gzip encoder produced by `EncoderBuilder().build()`.
  public type Encoder = EncoderFile.Encoder;

  // ── Decoder ──────────────────────────────────────────────────────────────

  /// Summary returned by `Decoder.finish()` / `Decoder.step()` on success.
  public type StreamedSummary = DecoderFile.StreamedSummary;

  /// Construct a stateful Gzip decoder.
  /// Feed compressed bytes with `decode()`, then drive decompression with
  /// `finish()` (one-shot) or `start()` + `step()` (incremental).
  /// Output accumulates internally; read it via `decompressed()` or `chunks()`.
  public let Decoder = DecoderFile.Decoder;

  /// Type of the stateful Gzip decoder (constructed via `Decoder()`).
  public type Decoder = DecoderFile.Decoder;

  // ── Convenience helpers ──────────────────────────────────────────────────

  /// Compress `bytes` in one call, returning the raw Gzip bytes.
  /// Pass a reusable encoder (e.g. a `transient let` in your canister) to avoid
  /// re-allocating internal structures on every call.
  /// For large data use `enc.encode()` + `enc.finish()` + `enc.compressed()` directly across self-calls.
  public func compress(enc : Encoder, bytes : [Nat8]) : [Nat8] {
    enc.encode(bytes);
    enc.finish();
    let out = enc.compressed();
    enc.clear();
    out;
  };

  /// Compress UTF-8 text in one call.
  public func compressText(enc : Encoder, t : Text) : [Nat8] {
    enc.encode(Blob.toArray(Text.encodeUtf8(t)));
    enc.finish();
    let out = enc.compressed();
    enc.clear();
    out;
  };

  /// Compress a Blob in one call.
  public func compressBlob(enc : Encoder, b : Blob) : [Nat8] {
    enc.encode(Blob.toArray(b));
    enc.finish();
    let out = enc.compressed();
    enc.clear();
    out;
  };

  /// Decompress `bytes` in one call, returning all output as a single array.
  /// For large data use `Decoder` + `finish()` or the `start`/`step` API.
  public func decompress(bytes : [Nat8]) : Result.Result<[Nat8], Text> {
    let dec = DecoderFile.Decoder();
    ignore dec.decode(bytes);
    switch (dec.finish()) {
      case (#err(msg)) return #err(msg);
      case (#ok(_)) {};
    };
    #ok(dec.decompressed());
  };

};
