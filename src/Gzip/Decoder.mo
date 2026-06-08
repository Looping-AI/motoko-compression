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
import List "mo:core/List";
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

    // Compressed input fragments collected by decode() calls.
    // We defer concatenation until start() so that no doubling reallocations
    // occur in BitBuffer while the caller feeds the stream in chunks.
    let chunks : List.List<[Nat8]> = List.empty();
    var totalBytes : Nat = 0;

    // ── In-progress streaming-decode state (set by start, used by step) ──────
    var header : ?Header.Header = null;
    var deflateState : ?DeflateDecoder.Decoder = null;
    var crcState : ?CRC32.CRC32 = null;
    var total : Nat = 0;
    var inputStore : ?[var Nat8] = null;
    var sliceStart : Nat = 0;
    var sliceLen : Nat = 0;
    var outCapHint : Nat = 0;

    // ── Public API ──────────────────────────────────────────────────────────

    /// Add compressed bytes to the internal buffer.
    ///
    /// Returns `#ok` always; errors are only surfaced by `start()`/`step()`.
    public func decode(bytes : [Nat8]) : Result<(), Text> {
      if (bytes.size() > 0) {
        List.add(chunks, bytes);
        totalBytes += bytes.size();
      };
      #ok();
    };

    /// Begin a streaming decode: parse the Gzip header and prepare the deflate
    /// decoder over the buffered input. Call once after feeding all input via
    /// `decode()`, then call `step()` repeatedly until it returns `#done`.
    public func start() : Result<Header.Header, Text> {
      // Build one BitReader from the accumulated fragments: one pre-sized
      // allocation + one sequential copy, no doubling reallocations.
      let reader = BitReader.BitReader(totalBytes);
      for (chunk in List.values(chunks)) {
        reader.addBytes(chunk);
      };
      // Fragments are fully copied; release them to allow GC.
      List.clear(chunks);
      totalBytes := 0;

      // 1. Decode the Gzip header.
      let parsedHeader = switch (Header.decode(reader)) {
        case (#err(msg)) return #err(msg);
        case (#ok(h)) h;
      };

      reader.clearRead();
      // Slice the deflate data (plus 8-byte footer) in place from the reader's
      // buffer instead of copying it into a fresh array. Valid because the gzip
      // header is byte-aligned, so the read position is on a byte boundary.
      let (rawStore, rawStart, rawLen) = reader.readableSlice();

      // 2. Pre-size the output buffer from the gzip ISIZE field (last 4 bytes,
      //    LE, = uncompressed size mod 2^32). The streaming cap is still applied
      //    inside the deflate decoder for large streams.
      let capHint : Nat = if (rawLen >= 4) {
        let isizeSlice = Array.tabulate<Nat8>(4, func(k) { rawStore[rawStart + rawLen - 4 + k] });
        Utils.leBytesToNat(isizeSlice);
      } else { 0 };

      header := ?parsedHeader;
      deflateState := ?DeflateDecoder.fromSlice(rawStore, rawStart, rawLen);
      crcState := ?CRC32.CRC32();
      total := 0;
      inputStore := ?rawStore;
      sliceStart := rawStart;
      sliceLen := rawLen;
      outCapHint := capHint;
      #ok(parsedHeader);
    };

    /// Decompress at most `maxOutBytes` of output, delivering it to `consume`
    /// in bounded chunks, then return `#more` (call again) or `#done` with the
    /// verified `StreamedSummary`. CRC32 and ISIZE are verified incrementally;
    /// on `#done` the footer is checked and the decoder is reset via `clear()`.
    /// Must be preceded by `start()`.
    public func step(maxOutBytes : Nat, consume : ([Nat8]) -> ()) : Result<{ #more; #done : StreamedSummary }, Text> {
      let ?deflate = deflateState else {
        return #err("Gzip.Decoder.step: call start() first");
      };
      let ?crc = crcState else {
        return #err("Gzip.Decoder.step: call start() first");
      };

      let sink = func(chunk : [Nat8]) {
        crc.update(chunk);
        total += chunk.size();
        consume(chunk);
      };

      switch (deflate.decodeBounded(outCapHint, maxOutBytes, sink)) {
        case (#err(msg)) {
          return #err(msg);
        };
        case (#ok(#more)) {
          return #ok(#more);
        };
        case (#ok(#done)) {};
      };

      // Deflate is complete — verify the Gzip footer (8 bytes) that follows.
      let store = switch (inputStore) {
        case (?s) s;
        case null {
          return #err("Gzip.Decoder.step: missing input slice");
        };
      };
      let start = sliceStart;
      let len = sliceLen;
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
      let actual_isize = total % 4294967296;
      if (stored_isize != actual_isize) {
        return #err(
          "Gzip: ISIZE mismatch — stored "
          # debug_show stored_isize
          # ", computed "
          # debug_show actual_isize
        );
      };

      let parsedHeader = switch (header) {
        case (?h) h;
        case null {
          return #err("Gzip.Decoder.step: missing header");
        };
      };
      let summary : StreamedSummary = {
        header = parsedHeader;
        size = total;
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
      List.clear(chunks);
      totalBytes := 0;
      header := null;
      deflateState := null;
      crcState := null;
      total := 0;
      inputStore := null;
      sliceStart := 0;
      sliceLen := 0;
      outCapHint := 0;
    };
  };

};
