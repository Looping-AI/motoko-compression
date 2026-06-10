import Gzip "Gzip";

module {

  /// RFC 1952 FEXTRA field: a two-byte subfield ID and associated data bytes.
  public type ExtraField = Gzip.ExtraField;
  /// Operating system identifier written into byte 9 of the Gzip header (RFC 1952).
  public type Os = Gzip.Os;
  /// Decoded Gzip header fields (RFC 1952 §2.3).
  public type Header = Gzip.Header;

  /// LZSS compression level: `#fast`, `#balance`, or `#best`.
  public type CompressionLevel = Gzip.CompressionLevel;
  /// Huffman table selection: `#fixed` (RFC static tables), `#dynamic` (per-block),
  /// or `#auto` (picks the cheaper variant per block).
  public type HuffmanMode = Gzip.HuffmanMode;
  /// Full configuration for the Gzip encoder.
  public type GzipOptions = Gzip.GzipOptions;
  /// Default DEFLATE block size (32 KiB).
  public let DEFAULT_DEFLATE_BLOCK_SIZE = Gzip.DEFAULT_DEFLATE_BLOCK_SIZE;
  /// Default per-call input size recommendation for timer-driven encoding (6 MiB).
  public let DEFAULT_OUTPUT_CHUNK_SIZE = Gzip.DEFAULT_OUTPUT_CHUNK_SIZE;
  /// Return default Gzip options: `#balance` LZSS, 32 KiB block size, `#fixed` Huffman, 6 MiB chunk.
  public let defaultOptions = Gzip.defaultOptions;
  /// Create a configured stateful Gzip encoder.
  public let buildEncoder = Gzip.buildEncoder;
  /// Stateful Gzip encoder. Create with `buildEncoder`; feed data with `encode`;
  /// finalise with `finish`; retrieve output with `compressed` or `chunks`.
  public type Encoder = Gzip.Encoder;

  /// Create a fresh stateful Gzip decoder.
  public let buildDecoder = Gzip.buildDecoder;
  /// Stateful Gzip decoder. Create with `buildDecoder`; feed compressed bytes
  /// with `decode`; run with `finish` or the resumable `start`/`step` API.
  public type Decoder = Gzip.Decoder;

  /// Compress `bytes` in one call using a reusable encoder.
  public let compress = Gzip.compress;
  /// Compress UTF-8 text in one call using a reusable encoder.
  public let compressText = Gzip.compressText;
  /// Compress a `Blob` in one call using a reusable encoder.
  public let compressBlob = Gzip.compressBlob;
  /// Decompress `bytes` in one call, returning all output as a single array.
  public let decompress = Gzip.decompress;

};
