/// Deflate symbol types and helpers.
///
/// A `Symbol` is either a raw literal byte, a back-reference pointer, or the
/// special EndOfBlock marker (code 256).  The length/distance coding tables
/// follow RFC 1951.

import Nat8 "mo:core/Nat8";
import Nat16 "mo:core/Nat16";
import HuffmanEncoder "../Huffman/Encoder";
import BitBuffer "../internal/BitBuffer";

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

  // ── Encode helpers (private) ─────────────────────────────────────────────
  //
  // Motoko modules only allow purely static top-level `let` bindings
  // (array literals, func definitions, etc.) — no `var`, loops, or function
  // applications are permitted at module scope.  The encode logic is
  // therefore expressed as private functions.  The hot Encoder.encode path
  // fully inlines the equivalent code with local `var` variables.

  // Helpers used by lengthMarker/distanceMarker and the inlined Encoder.encode.
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
    return r;
  };

  /// Returns the distance code (0..29) for `symbol`, or `NO_DISTANCE` for
  /// non-pointer symbols.  No heap allocation.  Use for Huffman frequency
  /// counting and any code that needs only the code value.
  public func distanceMarker(symbol : Symbol) : Nat {
    let r = switch symbol {
      case (#pointer(distance, _)) distCode(distance);
      case _ NO_DISTANCE;
    };
    return r;
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

};
