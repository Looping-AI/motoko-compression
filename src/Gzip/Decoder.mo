/// Gzip decoder — RFC 1952.
///
/// Usage:
///   1. Call `decode(bytes)` one or more times to feed compressed data.
///   2. Call `finish()` to decompress and verify the stream.
///
/// `decode()` only accumulates bytes; all decompression work happens in
/// `finish()`.  This avoids partial-block reads that would trap in BitReader.

import Array "mo:core/Array";
import Nat32 "mo:core/Nat32";
import Result "mo:core/Result";

import BitReader "../internal/BitReader";
import CRC32 "../internal/CRC32";
import DeflateDecoder "../Deflate/Decoder";
import Header "Header";
import Utils "../internal/utils";

module {

  type Result<A, B> = Result.Result<A, B>;

  // ── Public types ─────────────────────────────────────────────────────────

  /// Returned by `Decoder.finish()` on success.
  public type DecodedResponse = {
    header : Header.Header;
    bytes : [Nat8];
  };

  // ── Decoder class ─────────────────────────────────────────────────────────

  /// Stateful Gzip decoder.
  ///
  /// The decoder accumulates compressed input across multiple `decode()` calls;
  /// `finish()` performs the actual decompression and footer verification.
  public class Decoder() {

    let reader = BitReader.BitReader();

    // ── Public API ──────────────────────────────────────────────────────────

    /// Add compressed bytes to the internal buffer.
    ///
    /// Returns `#ok` always; errors are only surfaced by `finish()`.
    public func decode(bytes : [Nat8]) : Result<(), Text> {
      reader.addBytes(bytes);
      #ok();
    };

    /// Decompress all accumulated bytes and verify the Gzip footer.
    ///
    /// Calls `clear()` on success before returning.
    public func finish() : Result<DecodedResponse, Text> {
      // 1. Decode the Gzip header (uses BitReader for existing Header.decode API).
      let header = switch (Header.decode(reader)) {
        case (#err(msg)) return #err(msg);
        case (#ok(h)) h;
      };

      // Drop the consumed header bytes; remaining bytes = deflate payload + footer.
      reader.clearRead();
      let remaining = reader.readBytes(reader.byteSize());

      // 2. Deflate-decompress the payload.
      let deflate = DeflateDecoder.Decoder(remaining);
      let decodedBytes = switch (deflate.decode()) {
        case (#err(msg)) return #err(msg);
        case (#ok(b)) b;
      };

      // 3. Locate the Gzip footer (8 bytes) immediately after the deflate data.
      let c = deflate.bytesConsumed();
      if (c + 8 > remaining.size()) {
        return #err("Gzip: stream truncated — no footer");
      };

      // 4. Verify CRC32 (4 bytes, LE).
      let crcSlice = Array.tabulate<Nat8>(4, func(k) { remaining[c + k] });
      let stored_crc32 = Nat32.fromNat(Utils.leBytesToNat(crcSlice));
      let actual_crc32 = CRC32.checksum(decodedBytes);
      if (stored_crc32 != actual_crc32) {
        return #err(
          "Gzip: CRC32 mismatch — stored "
          # debug_show stored_crc32
          # ", computed "
          # debug_show actual_crc32
        );
      };

      // 5. Verify ISIZE (4 bytes, LE, mod 2^32).
      let isizeSlice = Array.tabulate<Nat8>(4, func(k) { remaining[c + 4 + k] });
      let stored_isize = Utils.leBytesToNat(isizeSlice);
      let actual_isize = decodedBytes.size() % 4294967296;
      if (stored_isize != actual_isize) {
        return #err(
          "Gzip: ISIZE mismatch — stored "
          # debug_show stored_isize
          # ", computed "
          # debug_show actual_isize
        );
      };

      let result : DecodedResponse = {
        header;
        bytes = decodedBytes;
      };

      clear();
      #ok(result);
    };

    /// Reset the decoder state so it can be reused for a new stream.
    public func clear() {
      reader.clear();
    };
  };

};
