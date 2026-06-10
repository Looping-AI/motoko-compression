/// Deflate symbol types and helpers.
///
/// A `Symbol` is either a raw literal byte, a back-reference pointer, or the
/// special EndOfBlock marker (code 256).  The length/distance coding tables
/// follow RFC 1951.

import Nat8 "mo:core/Nat8";
import Nat16 "mo:core/Nat16";
import HuffmanEncoder "../Huffman/Encoder";

module {

  /// A deflate symbol: literal byte, back-reference, or end-of-block.
  public type Symbol = {
    #literal : Nat8;
    #pointer : (Nat, Nat); // (backward_offset, length)
    #EndOfBlock;
  };

  // ── Fixed Huffman code tables (RFC 1951 §3.2.6) ────────────────────────

  /// Fixed literal/length code ranges with their base code values.
  public let FIXED_LENGTH_CODES : [{
    bitwidth : Nat;
    symbol_start : Nat;
    symbol_end : Nat;
    base_code : Nat16;
  }] = [
    { bitwidth = 8; symbol_start = 0; symbol_end = 143; base_code = 0x30 },
    { bitwidth = 9; symbol_start = 144; symbol_end = 255; base_code = 0x190 },
    { bitwidth = 7; symbol_start = 256; symbol_end = 279; base_code = 0x00 },
    { bitwidth = 8; symbol_start = 280; symbol_end = 287; base_code = 0xc0 },
  ];

  /// Order in which bitwidth code lengths are stored (RFC 1951 §3.2.7).
  public let BITWIDTH_CODE_ORDER : [Nat] = [
    16,
    17,
    18,
    0,
    8,
    7,
    9,
    6,
    10,
    5,
    11,
    4,
    12,
    3,
    13,
    2,
    14,
    1,
    15,
  ];

  // ── Encoder class ──────────────────────────────────────────────────────

  /// Pairs a literal/length Huffman encoder with a distance Huffman encoder
  /// for encoding Deflate compressed symbols.
  public class Encoder(
    literal_encoder : HuffmanEncoder.Encoder,
    distance_encoder : HuffmanEncoder.Encoder,
  ) {
    /// Huffman encoder for literal/length codes (symbols 0–285).
    public let literal = literal_encoder;
    /// Huffman encoder for distance codes (symbols 0–29).
    public let distance = distance_encoder;
  };

};
