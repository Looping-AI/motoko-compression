/// Example: Gzip-compressed named image store on the Internet Computer.
///
/// Demonstrates storing and retrieving images with transparent Gzip compression
/// using the library's block-chunked encoder.
///
/// Note: `images` is a mutable in-memory map and is NOT preserved across
/// canister upgrades.  For a production canister, serialise the map into a
/// `stable` variable in `system func postupgrade`.
///
/// Usage:
///   - `store_image("logo.png", bytes)` — compress and store.
///   - `get_image("logo.png")`          — decompress and return.
///   - `is_exact_image("logo.png", bytes)` — verify stored contents match.
import Array     "mo:core/Array";
import Map       "mo:core/Map";
import Nat       "mo:core/Nat";
import Principal "mo:core/Principal";
import Runtime   "mo:core/Runtime";
import Text      "mo:core/Text";
import Gzip      "../src/Gzip/lib";

shared ({ caller = _owner }) persistent actor class ImageStore() = self {

  // ── State ─────────────────────────────────────────────────────────────────

  // Not stable — loses contents on canister upgrade.
  transient let images = Map.empty<Text, Gzip.EncodedResponse>();

  transient let gzip_encoder = Gzip.EncoderBuilder().build();
  transient let gzip_decoder = Gzip.Decoder();

  // ── Helpers ───────────────────────────────────────────────────────────────

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

  // ── Internal chunk handlers ───────────────────────────────────────────────

  /// Internal: encode one chunk (self-call for instruction-limit management).
  public shared ({ caller }) func _compress_chunk(chunk : [Nat8]) : async () {
    assert caller == canister_id();
    gzip_encoder.encode(chunk);
  };

  /// Internal: decode one chunk (self-call for instruction-limit management).
  public shared ({ caller }) func _decode_chunk(chunk : [Nat8]) : async () {
    assert caller == canister_id();
    switch (gzip_decoder.decode(chunk)) {
      case (#err(msg)) Runtime.trap("_decode_chunk: " # msg);
      case (#ok(_))    {};
    };
  };

  // ── Private helpers ───────────────────────────────────────────────────────

  func compress_image(data : [Nat8]) : async* Gzip.EncodedResponse {
    for (chunk in chunks(data, gzip_encoder.block_size()).vals()) {
      await _compress_chunk(chunk);
    };
    gzip_encoder.finish()
  };

  func decode_image(compressed : Gzip.EncodedResponse) : async* [Nat8] {
    for (chunk in compressed.chunks.vals()) {
      await _decode_chunk(chunk);
    };
    switch (gzip_decoder.finish()) {
      case (#err(msg))   Runtime.trap("decode_image: " # msg);
      case (#ok(result)) result.bytes;
    }
  };

  // ── Public API ────────────────────────────────────────────────────────────

  /// Compress `image` and store it under `name`.  Overwrites any existing entry.
  public func store_image(name : Text, image : [Nat8]) : async () {
    let compressed = await* compress_image(image);
    Map.add(images, Text.compare, name, compressed);
  };

  /// Decompress and return the image stored under `name`.
  /// Returns null if no image is stored under that name.
  public func get_image(name : Text) : async ?[Nat8] {
    switch (Map.get(images, Text.compare, name)) {
      case null      null;
      case (?stored) ?(await* decode_image(stored));
    }
  };

  /// Return true if the bytes stored under `name` match `new_image` exactly.
  public func is_exact_image(name : Text, new_image : [Nat8]) : async Bool {
    switch (await get_image(name)) {
      case null            false;
      case (?stored_image) stored_image == new_image;
    }
  };

}
