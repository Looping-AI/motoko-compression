/// Gzip module — recommended API entry point.
///
/// Import this module to access all Gzip types, classes, and helpers:
///
///   import Gzip "mo:compression/Gzip";
///
/// ─────────────────────────────────────────────────────────────────────────
/// FLOW 1 — One-shot helpers  (small / in-memory data)
/// ─────────────────────────────────────────────────────────────────────────
///
///   let compressed : [Nat8] = Gzip.compress(input);
///   let result = Gzip.decompress(compressed);   // Result<[Nat8], Text>
///
/// ─────────────────────────────────────────────────────────────────────────
/// FLOW 2 — Builder encode → decoder  (any size, single canister call)
/// ─────────────────────────────────────────────────────────────────────────
///
///   // Encode — register callback, feed one or more slices, then finish.
///   let enc = Gzip.EncoderBuilder().build();
///   let parts = List.empty<[Nat8]>();
///   enc.setOnOutput(func chunk { List.add(parts, chunk) });
///   enc.encodeText("Hello, ");
///   enc.encodeBlob(someBlob);
///   ignore enc.finishStreaming();
///
///   // Decode — feed collected chunks to the decoder.
///   let dec = Gzip.Decoder();
///   for (chunk in List.values(parts)) { ignore dec.decode(chunk) };
///   let output = Buffer.Buffer<Nat8>(0);
///   switch (dec.finishStreaming(func cs { Buffer.addAll(output, cs.vals()) })) {
///     case (#ok(_))    { /* use output.toArray() */ };
///     case (#err(msg)) Runtime.trap(msg);
///   };
///
/// ─────────────────────────────────────────────────────────────────────────
/// FLOW 3 — ICP streaming  (spread work across canister self-calls)
/// ─────────────────────────────────────────────────────────────────────────
///
/// Use when data exceeds the ~40B-instruction per-call budget.
/// Each self-call processes enc.outputChunkSize() bytes of input (default 6 MiB).
/// The encoder pushes completed output chunks via the registered callback;
/// the decoder processes them incrementally via start() + repeated step().
///
///   // ── Encoding side (one canister message per input slice) ─────────────
///   let enc = Gzip.EncoderBuilder().build();
///   enc.setOnOutput(func chunk { storeChunk(chunk) });
///
///   // Each self-call: feed exactly outputChunkSize() bytes of raw input.
///   enc.encode(nextSlice(enc.outputChunkSize()));  // emits ≤ 1 output chunk
///
///   // Final self-call once all input is consumed:
///   let summary = enc.finishStreaming();
///   // summary: { input_size; compressed_size; crc32 }
///
///   // ── Decoding side (one canister message per step) ─────────────────────
///   let dec = Gzip.Decoder();
///   for (chunk in storedChunks.vals()) { ignore dec.decode(chunk) };
///
///   switch (dec.start()) {
///     case (#err(msg)) Runtime.trap(msg);
///     case (#ok(_))    {};
///   };
///
///   // Each self-call: budget maxOutBytes of decompressed output per step.
///   switch (dec.step(6_000_000, func cs { consume(cs) })) {
///     case (#ok(#more))           selfCallAgain();
///     case (#ok(#done(summary)))  finalize(summary);
///     case (#err(msg))            Runtime.trap(msg);
///   };

import List "mo:core/List";
import Result "mo:core/Result";

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

  /// Summary returned by `Encoder.finishStreaming()`.
  public type EncodedSummary = EncoderFile.EncodedSummary;

  /// Fluent builder for `Gzip.Encoder` (see `EncoderBuilder().build()`).
  public type EncoderBuilder = EncoderFile.EncoderBuilder;
  public let EncoderBuilder = EncoderFile.EncoderBuilder;

  /// Stateful Gzip encoder produced by `EncoderBuilder().build()`.
  public type Encoder = EncoderFile.Encoder;

  // ── Decoder ──────────────────────────────────────────────────────────────

  /// Summary returned by `Decoder.finishStreaming()` / `Decoder.step()`.
  public type StreamedSummary = DecoderFile.StreamedSummary;

  /// Construct a stateful Gzip decoder.
  /// Feed compressed bytes with `decode()`, then drive decompression with
  /// `finishStreaming(consume)` (one-shot) or `start()` + `step()` (incremental).
  public let Decoder = DecoderFile.Decoder;

  /// Type of the stateful Gzip decoder (constructed via `Decoder()`).
  public type Decoder = DecoderFile.Decoder;

  // ── Convenience helpers ──────────────────────────────────────────────────

  /// Compress `bytes` in one call, returning the raw Gzip bytes.
  /// For large data use `EncoderBuilder` with `setOnOutput` + `finishStreaming()`.
  public func compress(bytes : [Nat8]) : [Nat8] {
    let enc = EncoderFile.EncoderBuilder().build();
    let parts = List.empty<[Nat8]>();
    enc.setOnOutput(func chunk { List.add(parts, chunk) });
    enc.encode(bytes);
    ignore enc.finishStreaming();
    mergeChunks(List.toArray(parts));
  };

  /// Decompress `bytes` in one call, collecting all output into a single array.
  /// For large data use `Decoder` + `finishStreaming` or the `start`/`step` API.
  public func decompress(bytes : [Nat8]) : Result.Result<[Nat8], Text> {
    let dec = DecoderFile.Decoder();
    ignore dec.decode(bytes);
    let parts = List.empty<[Nat8]>();
    switch (dec.finishStreaming(func cs { List.add(parts, cs) })) {
      case (#err(msg)) return #err(msg);
      case (#ok(_)) {};
    };
    #ok(mergeChunks(List.toArray(parts)));
  };

  // ── Internal ─────────────────────────────────────────────────────────────

  func mergeChunks(cs : [[Nat8]]) : [Nat8] {
    let out = List.empty<Nat8>();
    for (c in cs.vals()) {
      for (b in c.vals()) { List.add(out, b) };
    };
    List.toArray(out);
  };

};
