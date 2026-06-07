/// Deflate symbol types and helpers.
///
/// A `Symbol` is either a raw literal byte, a back-reference pointer, or the
/// special EndOfBlock marker (code 256).  The length/distance coding tables
/// follow RFC 1951.

import Nat8 "mo:core/Nat8";
import Nat16 "mo:core/Nat16";
import HuffmanEncoder "../Huffman/Encoder";
import BitBuffer "../internal/BitBuffer";
import CodeTables "CodeTables";

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

  // ── Encode helpers (oracle functions) ───────────────────────────────────
  //
  // These pure functions serve as independent test oracles for the CodeTables
  // equivalence suite and as helpers for `lengthMarker`/`distanceMarker`.
  // They cannot be replaced by table lookups at module scope — Motoko forbids
  // non-static expressions (loops, function calls) there; tables must be
  // built inside a class or function body.

  // Used by lengthMarker/distanceMarker and as independent CodeTables oracles.
  public func lenCode(length : Nat) : Nat {
    if (length <= 10) { 257 + (length - 3) } else if (length <= 18) {
      265 + (length - 11) / 2;
    } else if (length <= 34) { 269 + (length - 19) / 4 } else if (length <= 66) {
      273 + (length - 35) / 8;
    } else if (length <= 130) { 277 + (length - 67) / 16 } else if (length <= 257) {
      281 + (length - 131) / 32;
    } else { 285 } // length == 258
  };
  public func distCode(distance : Nat) : Nat {
    if (distance <= 4) { distance - 1 } else {
      var extra_bits = 1;
      var base = 4;
      var marker = 4;
      while (base * 2 < distance) { extra_bits += 1; marker += 2; base *= 2 };
      let half = base / 2;
      if (distance < base + half + 1) { marker } else { marker + 1 };
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
    let r = switch symbol {
      case (#EndOfBlock) 256;
      case (#literal(byte)) Nat8.toNat(byte);
      case (#pointer(_, length)) lenCode(length);
    };
    r;
  };

  /// Returns the distance code (0..29) for `symbol`, or `NO_DISTANCE` for
  /// non-pointer symbols.  No heap allocation.  Use for Huffman frequency
  /// counting and any code that needs only the code value.
  public func distanceMarker(symbol : Symbol) : Nat {
    let r = switch symbol {
      case (#pointer(distance, _)) distCode(distance);
      case _ NO_DISTANCE;
    };
    r;
  };

  // ── Encoder class ──────────────────────────────────────────────────────

  public class Encoder(
    literal_encoder : HuffmanEncoder.Encoder,
    distance_encoder : HuffmanEncoder.Encoder,
  ) {
    public let literal = literal_encoder;
    public let distance = distance_encoder;

    // Precomputed RFC 1951 length/distance code tables.
    let tables = CodeTables.CodeTables();

    /// Encode one symbol into `bitbuffer` using precomputed code tables.
    public func encode(bitbuffer : BitBuffer.BitBuffer, symbol : Symbol) {
      switch symbol {
        case (#EndOfBlock) {
          literal_encoder.encode(bitbuffer, 256);
        };
        case (#literal(byte)) {
          literal_encoder.encode(bitbuffer, Nat8.toNat(byte));
        };
        case (#pointer(distance, length)) {
          // ── Length code (O(1) table lookup) ──────────────────────────
          let lCode = tables.lengthCode[length - 3];
          literal_encoder.encode(bitbuffer, lCode);
          let lBits = tables.lengthExtraBits[length - 3];
          if (lBits > 0) {
            bitbuffer.addBits(lBits, tables.lengthExtraVal[length - 3]);
          };
          // ── Distance code (O(1) table lookup) ────────────────────────
          let dCode = tables.distCodeOf(distance);
          distance_encoder.encode(bitbuffer, dCode);
          let dBits = tables.distExtraBits[dCode];
          if (dBits > 0) {
            bitbuffer.addBits(dBits, distance - tables.distBase[dCode]);
          };
        };
      };
    };
  };

};
