/// Gzip module — recommended API entry point.
///
/// Import this module to access all Gzip types, classes, and helpers:
///
///   import Gzip "mo:gzip";
///
/// ─────────────────────────────────────────────────────────────────────────
/// FLOW 1 — One-shot helpers  (small data, single call)
/// ─────────────────────────────────────────────────────────────────────────
///
///   // Keep as `transient let` in your canister for efficient reuse.
///   let enc = Gzip.buildEncoder(Gzip.defaultOptions());
///
///   let compressed : [Nat8] = Gzip.compress(enc, input);
///   let dec = Gzip.buildDecoder();
///   let result = Gzip.decompress(dec, compressed);   // Result<[Nat8], Text>
///
/// ─────────────────────────────────────────────────────────────────────────
/// FLOW 2 — Multi-step encoding  (any size, multi-call through Timers)
/// ─────────────────────────────────────────────────────────────────────────
///
/// Use when data exceeds the ~40B-instruction per-call budget.
/// Each call inside a timer processes enc.outputChunkSize() bytes of input (default 6 MiB).
/// The encoder accumulates output internally across calls; call finish() once
/// all input has been fed.
///
///   // ── Encoding side (one timer run per input slice) ─────────────
///   let enc = Gzip.buildEncoder(Gzip.defaultOptions());
///
///   // Each timer run: feed exactly outputChunkSize() bytes of raw input.
///   enc.encode(nextSlice(enc.outputChunkSize()));
///
///   // Final timer run once all input is consumed:
///   enc.finish();
///   let compressed = enc.compressed();           // [Nat8] — all bytes merged into one array
///   for (chunk in enc.chunks().vals()) { ... };  // — or iterate [[Nat8]] without the merge allocation
///   enc.clear();
///
///   // ── Decoding side (one timer run per step) ─────────────────────
///   let dec = Gzip.buildDecoder();
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
///       // Do something with the output — either:
///       let output = dec.decompressed();          // [Nat8] — all bytes merged into one array
///       for (chunk in dec.chunks().vals()) { ... }; // — or iterate [[Nat8]] without the merge allocation
///     };
///   };

import Blob "mo:core/Blob";
import Result "mo:core/Result";
import Text "mo:core/Text";

import HeaderFile "Header";
import EncoderFile "Encoder";
import DecoderFile "Decoder";
import Common "../LZSS/Common";

module {

  // ── Header ───────────────────────────────────────────────────────────────

  public type ExtraField = HeaderFile.ExtraField;
  public type Os = HeaderFile.Os;
  public type Header = HeaderFile.Header;

  // ── Public configuration ─────────────────────────────────────────────────

  public type CompressionLevel = Common.CompressionLevel;

  public type HuffmanMode = {
    #fixed;
    #dynamic;
    #auto;
  };

  public type GzipOptions = {
    lzss : CompressionLevel;
    deflateBlockSize : Nat;
    huffman : HuffmanMode;
    outputChunkSize : Nat;
  };

  /// Default DEFLATE block size (32 KiB).
  public let DEFAULT_DEFLATE_BLOCK_SIZE : Nat = 32_768;
  /// Default per-call input size recommendation for timer-driven encoding (6 MiB).
  public let DEFAULT_OUTPUT_CHUNK_SIZE : Nat = 6_291_456;

  /// Default Gzip options:
  /// - lzss = #balance
  /// - deflateBlockSize = 32 KiB
  /// - huffman = #fixed
  /// - outputChunkSize = 6 MiB
  public func defaultOptions() : GzipOptions {
    {
      lzss = #balance;
      deflateBlockSize = DEFAULT_DEFLATE_BLOCK_SIZE;
      huffman = #fixed;
      outputChunkSize = DEFAULT_OUTPUT_CHUNK_SIZE;
    };
  };

  // ── Stateful codec types ────────────────────────────────────────────────

  public type Encoder = EncoderFile.Encoder;
  public type Decoder = DecoderFile.Decoder;

  /// Create a configured stateful Gzip encoder.
  public func buildEncoder(options : GzipOptions) : Encoder {
    let forceHuffmanKind = switch (options.huffman) {
      case (#fixed) ?#fixed;
      case (#dynamic) ?#dynamic;
      case (#auto) null;
    };
    let deflateOptions = {
      lzss = options.lzss;
      deflate_block_size = options.deflateBlockSize;
      force_huffman_kind = forceHuffmanKind;
    };
    EncoderFile.Encoder(deflateOptions, options.outputChunkSize);
  };

  /// Create a fresh stateful Gzip decoder.
  public func buildDecoder() : Decoder {
    DecoderFile.Decoder();
  };

  // ── One-shot helpers ────────────────────────────────────────────────────

  /// Compress `bytes` in one call using a reusable encoder to avoid
  /// re-allocating internal structures on every call.
  /// The helper calls `clear()` so encoder state never leaks between calls.  
  /// For large data use `enc.encode()` + `enc.finish()` + `enc.compressed()` directly across timer runs.
  public func compress(enc : Encoder, bytes : [Nat8]) : [Nat8] {
    enc.encode(bytes);
    enc.finish();
    let out = enc.compressed();
    enc.clear();
    out;
  };

  /// Compress UTF-8 text in one call using a reusable encoder.
  public func compressText(enc : Encoder, t : Text) : [Nat8] {
    compress(enc, Blob.toArray(Text.encodeUtf8(t)));
  };

  /// Compress a Blob in one call using a reusable encoder.
  public func compressBlob(enc : Encoder, b : Blob) : [Nat8] {
    compress(enc, Blob.toArray(b));
  };

  /// Decompress `bytes` in one call, returning all output as a single array.
  /// Pass a reusable decoder to avoid re-allocating internal structures on every call.
  /// The helper calls `clear()` so decoder state never leaks between calls.
  /// For large data use the `start`/`step` API instead of `finish`.
  public func decompress(dec : Decoder, bytes : [Nat8]) : Result.Result<[Nat8], Text> {
    dec.clear();
    dec.decode(bytes);
    switch (dec.finish()) {
      case (#err(msg)) return #err(msg);
      case (#ok(_)) {};
    };
    let out = dec.decompressed();
    dec.clear();
    #ok(out);
  };

};
