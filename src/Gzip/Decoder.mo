/// Gzip decoder — RFC 1952.
///
/// Usage:
///   1. Call `decode(bytes)` one or more times to feed compressed data.
///   2. Call `finish()` to decompress and verify the stream.
///      Output accumulates internally; read it via `decompressed()` or `chunks()`.
///
/// `decode()` only accumulates bytes; all decompression work happens in
/// `finish()`.  This avoids partial-block reads that would trap in BitReader.

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

  // ── Decoder class ─────────────────────────────────────────────────────────

  /// Stateful Gzip decoder.
  ///
  /// The decoder accumulates compressed input across multiple `decode()` calls;
  /// `finish()` performs the actual decompression and footer verification.
  /// Decompressed output accumulates internally; read it via `decompressed()`
  /// or `chunks()` after `finish()` (or after each `step()` call).
  public class Decoder() {

    // Compressed input fragments collected by decode() calls.
    // We defer concatenation until start() so that no doubling reallocations
    // occur in BitBuffer while the caller feeds the stream in chunks.
    let inputChunks : List.List<[Nat8]> = List.empty();
    var totalBytes : Nat = 0;

    // Default after performance testing.
    // Giving ~25B instructions per 21 MiB chunk with standard parameters.
    let DECODE_OUTPUT_BUDGET : Nat = 21 * 1024 * 1024;

    // Decompressed output accumulated across step() calls.
    let decompressedChunks : List.List<[Nat8]> = List.empty();

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
    /// Errors are only surfaced by `start()`/`step()`.
    public func decode(bytes : [Nat8]) {
      if (bytes.size() > 0) {
        List.add(inputChunks, bytes);
        totalBytes += bytes.size();
      };
    };

    /// Begin a streaming decode: parse the Gzip header and prepare the deflate
    /// decoder over the buffered input. Call once after feeding all input via
    /// `decode()`, then call `step()` repeatedly until it returns `#done`.
    public func start() : Result<Header.Header, Text> {
      // Build one BitReader from the accumulated fragments: one pre-sized
      // allocation + one sequential copy, no doubling reallocations.
      let reader = BitReader.BitReader(totalBytes);
      for (chunk in List.values(inputChunks)) {
        reader.addBytes(chunk);
      };
      // Fragments are fully copied; release them to allow GC.
      List.clear(inputChunks);
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

    /// Decompress at most `budget` bytes of output, accumulating it internally,
    /// then return `#more` (call again) or `#done` when decompression is complete.
    /// Pass `#default` to use the internal default (initially 21 MiB).
    /// CRC32 and ISIZE are verified; on `#done` the streaming state is reset
    /// (but decompressed output is kept until `clear()` is called).
    /// Must be preceded by `start()`.
    public func step(budget : { #default; #custom : Nat }) : Result<{ #more; #done }, Text> {
      let limit = switch (budget) {
        case (#default) DECODE_OUTPUT_BUDGET;
        case (#custom n) n;
      };
      let ?deflate = deflateState else {
        return #err("Gzip.Decoder.step: call start() first");
      };
      let ?crc = crcState else {
        return #err("Gzip.Decoder.step: call start() first");
      };

      let sink = func(chunk : [Nat8]) {
        crc.update(chunk);
        total += chunk.size();
        List.add(decompressedChunks, chunk);
      };

      switch (deflate.decodeBounded(outCapHint, limit, sink)) {
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
      let storedCrc32 = Nat32.fromNat(Utils.leBytesToNat(crcSlice));
      let actualCrc32 = crc.finish();
      if (storedCrc32 != actualCrc32) {
        return #err(
          "Gzip: CRC32 mismatch — stored "
          # debug_show storedCrc32
          # ", computed "
          # debug_show actualCrc32
        );
      };

      // Verify ISIZE (4 bytes, LE, mod 2^32).
      let isizeSlice = Array.tabulate<Nat8>(4, func(k) { store[start + c + 4 + k] });
      let storedIsize = Utils.leBytesToNat(isizeSlice);
      let actualIsize = total % 4294967296;
      if (storedIsize != actualIsize) {
        return #err(
          "Gzip: ISIZE mismatch — stored "
          # debug_show storedIsize
          # ", computed "
          # debug_show actualIsize
        );
      };

      // Reset streaming state; decompressed output remains readable via
      // decompressed() / chunks() until clear() is called.
      header := null;
      deflateState := null;
      crcState := null;
      inputStore := null;
      sliceStart := 0;
      sliceLen := 0;
      outCapHint := 0;

      #ok(#done);
    };

    /// Decompress the buffered input in one shot, accumulating output internally.
    /// CRC32 and ISIZE are verified. Read result via `decompressed()` or `chunks()`.
    ///
    /// One-shot wrapper that drives `start()` + `step()` to completion; use the
    /// `start`/`step` pair directly to spread decoding across messages.
    public func finish() : Result<(), Text> {
      switch (start()) {
        case (#err(msg)) return #err(msg);
        case (#ok(_)) {};
      };
      // A large per-step budget so the whole stream decodes in one driving loop.
      loop {
        switch (step(#custom(0xFFFF_FFFF_FFFF))) {
          case (#err(msg)) return #err(msg);
          case (#ok(#more)) {};
          case (#ok(#done)) return #ok(());
        };
      };
    };

    /// Return all decompressed output as a single flat array.
    /// Allocates a new array — prefer `chunks()` when only iteration is needed.
    public func decompressed() : [Nat8] {
      let n = List.size(decompressedChunks);
      if (n == 0) return [];
      if (n == 1) return List.get(decompressedChunks, 0) ??[];
      Array.flatten(List.toArray(decompressedChunks));
    };

    /// Return the raw decompressed output chunks without merging them.
    public func chunks() : [[Nat8]] {
      List.toArray(decompressedChunks);
    };

    /// Total decompressed bytes accumulated so far (useful for progress tracking
    /// across multiple `step()` calls before the final `#done`).
    public func decompressedSize() : Nat { total };

    /// Reset the decoder state so it can be reused for a new stream.
    public func clear() {
      List.clear(inputChunks);
      totalBytes := 0;
      List.clear(decompressedChunks);
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
