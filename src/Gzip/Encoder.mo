/// Gzip encoder.
///
/// Key differences from edjcase original:
///   - No `Buffer<Nat8>` — all API boundaries use `[Nat8]` / `Blob`.
///   - `EncoderBuilder.lzss` takes `CompressionLevel`, not a `Lzss.Encoder` object.
///   - `encodeBuffer` dropped (Buffer type gone).
///   - Default lzss = `#balance`; `force_huffman_kind = null` (auto fixed/dynamic per block).
///   - `deflateBlockSize` and `outputChunkSize` are separate, orthogonal knobs.
///   - Output is accumulated internally; call `finish()` to flush, then
///     `compressed()` to get all bytes or `chunks()` to iterate without merging.

import Array "mo:core/Array";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Nat32 "mo:core/Nat32";

import BitBuffer "../internal/BitBuffer";
import CRC32 "../internal/CRC32";
import DeflateEncoder "../Deflate/Encoder";
import Header "Header";
import Utils "../internal/utils";
import Common "../LZSS/Common";

module {

  type BitBuffer = BitBuffer.BitBuffer;
  type CompressionLevel = Common.CompressionLevel;
  type DeflateOptions = DeflateEncoder.DeflateOptions;

  // ── Constants ────────────────────────────────────────────────────────────

  /// Default DEFLATE block size (bytes). Matches zlib's level-default and keeps
  /// per-block working memory (List<Symbol>) proportionate. Has no effect on
  /// LZSS back-reference reach (the 32 KiB sliding window spans all blocks).
  let DEFAULT_DEFLATE_BLOCK_SIZE : Nat = 32_768; // 32 KiB

  /// Recommended input slice size per ICP canister message when spreading
  /// compression across self-calls via `finish()`.
  /// Sized to stay safely within the 40B-instruction per-call limit with
  /// standard parameters (#balance LZSS, 32 KiB deflate block size).
  let DEFAULT_OUTPUT_CHUNK_SIZE : Nat = 6_291_456; // 6 MiB

  /// Threshold at which the streaming encoder drains completed bytes to the
  /// internal accumulator. Balances memory use against drain overhead.
  let STREAM_FLUSH_THRESHOLD : Nat = 1_048_576; // 1 MiB

  // ── EncoderBuilder ────────────────────────────────────────────────────────

  /// Fluent builder for `Encoder`.
  public class EncoderBuilder() = self {

    // lzss: #balance matches zlib's default. #fast is counter-intuitively slower: a smaller
    //   window triggers slideWindow() more often, multiplying WASM bounds checks across the window array.
    // force_huffman_kind: null auto-selects fixed vs dynamic Huffman, gives best ratio; fixed is typically fastest.
    var deflateOpts : DeflateOptions = {
      lzss = #balance;
      deflate_block_size = DEFAULT_DEFLATE_BLOCK_SIZE;
      force_huffman_kind = ?#fixed;
    };

    var chunkSize : Nat = DEFAULT_OUTPUT_CHUNK_SIZE;

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
    /// across ICP canister messages via `finish()`.
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
      Encoder(deflateOpts, chunkSize);
    };
  };

  // ── Encoder ───────────────────────────────────────────────────────────────

  /// Gzip encoder.
  ///
  /// Call `encode(bytes)` one or more times, then:
  ///   1. `finish()` — flush the final DEFLATE block and append the Gzip footer.
  ///   2. `compressed()` — merge all accumulated chunks into one `[Nat8]`.
  ///      Or iterate `chunks()` directly to avoid the merge allocation.
  ///   3. `clear()` — reset for reuse.
  public class Encoder(deflate_options : DeflateOptions, output_chunk_size : Nat) {

    var inputSize = 0;
    let crc32 = CRC32.CRC32();
    let bitbuffer = BitBuffer.new();
    var headerWritten = false;

    // Internal output accumulator — always wired; never exposed to callers.
    let outputChunks : List.List<[Nat8]> = List.empty();

    func ensureHeaderWritten() {
      if (not headerWritten) {
        headerWritten := true;
        Header.encode(bitbuffer, Header.defaultHeader(), deflate_options.lzss);
      };
    };

    func writeFooter(crc32Val : Nat32) {
      bitbuffer.addBytes(Utils.natToLeBytes(Nat32.toNat(crc32Val), 4));
      bitbuffer.addBytes(Utils.natToLeBytes(inputSize % 4294967296, 4));
    };

    let deflate = DeflateEncoder.Encoder(bitbuffer, deflate_options);
    deflate.setOnBlockFlushed(
      func(_ : Nat) {
        if (bitbuffer.byteSize() >= STREAM_FLUSH_THRESHOLD) {
          List.add(outputChunks, bitbuffer.drainCompleteBytes());
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

    /// Reset the encoder state (does not free the bitbuffer allocation).
    public func clear() {
      inputSize := 0;
      crc32.reset();
      bitbuffer.clear();
      headerWritten := false;
      List.clear(outputChunks);
      deflate.clear();
    };

    /// Flush the final DEFLATE block and append the Gzip footer.
    /// Call `compressed()` or iterate `chunks()` afterwards to read the output,
    /// then call `clear()` to reset the encoder for reuse.
    public func finish() {
      ensureHeaderWritten();
      ignore deflate.finish();
      let crc32Val = crc32.finish();
      writeFooter(crc32Val);
      List.add(outputChunks, bitbuffer.drainCompleteBytes());
    };

    /// Return all compressed bytes as a single flat array.
    /// Call after `finish()`.
    public func compressed() : [Nat8] {
      let n = List.size(outputChunks);
      if (n == 0) return [];
      if (n == 1) return List.get(outputChunks, 0) ??[];
      Array.flatten(List.toArray(outputChunks));
    };

    /// Return the raw accumulated output chunks without merging.
    /// Call after `finish()`. Prefer this over `compressed()` when iterating
    /// chunk-by-chunk (e.g. writing to stable memory) to avoid the merge allocation.
    public func chunks() : [[Nat8]] {
      List.toArray(outputChunks);
    };

  };

};
