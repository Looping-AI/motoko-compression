/// Gzip encoder.
///
/// Key differences from edjcase original:
///   - No `Buffer<Nat8>` — all API boundaries use `[Nat8]` / `Blob`.
///   - `EncoderBuilder.lzss` takes `CompressionLevel`, not a `Lzss.Encoder` object.
///   - `encodeBuffer` dropped (Buffer type gone); `encodeText` and `encodeBlob` kept.
///   - Default lzss = `#balance`; `force_huffman_kind = null` (auto fixed/dynamic per block).
///   - `deflateBlockSize` and `outputChunkSize` are separate, orthogonal knobs.

import Blob "mo:core/Blob";
import Nat "mo:core/Nat";
import Nat32 "mo:core/Nat32";
import Runtime "mo:core/Runtime";
import Text "mo:core/Text";

import BitBuffer "../internal/BitBuffer";
import CRC32 "../internal/CRC32";
import DeflateEncoder "../Deflate/Encoder";
import Header "Header";
import Utils "../internal/utils";
import Common "../LZSS/Common";

module {

  type BitBuffer = BitBuffer.BitBuffer;
  type Header = Header.Header;
  type CompressionLevel = Common.CompressionLevel;
  type DeflateOptions = DeflateEncoder.DeflateOptions;

  // ── Constants ────────────────────────────────────────────────────────────

  /// Default DEFLATE block size (bytes). Matches zlib's level-default and keeps
  /// per-block working memory (List<Symbol>) proportionate. Has no effect on
  /// LZSS back-reference reach (the 32 KiB sliding window spans all blocks).
  let DEFAULT_DEFLATE_BLOCK_SIZE : Nat = 32_768; // 32 KiB

  /// Recommended input slice size per ICP canister message when spreading
  /// compression across self-calls via `finishStreaming()`.
  /// Sized to stay safely within the 40B-instruction per-call limit with
  /// standard parameters (#balance LZSS, 32 KiB deflate block size).
  let DEFAULT_OUTPUT_CHUNK_SIZE : Nat = 6_291_456; // 6 MiB

  /// Threshold at which the streaming encoder drains completed bytes to the
  /// output callback. Balances memory use against drain overhead.
  let STREAM_FLUSH_THRESHOLD : Nat = 1_048_576; // 1 MiB

  // ── Public types ─────────────────────────────────────────────────────────

  /// Summary returned by `Encoder.finishStreaming()`.
  public type EncodedSummary = {
    input_size : Nat;
    compressed_size : Nat;
    crc32 : Nat32;
  };

  // ── EncoderBuilder ────────────────────────────────────────────────────────

  /// Fluent builder for `Encoder`.
  public class EncoderBuilder() = self {

    var hdr : Header = Header.defaultHeader();

    // lzss: #balance matches zlib's default. #fast is counter-intuitively slower: a smaller
    //   window triggers slideWindow() more often, multiplying WASM bounds checks across the window array.
    // force_huffman_kind: null auto-selects fixed vs dynamic Huffman, gives best ratio; fixed is typically fastest.
    var deflateOpts : DeflateOptions = {
      lzss = #balance;
      deflate_block_size = DEFAULT_DEFLATE_BLOCK_SIZE;
      force_huffman_kind = ?#fixed;
    };

    var chunkSize : Nat = DEFAULT_OUTPUT_CHUNK_SIZE;

    /// Override the Gzip header fields.
    public func header(h : Header) : EncoderBuilder {
      hdr := h;
      self;
    };

    /// Force dynamic Huffman tables for every block (better ratio, slightly slower).
    public func dynamicHuffman() : EncoderBuilder {
      deflateOpts := { deflateOpts with force_huffman_kind = ?#dynamic };
      self;
    };

    /// Force fixed Huffman tables for every block (faster, slightly larger output).
    public func fixedHuffman() : EncoderBuilder {
      deflateOpts := { deflateOpts with force_huffman_kind = ?#fixed };
      self;
    };

    /// Auto-select fixed vs dynamic Huffman per block (default).
    public func autoHuffman() : EncoderBuilder {
      deflateOpts := { deflateOpts with force_huffman_kind = null };
      self;
    };

    /// Set the LZSS compression level.
    public func lzss(level : CompressionLevel) : EncoderBuilder {
      deflateOpts := { deflateOpts with lzss = level };
      self;
    };

    /// Set the DEFLATE block size (bytes).
    ///
    /// This is an **internal compression parameter**: it controls how often
    /// a new DEFLATE block (and its Huffman table) is started. Smaller values
    /// increase Huffman overhead; larger values increase per-block memory use.
    /// The LZSS 32 KiB back-reference window spans all blocks regardless.
    /// Default: 32 KiB (matches zlib's default).
    public func deflateBlockSize(size : Nat) : EncoderBuilder {
      deflateOpts := { deflateOpts with deflate_block_size = size };
      self;
    };

    /// Set the recommended input slice size (bytes) for spreading compression
    /// across ICP canister messages via `finishStreaming()`.
    ///
    /// Use `encoder.outputChunkSize()` as the amount of raw input to feed per
    /// self-call: each slice of this size stays safely within the 40B-instruction
    /// per-call budget with standard parameters (#balance LZSS, 32 KiB blocks).
    ///
    /// Default: 6 MiB.
    public func outputChunkSize(size : Nat) : EncoderBuilder {
      chunkSize := size;
      self;
    };

    /// Build the configured `Encoder`.
    public func build() : Encoder {
      Encoder(hdr, deflateOpts, chunkSize);
    };
  };

  // ── Encoder ───────────────────────────────────────────────────────────────

  /// Gzip encoder.
  ///
  /// Register an output callback with `setOnOutput`, call `encode(bytes)` one or
  /// more times, then call `finishStreaming()` to flush the final block and footer.
  public class Encoder(header : Header, deflate_options : DeflateOptions, output_chunk_size : Nat) {

    var inputSize = 0;
    let crc32 = CRC32.CRC32();
    let bitbuffer = BitBuffer.new();
    var headerWritten = false;

    /// Streaming output callback — set via `setOnOutput`.
    var onOutput : ?([Nat8] -> ()) = null;
    /// Total bytes drained to `onOutput` so far in this streaming session.
    var streamedOut : Nat = 0;

    func ensureHeaderWritten() {
      if (not headerWritten) {
        headerWritten := true;
        Header.encode(bitbuffer, header, deflate_options.lzss);
      };
    };

    func writeFooter(crc32Val : Nat32) {
      bitbuffer.addBytes(Utils.natToLeBytes(Nat32.toNat(crc32Val), 4));
      bitbuffer.addBytes(Utils.natToLeBytes(inputSize % 4294967296, 4));
    };

    let deflate = DeflateEncoder.Encoder(bitbuffer, deflate_options);
    deflate.setOnBlockFlushed(
      func(_ : Nat) {
        switch (onOutput) {
          case (?sink) {
            if (bitbuffer.byteSize() >= STREAM_FLUSH_THRESHOLD) {
              let chunk = bitbuffer.drainCompleteBytes();
              streamedOut += chunk.size();
              sink(chunk);
            };
          };
          case null {};
        };
      }
    );

    /// Returns the configured output chunk size.
    ///
    /// Use this value as the per-self-call input slice size when spreading
    /// compression across ICP messages: each input slice of this size will
    /// produce at most one output chunk, keeping inter-canister payloads
    /// within IC message limits.
    public func outputChunkSize() : Nat { output_chunk_size };

    /// Returns the configured DEFLATE block size (bytes).
    public func deflateBlockSize() : Nat { deflate_options.deflate_block_size };

    /// Compress `bytes` and accumulate them in the internal buffer.
    public func encode(bytes : [Nat8]) {
      if (bytes.size() == 0) return;

      // Reserve enough for the compressed output of this slice, capped at
      // STREAM_FLUSH_THRESHOLD so a large streaming slice (e.g. 6 MiB) never
      // pre-allocates more than ~2× the flush window before draining.
      bitbuffer.reserve(bitbuffer.byteSize() + Nat.min(bytes.size(), STREAM_FLUSH_THRESHOLD) + 25);
      inputSize += bytes.size();
      crc32.update(bytes);
      ensureHeaderWritten();
      deflate.encode(bytes);
    };

    /// Compress UTF-8 text.
    public func encodeText(t : Text) {
      encode(Blob.toArray(Text.encodeUtf8(t)));
    };

    /// Compress a Blob.
    public func encodeBlob(b : Blob) {
      encode(Blob.toArray(b));
    };

    /// Register a callback that receives compressed bytes as they are produced.
    /// Must be called before `finishStreaming()`.
    public func setOnOutput(cb : [Nat8] -> ()) {
      onOutput := ?cb;
    };

    /// Reset the encoder state (does not free the bitbuffer allocation).
    public func clear() {
      inputSize := 0;
      crc32.reset();
      bitbuffer.clear();
      headerWritten := false;
      onOutput := null;
      streamedOut := 0;
      deflate.clear();
    };

    /// Flush the final Deflate block, append the Gzip footer, and stream all
    /// remaining bytes to the registered `onOutput` callback.
    /// Traps if `setOnOutput` was not called first.
    /// Returns a summary with `input_size`, `compressed_size`, and `crc32`.
    public func finishStreaming() : EncodedSummary {
      let sink = switch (onOutput) {
        case (?s) s;
        case null Runtime.trap("Gzip.Encoder.finishStreaming: call setOnOutput first");
      };
      ensureHeaderWritten();
      ignore deflate.finish();
      let crc32Val = crc32.finish();
      writeFooter(crc32Val);
      // Drain all remaining bytes (byteAlign already done by deflate.finish footer).
      let remaining = bitbuffer.drainCompleteBytes();
      streamedOut += remaining.size();
      sink(remaining);
      let summary : EncodedSummary = {
        input_size = inputSize;
        compressed_size = streamedOut;
        crc32 = crc32Val;
      };
      clear();
      summary;
    };

  };

};
