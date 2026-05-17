/// Public facade for the LZSS compression module.
///
/// Usage:
///   import LZSS "src/LZSS/lib";
///
///   let encoded : List.List<LZSS.LzssEntry> = LZSS.encode(bytes);
///   let decoded : List.List<Nat8>           = LZSS.decode(encoded);

import List "mo:core/List";
import EncoderModule "Encoder/lib";
import DecoderModule "Decoder";
import Common "Common";

module {

  // ── Re-exported types ───────────────────────────────────────────────────

  public type LzssEntry        = Common.LzssEntry;
  public type CompressionLevel = Common.CompressionLevel;

  // ── Re-exported constants ───────────────────────────────────────────────

  public let MATCH_WINDOW_SIZE = Common.MATCH_WINDOW_SIZE;
  public let MATCH_MAX_SIZE    = Common.MATCH_MAX_SIZE;

  // ── Re-exported classes ─────────────────────────────────────────────────

  public let Encoder = EncoderModule;
  public let Decoder = DecoderModule;

  // ── Convenience functions ───────────────────────────────────────────────

  /// Encode `bytes` at the best compression level.
  /// Returns a list of `LzssEntry` values (literals and back-references).
  public func encode(bytes : [Nat8]) : List.List<LzssEntry> {
    EncoderModule.encode(bytes)
  };

  /// Decode a list of LZSS entries back to the original byte sequence.
  public func decode(entries : List.List<LzssEntry>) : List.List<Nat8> {
    DecoderModule.decode(entries)
  };

}
