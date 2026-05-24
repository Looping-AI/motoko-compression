/// Gzip encoder.
///
/// Key differences from edjcase original:
///   - No `Debug.trap`; finish() is always infallible (encoding cannot fail).
///   - No `Buffer<Nat8>` — all API boundaries use `[Nat8]` / `Blob`.
///   - `EncoderBuilder.lzss` takes `CompressionLevel`, not a `Lzss.Encoder` object.
///   - Chunking uses `setOnBlockFlushed` callback instead of mo:bitbuffer events.
///   - `encodeBuffer` dropped (Buffer type gone); `encodeText` and `encodeBlob` kept.
///   - Default lzss = `?#best`; `dynamic_huffman = false` (fixed Huffman, faster).
///   - `deflateBlockSize` and `outputChunkSize` are separate, orthogonal knobs.

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import List "mo:core/List";
import Nat32 "mo:core/Nat32";
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

  /// Default output chunk size (bytes). Each output chunk holds one or more
  /// complete DEFLATE blocks and can be fed to `Decoder.decode()` independently.
  /// Sized to fit IC ingress and inter-canister response limits (≤ 2 MiB).
  let DEFAULT_OUTPUT_CHUNK_SIZE : Nat = 2_097_152; // 2 MiB

  /// Default threshold below which `finish()` returns `#single` (flat array)
  /// instead of `#chunked`. Matches the IC's practical single-message limit.
  let DEFAULT_SINGLE_THRESHOLD : Nat = DEFAULT_OUTPUT_CHUNK_SIZE;

  // ── Public types ─────────────────────────────────────────────────────────

  /// The result of `Encoder.finish()`.
  /// `#single` is returned when the total compressed size is below the encoder's
  /// `singleThreshold`; the bytes are merged into one flat array.
  /// `#chunked` is returned for larger output; each chunk contains one or more
  /// complete Deflate blocks (block-aligned) and can be fed to
  /// `Decoder.decode()` in separate canister calls.
  public type EncodedResponse = {
    #single : [Nat8];
    #chunked : [[Nat8]];
  };

  // ── EncoderBuilder ────────────────────────────────────────────────────────

  /// Fluent builder for `Encoder`.
  public class EncoderBuilder() = self {

    var _header : Header = Header.defaultHeader();

    var _deflate_opts : DeflateOptions = {
      lzss = #balance; // default LZSS compression level (matches zlib's default)
      deflate_block_size = DEFAULT_DEFLATE_BLOCK_SIZE;
      dynamic_huffman = true; // Better ratio, without impactful performance penalty, matches zlib's default
    };

    var _output_chunk_size : Nat = DEFAULT_OUTPUT_CHUNK_SIZE;
    var _single_threshold : Nat = DEFAULT_SINGLE_THRESHOLD;

    /// Override the Gzip header fields.
    public func header(h : Header) : EncoderBuilder {
      _header := h;
      self;
    };

    /// Use dynamic Huffman tables (better ratio, slightly slower).
    public func dynamicHuffman() : EncoderBuilder {
      _deflate_opts := { _deflate_opts with dynamic_huffman = true };
      self;
    };

    /// Use fixed Huffman tables (faster, slightly larger output).
    public func fixedHuffman() : EncoderBuilder {
      _deflate_opts := { _deflate_opts with dynamic_huffman = false };
      self;
    };

    /// Set the LZSS compression level.
    public func lzss(level : CompressionLevel) : EncoderBuilder {
      _deflate_opts := { _deflate_opts with lzss = level };
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
      _deflate_opts := { _deflate_opts with deflate_block_size = size };
      self;
    };

    /// Set the output chunk size (bytes).
    ///
    /// `finish()` packs one or more complete DEFLATE blocks into each output
    /// chunk, keeping each chunk at most this many bytes. The final chunk also
    /// carries the 8-byte Gzip footer, so it may be up to ~16 bytes larger than
    /// this limit. Cuts are always snapped to DEFLATE block boundaries, which is
    /// required for chunks to be independently decodable via `Decoder.decode()`.
    ///
    /// If a single DEFLATE block already exceeds this size, it will be emitted
    /// as its own (oversized) chunk — set `deflateBlockSize` ≤ `outputChunkSize`.
    ///
    /// Default: 2 MiB (fits IC ingress and inter-canister response limits).
    ///
    /// This value is also a sensible upper bound for the input slice you feed
    /// per self-call when spreading compression across ICP messages, since each
    /// call's compressed output will then be at most one chunk.
    public func outputChunkSize(size : Nat) : EncoderBuilder {
      _output_chunk_size := size;
      self;
    };

    /// Set the threshold (bytes) below which `finish()` merges all chunks into
    /// a single flat `#single` array instead of returning `#chunked`.
    /// Default: 2 MiB (matches `outputChunkSize` default).
    public func singleThreshold(size : Nat) : EncoderBuilder {
      _single_threshold := size;
      self;
    };

    /// Build the configured `Encoder`.
    public func build() : Encoder {
      Encoder(_header, _deflate_opts, _output_chunk_size, _single_threshold);
    };
  };

  // ── Encoder ───────────────────────────────────────────────────────────────

  /// Gzip encoder.
  ///
  /// Call `encode(bytes)` one or more times, then `finish()` to retrieve
  /// the compressed `EncodedResponse`.
  public class Encoder(header : Header, deflate_options : DeflateOptions, output_chunk_size : Nat, single_threshold : Nat) {

    var input_size = 0;
    let crc32 = CRC32.CRC32();
    let bitbuffer = BitBuffer.new();
    var header_written = false;

    /// Byte offsets into `bitbuffer` recorded after each Deflate block flush.
    let block_ends = List.empty<Nat>();

    let deflate = DeflateEncoder.Encoder(bitbuffer, deflate_options);
    deflate.setOnBlockFlushed(
      func(byte_offset : Nat) {
        List.add(block_ends, byte_offset);
      }
    );

    /// Returns the configured output chunk size.
    ///
    /// Use this value as the per-self-call input slice size when spreading
    /// compression across ICP messages: each input slice of this size will
    /// produce at most one output chunk, keeping inter-canister payloads
    /// within IC message limits.
    public func outputChunkSize() : Nat { output_chunk_size };

    /// Compress `bytes` and accumulate them in the internal buffer.
    public func encode(bytes : [Nat8]) {
      if (bytes.size() == 0) return;

      // Pre-grow the output buffer to the worst-case DEFLATE stored-block size
      // so the backing array never doubles during compression of this chunk.
      // Worst case: raw (stored) blocks — 5 bytes header per 65535-byte block.
      // Add 25 bytes for gzip header (10) + footer (8) + slack (7).
      bitbuffer.reserve(bitbuffer.byteSize() + bytes.size() + bytes.size() / 65535 * 5 + 25);
      input_size += bytes.size();
      crc32.update(bytes);
      if (not header_written) {
        header_written := true;
        Header.encode(bitbuffer, header, deflate_options.lzss);
      };
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

    /// Reset the encoder state (does not free the bitbuffer allocation).
    public func clear() {
      input_size := 0;
      crc32.reset();
      bitbuffer.clear();
      List.clear(block_ends);
      header_written := false;
    };

    /// Flush the final Deflate block, append the Gzip footer, and return
    /// the compressed data split into block-aligned chunks.
    public func finish() : EncodedResponse {
      // Write the Gzip header if no data was ever encoded
      if (not header_written) {
        header_written := true;
        Header.encode(bitbuffer, header, deflate_options.lzss);
      };

      // Flush the final Deflate block (BFINAL=1)
      ignore deflate.finish(); // calls flush(true) + byteAlign + clear

      // Footer: CRC32 (4 bytes LE) + ISIZE (4 bytes LE, mod 2^32)
      let crc32_val = crc32.finish();
      bitbuffer.addBytes(Utils.natToLeBytes(Nat32.toNat(crc32_val), 4));
      bitbuffer.addBytes(Utils.natToLeBytes(input_size % 4294967296, 4));

      let total = bitbuffer.byteSize();
      let all = bitbuffer.getBytes(0, total);

      let resp : EncodedResponse = if (total < single_threshold) {
        #single all;
      } else {
        // Slice `all` into output chunks.
        //
        // Each chunk holds one or more complete DEFLATE blocks (cuts snapped to
        // DEFLATE boundaries so chunks are independently decodable). The final
        // chunk carries the Gzip footer and may be up to ~16 B larger than
        // `output_chunk_size` due to footer + last-block Huffman overhead.
        //
        // Degenerate case: if a single DEFLATE block exceeds `output_chunk_size`,
        // it is emitted as its own oversized chunk rather than being split mid-block.
        let ends = List.toArray(block_ends);
        let n = ends.size();

        let chunks : [[Nat8]] = if (n == 0) {
          // encode() was never called — single chunk with header + empty Deflate + footer
          [all];
        } else {
          let out = List.empty<[Nat8]>();
          var chunk_lo = 0;
          var prev_block_end = 0;
          var blocks_in_chunk = 0;

          for (block_end in ends.vals()) {
            // Avoid Nat underflow: rewrite `block_end - chunk_lo > output_chunk_size`
            // as `block_end > chunk_lo + output_chunk_size` (both are Nat, sum never wraps).
            if (block_end > chunk_lo + output_chunk_size and blocks_in_chunk > 0) {
              // Adding this block would exceed the limit; emit what we have.
              List.add(out, Array.tabulate<Nat8>(prev_block_end - chunk_lo, func(j) { all[chunk_lo + j] }));
              chunk_lo := prev_block_end;
              blocks_in_chunk := 0;
            };
            prev_block_end := block_end;
            blocks_in_chunk += 1;
          };

          // Final chunk: from chunk_lo to end of buffer (includes Gzip footer).
          List.add(out, Array.tabulate<Nat8>(total - chunk_lo, func(j) { all[chunk_lo + j] }));
          List.toArray(out);
        };

        #chunked chunks;
      };
      clear();
      resp;
    };
  };

};
