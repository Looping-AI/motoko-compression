/// Deflate symbol types and helpers.
///
/// A `Symbol` is either a raw literal byte, a back-reference pointer, or the
/// special EndOfBlock marker (code 256).  The length/distance coding tables
/// follow RFC 1951.

import Nat8 "mo:core/Nat8";
import Nat16 "mo:core/Nat16";
import Result "mo:core/Result";
import Runtime "mo:core/Runtime";
import HuffmanEncoder "../Huffman/Encoder";
import HuffmanDecoder "../Huffman/Decoder";
import BitBuffer "../internal/BitBuffer";
import BitReader "../BitReader";

module {

  type BitBuffer = BitBuffer.BitBuffer;
  type BitReader = BitReader.BitReader;
  type Result<A, B> = Result.Result<A, B>;

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

  public let MAX_DISTANCE : Nat = 32_768;

  // ── Length encoding ────────────────────────────────────────────────────

  /// Returns (literal-code, extra-bit-count, extra-bit-value) for a symbol.
  public func lengthCode(symbol : Symbol) : (Nat16, Nat, Nat16) {
    switch symbol {
      case (#EndOfBlock) { (256, 0, 0) };
      case (#literal(byte)) { (Nat8.toNat16(byte), 0, 0) };
      case (#pointer(_, length)) {
        if (length < 3 or length > 258) {
          Runtime.trap("Deflate: length " # debug_show length # " out of range [3,258]");
        };
        let len = Nat16.fromNat(length);
        if (len <= 10) { (257 + (len - 3), 0, 0) } else if (len <= 18) {
          (265 + ((len - 11) / 2), 1, (len - 11) % 2);
        } else if (len <= 34) { (269 + ((len - 19) / 4), 2, (len - 19) % 4) } else if (len <= 66) {
          (273 + ((len - 35) / 8), 3, (len - 35) % 8);
        } else if (len <= 130) { (277 + ((len - 67) / 16), 4, (len - 67) % 16) } else if (len <= 257) {
          (281 + ((len - 131) / 32), 5, (len - 131) % 32);
        } else {
          // length == 258
          (285, 0, 0);
        };
      };
    };
  };

  // ── Distance encoding ──────────────────────────────────────────────────

  /// Returns ?(distance-code, extra-bit-count, extra-bit-value), or null for non-pointers.
  public func distanceCode(symbol : Symbol) : ?(Nat, Nat, Nat16) {
    switch symbol {
      case (#pointer(distance, _)) {
        if (distance == 0 or distance > MAX_DISTANCE) {
          Runtime.trap("Deflate: distance " # debug_show distance # " out of range");
        };
        if (distance <= 4) {
          ?(distance - 1, 0, 0);
        } else {
          var extra_bits = 1;
          var base = 4;
          var marker = 4;
          // Advance until 2*base >= distance
          while (base * 2 < distance) {
            extra_bits += 1;
            marker += 2;
            base *= 2;
          };
          // base < distance <= 2*base
          let half = base / 2;
          let delta = distance - base - 1; // always >= 0 (base < distance)
          let offset = Nat16.fromNat(delta % half);
          if (distance <= base + half) {
            ?(marker, extra_bits, offset);
          } else {
            ?(marker + 1, extra_bits, offset);
          };
        };
      };
      case (_) null;
    };
  };

  // ── Encoder class ──────────────────────────────────────────────────────

  public class Encoder(
    literal_encoder : HuffmanEncoder.Encoder,
    distance_encoder : HuffmanEncoder.Encoder,
  ) {
    public let literal = literal_encoder;
    public let distance = distance_encoder;

    /// Encode one symbol into `bitbuffer`.
    public func encode(bitbuffer : BitBuffer, symbol : Symbol) {
      let (marker, extra_bits, offset) = lengthCode(symbol);
      literal_encoder.encode(bitbuffer, Nat16.toNat(marker));
      if (extra_bits > 0) {
        bitbuffer.addBits(extra_bits, Nat16.toNat(offset));
      };
      switch (distanceCode(symbol)) {
        case (?(m, eb, off)) {
          distance_encoder.encode(bitbuffer, m);
          if (eb > 0) { bitbuffer.addBits(eb, Nat16.toNat(off)) };
        };
        case null {};
      };
    };
  };

  // ── Decoder tables ─────────────────────────────────────────────────────

  /// (base_length, extra_bits) indexed by length_code - 257.
  let LENGTH_TABLE : [(Nat, Nat)] = [
    (3, 0),
    (4, 0),
    (5, 0),
    (6, 0),
    (7, 0),
    (8, 0),
    (9, 0),
    (10, 0),
    (11, 1),
    (13, 1),
    (15, 1),
    (17, 1),
    (19, 2),
    (23, 2),
    (27, 2),
    (31, 2),
    (35, 3),
    (43, 3),
    (51, 3),
    (59, 3),
    (67, 4),
    (83, 4),
    (99, 4),
    (115, 4),
    (131, 5),
    (163, 5),
    (195, 5),
    (227, 5),
    (258, 0),
  ];

  /// (base_distance, extra_bits) indexed by distance_code.
  let DISTANCE_TABLE : [(Nat, Nat)] = [
    (1, 0),
    (2, 0),
    (3, 0),
    (4, 0),
    (5, 1),
    (7, 1),
    (9, 2),
    (13, 2),
    (17, 3),
    (25, 3),
    (33, 4),
    (49, 4),
    (65, 5),
    (97, 5),
    (129, 6),
    (193, 6),
    (257, 7),
    (385, 7),
    (513, 8),
    (769, 8),
    (1025, 9),
    (1537, 9),
    (2049, 10),
    (3073, 10),
    (4097, 11),
    (6145, 11),
    (8193, 12),
    (12_289, 12),
    (16_385, 13),
    (24_577, 13),
  ];

  // ── Decoder class ──────────────────────────────────────────────────────

  public class Decoder(
    literal_decoder : HuffmanDecoder.Decoder,
    distance_decoder : HuffmanDecoder.Decoder,
  ) {
    /// Decode one symbol from `reader`.
    public func decode(reader : BitReader) : Result<Symbol, Text> {
      let sym_res = decodeLiteral(reader);
      let #ok(sym) = sym_res else return sym_res;
      // If it's a pointer, the distance is still 0 — we need to decode it.
      switch sym {
        case (#pointer(_, length)) {
          switch (decodeDistance(reader)) {
            case (#ok(dist)) #ok(#pointer(dist, length));
            case (#err(msg)) #err(msg);
          };
        };
        case other #ok(other);
      };
    };

    func decodeLiteral(reader : BitReader) : Result<Symbol, Text> {
      let val = switch (literal_decoder.decode(reader)) {
        case (#ok(v)) v;
        case (#err(msg)) return #err(msg);
      };
      if (val <= 255) {
        #ok(#literal(Nat8.fromNat(val)));
      } else if (val == 256) {
        #ok(#EndOfBlock);
      } else if (val >= 286) {
        #err("Invalid deflate literal/length code " # debug_show val);
      } else {
        // val in [257, 285]
        let (base, extra_bits) = LENGTH_TABLE[val - 257];
        #ok(#pointer(0, base + reader.readBits(extra_bits)));
      };
    };

    func decodeDistance(reader : BitReader) : Result<Nat, Text> {
      let val = switch (distance_decoder.decode(reader)) {
        case (#ok(v)) v;
        case (#err(msg)) return #err(msg);
      };
      if (val >= DISTANCE_TABLE.size()) {
        return #err("Invalid deflate distance code " # debug_show val);
      };
      let (base, extra_bits) = DISTANCE_TABLE[val];
      #ok(base + reader.readBits(extra_bits));
    };
  };

};
