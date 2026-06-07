/// Gzip decoder — RFC 1952.
///
/// Usage:
///   1. Call `decode(bytes)` one or more times to feed compressed data.
///   2. Call `finishStreaming(consume)` to decompress and verify the stream,
///      receiving output in bounded chunks via the `consume` callback.
///
/// `decode()` only accumulates bytes; all decompression work happens in
/// `finishStreaming()`.  This avoids partial-block reads that would trap in BitReader.

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

  /// Returned by `Decoder.finishStreaming()` on success. Carries the header and
  /// verified decoded-stream metadata, but not the bytes themselves — those are
  /// delivered incrementally through the caller's `consume` callback.
  public type StreamedSummary = {
    header : Header.Header;
    size : Nat;
    crc32 : Nat32;
  };

  // ── Decoder class ─────────────────────────────────────────────────────────

  /// Stateful Gzip decoder.
  ///
  /// The decoder accumulates compressed input across multiple `decode()` calls;
  /// `finishStreaming()` performs the actual decompression and footer verification.
  public class Decoder() {

    let reader = BitReader.BitReader();

    // ── In-progress streaming-decode state (set by start, used by step) ──────
    var header_ : ?Header.Header = null;
    var deflate_ : ?DeflateDecoder.Decoder = null;
    var crc_ : ?CRC32.CRC32 = null;
    var total_ : Nat = 0;
    var store_ : ?[var Nat8] = null;
    var sliceStart_ : Nat = 0;
    var sliceLen_ : Nat = 0;
    var outCapHint_ : Nat = 0;

    // ── Public API ──────────────────────────────────────────────────────────

    /// Add compressed bytes to the internal buffer.
    ///
    /// Returns `#ok` always; errors are only surfaced by `start()`/`step()`.
    public func decode(bytes : [Nat8]) : Result<(), Text> {
      reader.addBytes(bytes);
      #ok();
    };

    /// Begin a streaming decode: parse the Gzip header and prepare the deflate
    /// decoder over the buffered input. Call once after feeding all input via
    /// `decode()`, then call `step()` repeatedly until it returns `#done`.
    public func start() : Result<Header.Header, Text> {
      // 1. Decode the Gzip header.
      let header = switch (Header.decode(reader)) {
        case (#err(msg)) return #err(msg);
        case (#ok(h)) h;
      };

      reader.clearRead();
      // Slice the deflate data (plus 8-byte footer) in place from the reader's
      // buffer instead of copying it into a fresh array. Valid because the gzip
      // header is byte-aligned, so the read position is on a byte boundary.
      let (store, start, len) = reader.readableSlice();

      // 2. Pre-size the output buffer from the gzip ISIZE field (last 4 bytes,
      //    LE, = uncompressed size mod 2^32). The streaming cap is still applied
      //    inside the deflate decoder for large streams.
      let outCapHint : Nat = if (len >= 4) {
        let isizeSlice = Array.tabulate<Nat8>(4, func(k) { store[start + len - 4 + k] });
        Utils.leBytesToNat(isizeSlice);
      } else { 0 };

      header_ := ?header;
      deflate_ := ?DeflateDecoder.fromSlice(store, start, len);
      crc_ := ?CRC32.CRC32();
      total_ := 0;
      store_ := ?store;
      sliceStart_ := start;
      sliceLen_ := len;
      outCapHint_ := outCapHint;
      #ok(header);
    };

    /// Decompress at most `maxOutBytes` of output, delivering it to `consume`
    /// in bounded chunks, then return `#more` (call again) or `#done` with the
    /// verified `StreamedSummary`. CRC32 and ISIZE are verified incrementally;
    /// on `#done` the footer is checked and the decoder is reset via `clear()`.
    /// Must be preceded by `start()`.
    public func step(maxOutBytes : Nat, consume : ([Nat8]) -> ()) : Result<{ #more; #done : StreamedSummary }, Text> {
      let ?deflate = (deflate_) else {
        return #err("Gzip.Decoder.step: call start() first");
      };
      let ?crc = (crc_) else {
        return #err("Gzip.Decoder.step: call start() first");
      };

      let sink = func(chunk : [Nat8]) {
        crc.update(chunk);
        total_ += chunk.size();
        consume(chunk);
      };

      switch (deflate.decodeBounded(outCapHint_, maxOutBytes, sink)) {
        case (#err(msg)) {
          return #err(msg);
        };
        case (#ok(#more)) {
          return #ok(#more);
        };
        case (#ok(#done)) {};
      };

      // Deflate is complete — verify the Gzip footer (8 bytes) that follows.
      let store = switch (store_) {
        case (?s) s;
        case null {
          return #err("Gzip.Decoder.step: missing input slice");
        };
      };
      let start = sliceStart_;
      let len = sliceLen_;
      let c = deflate.bytesConsumed();
      if (c + 8 > len) {
        return #err("Gzip: stream truncated — no footer");
      };

      // Verify CRC32 (4 bytes, LE).
      let crcSlice = Array.tabulate<Nat8>(4, func(k) { store[start + c + k] });
      let stored_crc32 = Nat32.fromNat(Utils.leBytesToNat(crcSlice));
      let actual_crc32 = crc.finish();
      if (stored_crc32 != actual_crc32) {
        return #err(
          "Gzip: CRC32 mismatch — stored "
          # debug_show stored_crc32
          # ", computed "
          # debug_show actual_crc32
        );
      };

      // Verify ISIZE (4 bytes, LE, mod 2^32).
      let isizeSlice = Array.tabulate<Nat8>(4, func(k) { store[start + c + 4 + k] });
      let stored_isize = Utils.leBytesToNat(isizeSlice);
      let actual_isize = total_ % 4294967296;
      if (stored_isize != actual_isize) {
        return #err(
          "Gzip: ISIZE mismatch — stored "
          # debug_show stored_isize
          # ", computed "
          # debug_show actual_isize
        );
      };

      let header = switch (header_) {
        case (?h) h;
        case null {
          return #err("Gzip.Decoder.step: missing header");
        };
      };
      let summary : StreamedSummary = {
        header;
        size = total_;
        crc32 = actual_crc32;
      };
      clear();

      #ok(#done(summary));
    };

    /// Decompress and deliver the decoded output to `consume` in bounded chunks,
    /// never materialising the full output array. CRC32 and ISIZE are verified
    /// incrementally as chunks are produced. Returns the header plus the
    /// verified decoded size and CRC32.
    ///
    /// One-shot wrapper that drives `start()` + `step()` to completion; use the
    /// `start`/`step` pair directly to spread decoding across messages.
    /// Calls `clear()` on success before returning.
    public func finishStreaming(consume : ([Nat8]) -> ()) : Result<StreamedSummary, Text> {
      switch (start()) {
        case (#err(msg)) return #err(msg);
        case (#ok(_)) {};
      };
      // A large per-step budget so the whole stream decodes in one driving loop.
      let WHOLE : Nat = 0xFFFF_FFFF_FFFF;
      loop {
        switch (step(WHOLE, consume)) {
          case (#err(msg)) return #err(msg);
          case (#ok(#more)) {};
          case (#ok(#done(summary))) return #ok(summary);
        };
      };
    };

    /// Reset the decoder state so it can be reused for a new stream.
    public func clear() {
      reader.clear();
      header_ := null;
      deflate_ := null;
      crc_ := null;
      total_ := 0;
      store_ := null;
      sliceStart_ := 0;
      sliceLen_ := 0;
      outCapHint_ := 0;
    };
  };

};
