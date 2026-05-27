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
///   - `storeAndCompressImage("logo.png", bytes)` — compress and store.
///   - `getImagePage("logo.png", page)`           — retrieve decompressed page.
///   - `getImage("logo.png")`                     — retrieve full image (< 6 MiB).
///   - For images > 6 MiB: beginImageUpload / uploadImageChunk / finishImageUpload.
import Array "mo:core/Array";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Principal "mo:core/Principal";
import Runtime "mo:core/Runtime";
import Text "mo:core/Text";
import Gzip "../src/Gzip/lib";

shared ({ caller = _owner }) persistent actor class ImageStore() = self {

  // ── State ─────────────────────────────────────────────────────────────────

  // Not stable — loses contents on canister upgrade.
  transient let images = Map.empty<Text, Gzip.EncodedResponse>();
  transient let decoded_cache = Map.empty<Text, [Nat8]>();

  transient let gzip_encoder = Gzip.EncoderBuilder().build();
  transient let gzip_decoder = Gzip.Decoder();

  // ── Helpers ───────────────────────────────────────────────────────────────

  transient let MB : Nat = 1_024 * 1_024;
  transient let PAGE_SIZE : Nat = 2 * MB - 512;

  func pageOf(data : [Nat8], page : Nat) : [Nat8] {
    let lo = page * PAGE_SIZE;
    let n = data.size();
    if (lo >= n) return [];
    let hi = Nat.min(lo + PAGE_SIZE, n);
    Array.tabulate<Nat8>(hi - lo, func(i) { data[lo + i] });
  };

  func canisterId() : Principal { Principal.fromActor(self) };

  // ── Internal chunk handlers ───────────────────────────────────────────────

  /// Internal: decode one chunk (self-call for instruction-limit management).
  public shared ({ caller }) func _decodeChunk(chunk : [Nat8]) : async () {
    assert caller == canisterId();
    switch (gzip_decoder.decode(chunk)) {
      case (#err(msg)) Runtime.trap("_decode_chunk: " # msg);
      case (#ok(_)) {};
    };
  };

  // ── Private helpers ───────────────────────────────────────────────────────

  /// Decompress `compressed` and write the result directly into `decoded_cache`.
  /// Returns `async ()` so the large [Nat8] never crosses an async return boundary.
  func decodeImage(name : Text, compressed : Gzip.EncodedResponse) : async () {
    gzip_decoder.clear();
    switch (compressed) {
      case (#single data) {
        switch (gzip_decoder.decode(data)) {
          case (#err(msg)) Runtime.trap("decode_image: " # msg);
          case (#ok(_)) {};
        };
      };
      case (#chunked chunks) {
        for (chunk in chunks.vals()) {
          await _decodeChunk(chunk);
        };
      };
    };
    switch (gzip_decoder.finish()) {
      case (#err(msg)) Runtime.trap("decode_image: " # msg);
      case (#ok(result)) Map.add(decoded_cache, Text.compare, name, result.bytes);
    };
  };

  // ── Public API ────────────────────────────────────────────────────────────

  // <6 MiB Images

  /// Compress `data` and store the result under `name`.  Overwrites any existing entry.
  /// For images larger than ~6 MiB use beginImageUpload / uploadImageChunk / finishImageUpload.
  public func storeAndCompressImage(name : Text, data : [Nat8]) : async () {
    gzip_encoder.encode(data);
    let compressed = gzip_encoder.finish();
    Map.add(images, Text.compare, name, compressed);
    ignore Map.delete(decoded_cache, Text.compare, name);
  };

  /// Decompress and return the image stored under `name`.
  /// Returns null if no image is stored under that name.
  public func getImage(name : Text) : async ?[Nat8] {
    return await getImagePage(name, 0);
  };

  // >6 MiB Images

  /// Begin a chunked upload.  Clears any buffered encoder state from a
  /// previous (possibly incomplete) upload.
  public func beginImageUpload() : async () {
    gzip_encoder.clear();
  };

  /// Feed one raw chunk of image data to the encoder.
  /// Each call should supply at most one encoder chunk worth of bytes (≤ 6 MiB).
  public func uploadImageChunk(chunk : [Nat8]) : async () {
    gzip_encoder.encode(chunk);
  };

  /// Finalize compression and store the result under `name`.
  /// Must be called after `beginImageUpload` + one or more `uploadImageChunk` calls.
  public func finishImageUpload(name : Text) : async () {
    let compressed = gzip_encoder.finish();
    Map.add(images, Text.compare, name, compressed);
    ignore Map.delete(decoded_cache, Text.compare, name);
  };

  /// Decompress and return one page of the image stored under `name`.
  /// Returns null if image not found, ?[] when page is beyond the last byte.
  public func getImagePage(name : Text, page : Nat) : async ?[Nat8] {
    switch (Map.get(images, Text.compare, name)) {
      case null null;
      case (?stored) {
        if (Map.get(decoded_cache, Text.compare, name) == null) {
          await decodeImage(name, stored);
        };
        switch (Map.get(decoded_cache, Text.compare, name)) {
          case null Runtime.trap("getImagePage: decodeImage did not populate cache");
          case (?data) ?(pageOf(data, page));
        };
      };
    };
  };

};
