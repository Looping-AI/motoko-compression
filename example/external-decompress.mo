/// Example: interoperability test canister.
///
/// Receives externally-compressed gzip data (e.g. from node:zlib, pako, or
/// any standard gzip producer), decompresses it using the motoko-compression
/// library, and returns the original bytes — proving round-trip compatibility
/// with foreign gzip implementations.
///
/// Usage:
///   1. Call `append_external_compressed(chunk)` one or more times to upload
///      the compressed payload in ≤1 MB chunks.
///   2. Call `decompress()` to decompress and cache the result.
///   3. Call `get_decompressed_data(page)` to read the result in 2 MiB pages.
///   4. Call `clear()` to reset for the next test run.
import Array "mo:core/Array";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Principal "mo:core/Principal";
import Runtime "mo:core/Runtime";
import Gzip "../src/Gzip/lib";

shared ({ caller = _owner }) persistent actor class ExternalDecompress() = self {

  // ── Constants ─────────────────────────────────────────────────────────────

  transient let MB = 1_024 * 1_024;
  transient let PAGE_SIZE : Nat = 2 * MB - 512;

  /// Upload chunks to batch per self-call during decompress().
  /// Each chunk is ≤1 MB, so 3 chunks ≤ 3 MB of byte accumulation per message —
  /// well within the 40B instruction budget (decode() is cheap; all work is in finish()).
  transient let DECODE_BATCH_SIZE : Nat = 3;

  // ── Stable state ──────────────────────────────────────────────────────────

  /// Accumulated compressed chunks uploaded via appendExternalCompressed.
  /// List gives O(1) append vs the O(N²) Array.concat pattern.
  var _chunks = List.empty<[Nat8]>();
  var _decompressed : ?[Nat8] = null;

  // ── Transient state ───────────────────────────────────────────────────────

  /// Fresh decoder per canister lifetime; replaced on clear().
  transient var gzip_decoder = Gzip.Decoder();

  // ── Helpers ────────────────────────────────────────────────────────────

  func canisterId() : Principal { Principal.fromActor(self) };

  /// Return up to PAGE_SIZE bytes at index `page` (2 MiB pages, 0-indexed).
  /// Returns [] when `page` is past the end of `data`.
  func pageOf(data : [Nat8], page : Nat) : [Nat8] {
    let lo = page * PAGE_SIZE;
    let n = data.size();
    if (lo >= n) return [];
    let hi = Nat.min(lo + PAGE_SIZE, n);
    Array.tabulate<Nat8>(hi - lo, func(i) { data[lo + i] });
  };

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Append one chunk of externally-compressed gzip bytes.
  /// Call repeatedly to upload large payloads in ≤1 MB pieces.
  public func appendExternalCompressed(chunk : [Nat8]) : async () {
    List.add(_chunks, chunk);
  };

  /// Reset the compressed buffer, decompressed cache, and decoder state for a fresh run.
  public func clear() : async () {
    List.clear(_chunks);
    _decompressed := null;
    gzip_decoder := Gzip.Decoder();
  };

  /// Return the number of bytes accumulated so far (query — no state change).
  public query func compressedSize() : async Nat {
    var total = 0;
    for (chunk in List.values(_chunks)) { total += chunk.size() };
    total;
  };

  /// Internal: accumulate a batch of compressed chunks into the decoder buffer.
  /// External gzip data is ONE continuous stream, so decode() only accumulates bytes —
  /// finish() is called once by decompress() after all batches complete.
  /// Guarded so only this canister may call it — each await gives a fresh instruction budget.
  public shared ({ caller }) func _decodeBatch(batch : [[Nat8]]) : async () {
    assert caller == canisterId();
    for (chunk in batch.vals()) {
      switch (gzip_decoder.decode(chunk)) {
        case (#err(msg)) Runtime.trap("_decodeBatch: " # msg);
        case (#ok(_)) {};
      };
    };
  };

  /// Decompress all accumulated chunks and cache the result in _decompressed.
  /// Spreads decode() work across ICP messages via self-calls (DECODE_BATCH_SIZE per call),
  /// then calls finish() once to perform the actual decompression.
  public func decompress() : async () {
    let all = List.toArray(_chunks);
    let n = all.size();
    var i = 0;
    while (i < n) {
      let hi = Nat.min(i + DECODE_BATCH_SIZE, n);
      let batch = Array.tabulate<[Nat8]>(hi - i, func(j) { all[i + j] });
      await _decodeBatch(batch);
      i := hi;
    };
    switch (gzip_decoder.finish()) {
      case (#err(msg)) Runtime.trap("decompress finish: " # msg);
      case (#ok(result)) _decompressed := ?result.bytes;
    };
  };

  /// Return a 2 MiB page of the decompressed bytes (0-indexed).
  /// Returns [] when `page` is past the end or decompress() has not been called.
  public query func getDecompressedData(page : Nat) : async [Nat8] {
    let ?d = _decompressed else return [];
    pageOf(d, page);
  };

};
