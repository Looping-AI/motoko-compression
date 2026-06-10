/// Gzip encoder.
///
/// Key differences from edjcase original:
///   - No `Buffer<Nat8>` — all API boundaries use `[Nat8]` / `Blob`.
///   - `EncoderBuilder.lzss` takes `CompressionLevel`, not a `Lzss.Encoder` object.
///   - `encodeBuffer` dropped (Buffer type gone).
///   - Default lzss = `#balance`; `force_huffman_kind = ?#fixed` (fixed Huffman for all blocks by default).
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

module {

  type BitBuffer = BitBuffer.BitBuffer;
  type DeflateOptions = DeflateEncoder.DeflateOptions;

  /// Threshold at which the streaming encoder drains completed bytes to the
  /// internal accumulator. Balances memory use against drain overhead.
  let STREAM_FLUSH_THRESHOLD : Nat = 1_048_576; // 1 MiB

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
      deflate.finish();
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
