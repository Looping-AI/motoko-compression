/// Gzip decoder — RFC 1952.
///
/// Usage:
///   1. Call `decode(bytes)` one or more times to feed compressed data.
///   2. Call `finish()` to decompress and verify the stream.
///
/// `decode()` only accumulates bytes; all decompression work happens in
/// `finish()`.  This avoids partial-block reads that would trap in BitReader.

import List "mo:core/List";
import Nat32 "mo:core/Nat32";
import Result "mo:core/Result";

import BitReader "../BitReader";
import CRC32 "../internal/CRC32";
import DeflateDecoder "../Deflate/Decoder";
import Header "Header";
import Utils "../utils";

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
    let buffer = List.empty<Nat8>();
    let deflate = DeflateDecoder.Decoder(reader, ?buffer);

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
      // 1. Decode the Gzip header
      let header = switch (Header.decode(reader)) {
        case (#err(msg)) return #err(msg);
        case (#ok(h)) h;
      };

      // Free the header bytes from the reader buffer
      reader.clearRead();

      // 2. Deflate-decompress the payload
      switch (deflate.decode()) {
        case (#err(msg)) return #err(msg);
        case (#ok(_)) {};
      };

      // 3. Byte-align to reach the Gzip footer
      reader.byteAlign();

      // 4. Read and verify CRC32 (4 bytes, LE)
      let stored_crc32 = Nat32.fromNat(Utils.leBytesToNat(reader.readBytes(4)));
      let actual_crc32 = CRC32.checksum(List.toArray(buffer));
      if (stored_crc32 != actual_crc32) {
        return #err(
          "Gzip: CRC32 mismatch — stored "
          # debug_show stored_crc32
          # ", computed "
          # debug_show actual_crc32
        );
      };

      // 5. Read and verify ISIZE (4 bytes, LE, mod 2^32)
      let stored_isize = Utils.leBytesToNat(reader.readBytes(4));
      let actual_isize = List.size(buffer) % 4294967296;
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
        bytes = List.toArray(buffer);
      };

      clear();
      #ok(result);
    };

    /// Reset the decoder state so it can be reused for a new stream.
    public func clear() {
      reader.reset();
      List.clear(buffer);
    };
  };

};
