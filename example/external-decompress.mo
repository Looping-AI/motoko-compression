/// Example: interoperability test canister.
///
/// Receives externally-compressed gzip data (e.g. from node:zlib, pako, or
/// any standard gzip producer), decompresses it using the motoko-gzip
/// library, and returns the original bytes — proving round-trip compatibility
/// with foreign gzip implementations.
///
/// Supports payloads up to ≤ 21 MiB compressed (fits within the per-message
/// instruction budget for a single `decompress()` call).
/// For larger payloads, check the other examples and their use of timers
/// to spread work across multiple messages.
///
/// Usage:
///   1. Call `appendExternalCompressed(chunk)` one or more times (≤ 21 MiB total compressed).
///   2. Call `decompress()` to decompress and cache the result.
///   3. Call `getDecompressedData(page)` to read the result in 2 MiB pages.
///   4. Call `clear()` to reset for the next test run.
import Array "mo:core/Array";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Runtime "mo:core/Runtime";
import Gzip "../src/Gzip/lib";

shared ({ caller = _owner }) persistent actor class ExternalDecompress() {

  // ── Constants ─────────────────────────────────────────────────────────────

  transient let MB = 1_024 * 1_024;
  transient let PAGE_SIZE : Nat = 2 * MB - 512;

  // ── Stable state ──────────────────────────────────────────────────────────

  /// Accumulated compressed chunks uploaded via appendExternalCompressed.
  /// List gives O(1) append vs the O(N²) Array.concat pattern.
  let chunks = List.empty<[Nat8]>();
  var decompressed : [Nat8] = [];

  // ── Transient state ───────────────────────────────────────────────────────

  transient let gzipDecoder = Gzip.Decoder();

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// Return up to PAGE_SIZE bytes at index `page` (2 MiB pages, 0-indexed).
  /// Returns [] when `page` is past the end of `data`.
  func pageOf(data : [Nat8], page : Nat) : [Nat8] {
    let lo = page * PAGE_SIZE;
    let n = data.size();
    if (lo >= n) return [];
    let hi = Nat.min(lo + PAGE_SIZE, n);
    Array.tabulate<Nat8>(hi - lo, func(i) { data[lo + i] });
  };

  // ── Public API ────────────────────────────────────────────────────────────

  /// Append one chunk of externally-compressed gzip bytes.
  /// Call repeatedly to upload large payloads in ≤1 MB pieces.
  public func appendExternalCompressed(chunk : [Nat8]) : async () {
    List.add(chunks, chunk);
  };

  /// Reset the compressed buffer, decompressed cache, and decoder state for a fresh run.
  public shared func clear() : async () {
    List.clear(chunks);
    decompressed := [];
    gzipDecoder.clear();
  };

  /// Return the number of bytes accumulated so far (query — no state change).
  public query func compressedSize() : async Nat {
    var total = 0;
    for (chunk in List.values(chunks)) { total += chunk.size() };
    total;
  };

  /// Decompress all accumulated chunks and cache the result in decompressed.
  /// Supports payloads up to ≤ 21 MiB compressed (single-message instruction budget).
  public func decompress() : async () {
    gzipDecoder.clear();
    for (chunk in List.values(chunks)) { gzipDecoder.decode(chunk) };
    switch (gzipDecoder.finish()) {
      case (#err msg) Runtime.trap("decompress: " # msg);
      case (#ok _) decompressed := gzipDecoder.decompressed();
    };
    gzipDecoder.clear();
  };

  /// Return a 2 MiB page of the decompressed bytes (0-indexed).
  /// Returns [] when `page` is past the end or decompress() has not been called.
  public query func getDecompressedData(page : Nat) : async [Nat8] {
    pageOf(decompressed, page);
  };

};
