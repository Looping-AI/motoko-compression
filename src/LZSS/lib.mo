/// Public facade for the LZSS compression module.
///
/// Phase D dropped the list-based `LzssEntry` API. Usage is now:
///
///   import LZSS "src/LZSS/lib";
///
///   // Encode via streaming callbacks (no per-symbol heap allocation).
///   let enc = LZSS.Encoder.Encoder(#best);
///   let sink : LZSS.MatchSink = {
///     onLiteral = func(b)        { /* ... */ };
///     onPointer = func(off, len) { /* ... */ };
///   };
///   enc.encode(bytes, sink);
///   enc.flush(sink);
///
///   // Decode by driving the Decoder methods directly.
///   let dec = LZSS.Decoder.Decoder();
///   let out = List.empty<Nat8>();
///   dec.literal(out, 0x41);
///   dec.pointer(out, 1, 5);

import EncoderModule "Encoder/lib";
import DecoderModule "Decoder";
import Common "Common";

module {

  // ── Re-exported types ───────────────────────────────────────────────────

  public type MatchSink = Common.MatchSink;
  public type CompressionLevel = Common.CompressionLevel;

  // ── Re-exported constants ───────────────────────────────────────────────

  public let MATCH_WINDOW_SIZE = Common.MATCH_WINDOW_SIZE;
  public let MATCH_MAX_SIZE = Common.MATCH_MAX_SIZE;

  // ── Re-exported sub-modules ─────────────────────────────────────────────

  public let Encoder = EncoderModule;
  public let Decoder = DecoderModule;

};
