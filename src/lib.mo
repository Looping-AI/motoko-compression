import Gzip "Gzip";

module {

  public type ExtraField = Gzip.ExtraField;
  public type Os = Gzip.Os;
  public type Header = Gzip.Header;

  public type CompressionLevel = Gzip.CompressionLevel;
  public type HuffmanMode = Gzip.HuffmanMode;
  public type GzipOptions = Gzip.GzipOptions;
  public let DEFAULT_DEFLATE_BLOCK_SIZE = Gzip.DEFAULT_DEFLATE_BLOCK_SIZE;
  public let DEFAULT_OUTPUT_CHUNK_SIZE = Gzip.DEFAULT_OUTPUT_CHUNK_SIZE;
  public let defaultOptions = Gzip.defaultOptions;
  public let buildEncoder = Gzip.buildEncoder;
  public type Encoder = Gzip.Encoder;

  public let buildDecoder = Gzip.buildDecoder;
  public type Decoder = Gzip.Decoder;

  public let compress = Gzip.compress;
  public let compressText = Gzip.compressText;
  public let compressBlob = Gzip.compressBlob;
  public let decompress = Gzip.decompress;

};
