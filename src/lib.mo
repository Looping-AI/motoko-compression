import Gzip "Gzip";

module {

  public type ExtraField = Gzip.ExtraField;
  public type Os = Gzip.Os;
  public type Header = Gzip.Header;

  public type EncoderBuilder = Gzip.EncoderBuilder;
  public let EncoderBuilder = Gzip.EncoderBuilder;
  public type Encoder = Gzip.Encoder;

  public let Decoder = Gzip.Decoder;
  public type Decoder = Gzip.Decoder;

  public let compress = Gzip.compress;
  public let compressText = Gzip.compressText;
  public let compressBlob = Gzip.compressBlob;
  public let decompress = Gzip.decompress;

};
