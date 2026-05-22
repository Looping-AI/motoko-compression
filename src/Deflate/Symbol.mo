/// Deflate symbol types and helpers.
///
/// A `Symbol` is either a raw literal byte, a back-reference pointer, or the
/// special EndOfBlock marker (code 256).  The length/distance coding tables
/// follow RFC 1951.

import Nat8 "mo:core/Nat8";
import Nat16 "mo:core/Nat16";
import Result "mo:core/Result";
import HuffmanEncoder "../Huffman/Encoder";
import HuffmanDecoder "../Huffman/Decoder";
import BitBuffer "../internal/BitBuffer";
import BitReader "../internal/BitReader";

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

  public let MAX_DISTANCE : Nat = 32_768;

  // ── Decoder tables (RFC 1951) ──────────────────────────────────────────

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

  // ── Encode helpers (private) ─────────────────────────────────────────────
  //
  // Motoko modules only allow purely static top-level `let` bindings
  // (array literals, func definitions, etc.) — no `var`, loops, or function
  // applications are permitted at module scope.  The encode logic is
  // therefore expressed as private functions.  The hot Encoder.encode path
  // fully inlines the equivalent code with local `var` variables.

  // Helpers used by lengthMarker/distanceMarker and the inlined Encoder.encode.
  func lenCode(length : Nat) : Nat {
    if (length <= 10) { 257 + (length - 3) } else if (length <= 18) {
      265 + (length - 11) / 2;
    } else if (length <= 34) { 269 + (length - 19) / 4 } else if (length <= 66) {
      273 + (length - 35) / 8;
    } else if (length <= 130) { 277 + (length - 67) / 16 } else if (length <= 257) {
      281 + (length - 131) / 32;
    } else { 285 } // length == 258
  };
  func lenExtraBits(length : Nat) : Nat {
    if (length <= 10 or length == 258) { 0 } else if (length <= 18) { 1 } else if (length <= 34) {
      2;
    } else if (length <= 66) { 3 } else if (length <= 130) { 4 } else { 5 };
  };
  func lenExtra(length : Nat) : Nat {
    if (length <= 10 or length == 258) { 0 } else if (length <= 18) {
      (length - 11) % 2;
    } else if (length <= 34) { (length - 19) % 4 } else if (length <= 66) {
      (length - 35) % 8;
    } else if (length <= 130) { (length - 67) % 16 } else {
      (length - 131) % 32;
    };
  };

  func distCode(distance : Nat) : Nat {
    if (distance <= 4) { distance - 1 } else {
      var extra_bits = 1;
      var base = 4;
      var marker = 4;
      while (base * 2 < distance) { extra_bits += 1; marker += 2; base *= 2 };
      let half = base / 2;
      if (distance < base + half + 1) { marker } else { marker + 1 };
    };
  };
  func distExtraBits(distance : Nat) : Nat {
    if (distance <= 4) { 0 } else {
      var extra_bits = 1;
      var base = 4;
      while (base * 2 < distance) { extra_bits += 1; base *= 2 };
      extra_bits;
    };
  };
  func distExtra(distance : Nat) : Nat {
    if (distance <= 4) { 0 } else {
      var base = 4;
      while (base * 2 < distance) { base *= 2 };
      let half = base / 2;
      (distance - base - 1) % half;
    };
  };

  // ── Scalar marker helpers (no tuple, no heap allocation) ──────────────

  /// Sentinel returned by `distanceMarker` for non-pointer symbols.
  /// Distance codes are 0..29, so 30 is always out of the valid range.
  public let NO_DISTANCE : Nat = 30;

  /// Returns the literal/length code (0..285) for `symbol` as a plain `Nat`.
  /// No heap allocation. Use for Huffman frequency counting and any code
  /// that needs only the code value without extra-bits metadata.
  public func lengthMarker(symbol : Symbol) : Nat {
    switch symbol {
      case (#EndOfBlock) 256;
      case (#literal(byte)) Nat8.toNat(byte);
      case (#pointer(_, length)) lenCode(length);
    };
  };

  /// Returns the distance code (0..29) for `symbol`, or `NO_DISTANCE` for
  /// non-pointer symbols.  No heap allocation.  Use for Huffman frequency
  /// counting and any code that needs only the code value.
  public func distanceMarker(symbol : Symbol) : Nat {
    switch symbol {
      case (#pointer(distance, _)) distCode(distance);
      case _ NO_DISTANCE;
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
    ///
    /// Hot path: length and distance encoding is fully inlined — no tuple
    /// allocation per symbol.  Length uses an if/else chain; distance uses a
    /// single while-loop with local `var` accumulators.
    public func encode(bitbuffer : BitBuffer.BitBuffer, symbol : Symbol) {
      switch symbol {
        case (#EndOfBlock) {
          literal_encoder.encode(bitbuffer, 256);
        };
        case (#literal(byte)) {
          literal_encoder.encode(bitbuffer, Nat8.toNat(byte));
        };
        case (#pointer(distance, length)) {
          // ── Length code (O(1) if/else, no heap) ────────────────────────
          var lCode : Nat = 0;
          var lBits : Nat = 0;
          var lVal : Nat = 0;
          if (length <= 10) {
            lCode := 257 + (length - 3);
          } else if (length <= 18) {
            lCode := 265 + (length - 11) / 2;
            lBits := 1;
            lVal := (length - 11) % 2;
          } else if (length <= 34) {
            lCode := 269 + (length - 19) / 4;
            lBits := 2;
            lVal := (length - 19) % 4;
          } else if (length <= 66) {
            lCode := 273 + (length - 35) / 8;
            lBits := 3;
            lVal := (length - 35) % 8;
          } else if (length <= 130) {
            lCode := 277 + (length - 67) / 16;
            lBits := 4;
            lVal := (length - 67) % 16;
          } else if (length < 258) {
            lCode := 281 + (length - 131) / 32;
            lBits := 5;
            lVal := (length - 131) % 32;
          } else {
            lCode := 285; // length == 258, no extra bits
          };
          literal_encoder.encode(bitbuffer, lCode);
          if (lBits > 0) { bitbuffer.addBits(lBits, lVal) };
          // ── Distance code (O(log₂ d) loop, no heap) ───────────────────
          if (distance <= 4) {
            distance_encoder.encode(bitbuffer, distance - 1);
          } else {
            var dBits = 1;
            var dBase = 4;
            while (dBase * 2 < distance) { dBits += 1; dBase *= 2 };
            // After loop: dBase < distance ≤ 2*dBase
            let dHalf = dBase / 2;
            distance_encoder.encode(bitbuffer, 2 * dBits + 2 + (if (distance < dBase + dHalf + 1) 0 else 1));
            if (dBits > 0) {
              bitbuffer.addBits(dBits, (distance - dBase - 1) % dHalf);
            };
          };
        };
      };
    };
  };

  // ── Decoder class ──────────────────────────────────────────────────────

  public class Decoder(
    literal_decoder : HuffmanDecoder.Decoder,
    distance_decoder : HuffmanDecoder.Decoder,
  ) {
    /// Decode one symbol from `reader`.
    public func decode(reader : BitReader.BitReader) : Result.Result<Symbol, Text> {
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

    func decodeLiteral(reader : BitReader.BitReader) : Result.Result<Symbol, Text> {
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

    func decodeDistance(reader : BitReader.BitReader) : Result.Result<Nat, Text> {
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
