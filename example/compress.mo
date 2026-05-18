/// Example: general-purpose Gzip compression on the Internet Computer.
///
/// Demonstrates how to compress and decompress arbitrary byte data safely
/// within the ICP instruction-limit by splitting work across multiple messages
/// via a self-call pattern.
///
/// Usage:
///   1. Call `generate_data()` to fill the canister with 10 MB of pseudo-random data.
///   2. Call `compress_data()` to compress it (spreads work over several ICP messages).
///   3. Call `decompress_data()` to decompress and verify the round-trip.
import Array     "mo:core/Array";
import Nat       "mo:core/Nat";
import Nat64     "mo:core/Nat64";
import Principal "mo:core/Principal";
import Random    "mo:core/Random";
import Runtime   "mo:core/Runtime";
import Gzip      "../src/Gzip/lib";

shared ({ caller = _owner }) persistent actor class Compression() = self {

  // ── Constants ─────────────────────────────────────────────────────────────

  transient let MB         = 1_024 * 1_024;
  transient let BLOCK_SIZE = 1 * MB;

  // ── Stable state ──────────────────────────────────────────────────────────

  var _data       : ?[Nat8]               = null;
  var _compressed : ?Gzip.EncodedResponse = null;

  // ── Transient state ───────────────────────────────────────────────────────

  transient let gzip_encoder = Gzip.EncoderBuilder().blockSize(BLOCK_SIZE).build();
  transient let gzip_decoder = Gzip.Decoder();

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// Split `data` into fixed-size chunks of at most `size` bytes.
  func chunks(data : [Nat8], size : Nat) : [[Nat8]] {
    let n = data.size();
    if (n == 0 or size == 0) return [data];
    let count = n / size + (if (n % size != 0) 1 else 0);
    Array.tabulate<[Nat8]>(count, func(i) {
      let lo = i * size;
      let hi = Nat.min(lo + size, n);
      Array.tabulate<Nat8>(hi - lo, func(j) { data[lo + j] })
    })
  };

  func canister_id() : Principal { Principal.fromActor(self) };

  func get_data() : [Nat8] {
    switch (_data) { case (?d) d; case null [] }
  };

  // ── Data generation ───────────────────────────────────────────────────────

  /// Fill the canister with 10 MB of pseudo-random bytes for demo purposes.
  public func generate_data() : async () {
    let rng = Random.seed(42 : Nat64);
    _data := ?Array.tabulate<Nat8>(10 * MB, func(_) { rng.nat8() });
  };

  // ── Compression ───────────────────────────────────────────────────────────

  /// Internal: encode one chunk.
  /// Guarded so only this canister may call it — each await gives the caller
  /// a fresh ICP instruction budget.
  public shared ({ caller }) func _compress_chunk(chunk : [Nat8]) : async () {
    assert caller == canister_id();
    gzip_encoder.encode(chunk);
  };

  /// Compress all stored data in BLOCK_SIZE chunks and persist the result.
  /// Spreads work across ICP messages via self-calls.
  public func compress_data() : async () {
    for (chunk in chunks(get_data(), BLOCK_SIZE).vals()) {
      await _compress_chunk(chunk);
    };
    _compressed := ?gzip_encoder.finish();
  };

  // ── Decompression ─────────────────────────────────────────────────────────

  /// Internal: accumulate one compressed chunk.
  /// Guarded so only this canister may call it.
  public shared ({ caller }) func _decode_chunk(chunk : [Nat8]) : async () {
    assert caller == canister_id();
    switch (gzip_decoder.decode(chunk)) {
      case (#err(msg)) Runtime.trap("_decode_chunk: " # msg);
      case (#ok(_))    {};
    };
  };

  /// Decompress the stored compressed data.
  /// Returns true if the decompressed bytes match the original data.
  public func decompress_data() : async Bool {
    let ?compressed = _compressed else return false;
    for (chunk in compressed.chunks.vals()) {
      await _decode_chunk(chunk);
    };
    switch (gzip_decoder.finish()) {
      case (#err(msg))   Runtime.trap("decompress_data: " # msg);
      case (#ok(result)) result.bytes == get_data();
    }
  };

}
