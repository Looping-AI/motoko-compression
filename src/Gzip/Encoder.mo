/// Gzip encoder.
///
/// Key differences from edjcase original:
///   - No `Debug.trap`; finish() is always infallible (encoding cannot fail).
///   - No `Buffer<Nat8>` — all API boundaries use `[Nat8]` / `Blob`.
///   - `EncoderBuilder.lzss` takes `CompressionLevel`, not a `Lzss.Encoder` object.
///   - Chunking uses `setOnBlockFlushed` callback instead of mo:bitbuffer events.
///   - `encodeBuffer` dropped (Buffer type gone); `encodeText` and `encodeBlob` kept.
///   - Default lzss = `?#best`; `dynamic_huffman = false` (fixed Huffman, faster).

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import List "mo:core/List";
import Nat "mo:core/Nat";
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

  // ── Public types ─────────────────────────────────────────────────────────

  /// The result of `Encoder.finish()`.
  /// Each chunk contains one or more complete Deflate blocks (block-aligned),
  /// so chunks can be fed to `Decoder.decode()` in separate canister calls.
  public type EncodedResponse = {
    /// One entry per Deflate block (plus gzip header on first / footer on last).
    chunks : [[Nat8]];
    total_size : Nat;
  };

  // ── EncoderBuilder ────────────────────────────────────────────────────────

  /// Fluent builder for `Encoder`.
  public class EncoderBuilder() = self {

    var _header : Header = Header.defaultHeader();

    var _opts : DeflateOptions = {
      lzss = ?#best;
      block_size = Utils.INSTRUCTION_LIMIT;
      dynamic_huffman = false;
    };

    /// Override the Gzip header fields.
    public func header(h : Header) : EncoderBuilder {
      _header := h;
      self;
    };

    /// Disable LZSS compression (raw blocks, no compression).
    /// Block size is automatically capped to the raw-block maximum (65 535).
    public func noCompression() : EncoderBuilder {
      _opts := {
        _opts with lzss = null;
        block_size = Nat.min(_opts.block_size, 65_535);
      };
      self;
    };

    /// Use dynamic Huffman tables (better ratio, slightly slower).
    public func dynamicHuffman() : EncoderBuilder {
      _opts := { _opts with dynamic_huffman = true };
      self;
    };

    /// Use fixed Huffman tables (faster, slightly larger output).
    public func fixedHuffman() : EncoderBuilder {
      _opts := { _opts with dynamic_huffman = false };
      self;
    };

    /// Set the LZSS compression level.
    public func lzss(level : CompressionLevel) : EncoderBuilder {
      _opts := { _opts with lzss = ?level };
      self;
    };

    /// Set the Deflate block size (bytes). Each block becomes one output chunk.
    public func blockSize(size : Nat) : EncoderBuilder {
      _opts := { _opts with block_size = size };
      self;
    };

    /// Build the configured `Encoder`.
    public func build() : Encoder { Encoder(_header, _opts) };
  };

  // ── Encoder ───────────────────────────────────────────────────────────────

  /// Gzip encoder.
  ///
  /// Call `encode(bytes)` one or more times, then `finish()` to retrieve
  /// the compressed `EncodedResponse`.
  public class Encoder(header : Header, deflate_options : DeflateOptions) {

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

    /// Returns the configured Deflate block size.
    public func blockSize() : Nat { deflate_options.block_size };

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

      // Slice at block boundaries; last chunk includes the Gzip footer
      let ends = List.toArray(block_ends);
      let n = ends.size();

      let chunks : [[Nat8]] = if (n == 0) {
        // encode() was never called — single chunk with header + empty Deflate + footer
        [all];
      } else {
        Array.tabulate<[Nat8]>(
          n,
          func(i) {
            let lo = if (i == 0) 0 else ends[i - 1];
            let hi = if (i == n - 1) total else ends[i];
            Array.tabulate<Nat8>(hi - lo, func(j) { all[lo + j] });
          },
        );
      };

      let resp = { chunks; total_size = total };
      clear();
      resp;
    };
  };

};
