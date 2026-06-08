/// Gzip module — recommended API entry point.
///
/// Import this module to access all Gzip types, classes, and helpers:
///
///   import Gzip "mo:compression/Gzip";
///
/// ─────────────────────────────────────────────────────────────────────────
/// FLOW 1 — One-shot helpers  (small data, single call)
/// ─────────────────────────────────────────────────────────────────────────
///
///   // Keep as `transient let` in your canister for efficient reuse.
///   let enc = Gzip.EncoderBuilder().build();
///
///   let compressed : [Nat8] = Gzip.compress(enc, input);
///   let dec = Gzip.Decoder();
///   let result = Gzip.decompress(dec, compressed);   // Result<[Nat8], Text>
///
/// ─────────────────────────────────────────────────────────────────────────
/// FLOW 2 — Multi-step encoding  (any size, single or multi-call)
/// ─────────────────────────────────────────────────────────────────────────
///
/// Use when data exceeds the ~40B-instruction per-call budget.
/// Each call inside a timer processes enc.outputChunkSize() bytes of input (default 6 MiB).
/// The encoder accumulates output internally across calls; call finish() once
/// all input has been fed.
///
///   // ── Encoding side (one timer run per input slice) ─────────────
///   let enc = Gzip.EncoderBuilder().build();
///
///   // Each timer run: feed exactly outputChunkSize() bytes of raw input.
///   enc.encode(nextSlice(enc.outputChunkSize()));
///
///   // Final timer run once all input is consumed:
///   enc.finish();
///   let compressed = enc.compressed();           // [Nat8] — all bytes merged into one array
///   for (chunk in enc.chunks().vals()) { … };    // — or iterate [[Nat8]] without the merge allocation
///   enc.clear();
///
///   // ── Decoding side (one timer run per step) ─────────────────────
///   let dec = Gzip.Decoder();
///   dec.decode(compressed);
///
///   switch (dec.start()) {
///     case (#err(msg)) Runtime.trap(msg);
///     case (#ok(_))    {};
///   };
///
///   // Each timer run: #default uses the internal 21 MiB budget; #custom(n) overrides it.
///   switch (dec.step(#default)) {
///     case (#err(msg)) Runtime.trap(msg);
///     case (#ok(#more)) rescheduleTimer();
///     case (#ok(#done)) {
///.      // Do something with the output — either:
///       let output = dec.decompressed();          // [Nat8] — all bytes merged into one array
///       for (chunk in dec.chunks().vals()) { … }; // — or iterate [[Nat8]] without the merge allocation
///     };
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

  // ── Encoder ──────────────────────────────────────────────────────────────

  /// Fluent builder for `Gzip.Encoder` (see `EncoderBuilder().build()`).
  public type EncoderBuilder = EncoderFile.EncoderBuilder;
  public let EncoderBuilder = EncoderFile.EncoderBuilder;

  /// Stateful Gzip encoder produced by `EncoderBuilder().build()`.
  public type Encoder = EncoderFile.Encoder;

  // ── Decoder ──────────────────────────────────────────────────────────────

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
  /// For large data use `enc.encode()` + `enc.finish()` + `enc.compressed()` directly across timer runs.
  public func compress(enc : Encoder, bytes : [Nat8]) : [Nat8] {
    enc.encode(bytes);
    enc.finish();
    let out = enc.compressed();
    enc.clear();
    out;
  };

  /// Compress UTF-8 text in one call.
  public func compressText(enc : Encoder, t : Text) : [Nat8] {
    compress(enc, Blob.toArray(Text.encodeUtf8(t)));
  };

  /// Compress a Blob in one call.
  public func compressBlob(enc : Encoder, b : Blob) : [Nat8] {
    compress(enc, Blob.toArray(b));
  };

  /// Decompress `bytes` in one call, returning all output as a single array.
  /// Pass a reusable decoder (e.g. a `transient let` in your canister) to avoid
  /// re-allocating internal structures on every call.
  /// For large data use the `start`/`step` API.
  public func decompress(dec : Decoder, bytes : [Nat8]) : Result.Result<[Nat8], Text> {
    dec.decode(bytes);
    switch (dec.finish()) {
      case (#err(msg)) return #err(msg);
      case (#ok(_)) {};
    };
    #ok(dec.decompressed());
  };

};
