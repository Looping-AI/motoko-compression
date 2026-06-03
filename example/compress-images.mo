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
///   - `getImage("logo.png")`                     — retrieve full image (< 5 MiB).
///   - For images > 5 MiB: beginImageUpload / uploadImageChunk / finishImageUpload.
import Array "mo:core/Array";
import List "mo:core/List";
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

  // ── Constants ─────────────────────────────────────────────────────────────

  transient let MB : Nat = 1_024 * 1_024;
  transient let PAGE_SIZE : Nat = 2 * MB - 512;

  /// Bytes per self-call — derived from the encoder so both stay in sync.
  transient let ENCODE_CHUNK_SIZE : Nat = gzip_encoder.outputChunkSize();

  /// Compressed chunks to decompress per self-call.
  /// At ~8.6B instructions per 5 MiB chunk, 3 chunks ≈ 25.8B — safely under the 40B limit.
  transient let DECODE_BATCH_SIZE : Nat = 3;

  // ── Transient buffers ─────────────────────────────────────────────────────

  /// Accumulates per-chunk compressed streams during `_compressChunk` self-calls.
  /// Each element is a complete, independent gzip stream for one input chunk.
  transient var _compress_buf = List.empty<[Nat8]>();

  /// Accumulates decompressed bytes across `_decompressBatch` self-calls.
  transient var _decompress_buf = List.empty<Nat8>();

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// Split `data` into fixed-size chunks of at most `size` bytes.
  func chunks(data : [Nat8], size : Nat) : [[Nat8]] {
    let n = data.size();
    if (n == 0 or size == 0) return [data];
    let count = n / size + (if (n % size != 0) 1 else 0);
    Array.tabulate<[Nat8]>(
      count,
      func(i) {
        let lo = i * size;
        let hi = Nat.min(lo + size, n);
        Array.tabulate<Nat8>(hi - lo, func(j) { data[lo + j] });
      },
    );
  };

  func pageOf(data : [Nat8], page : Nat) : [Nat8] {
    let lo = page * PAGE_SIZE;
    let n = data.size();
    if (lo >= n) return [];
    let hi = Nat.min(lo + PAGE_SIZE, n);
    Array.tabulate<Nat8>(hi - lo, func(i) { data[lo + i] });
  };

  func canisterId() : Principal { Principal.fromActor(self) };

  // ── Internal chunk handlers ───────────────────────────────────────────────

  /// Internal: compress one input chunk into a complete, independent gzip stream
  /// and append it to `_compress_buf`. Each await gives a fresh instruction budget.
  public shared ({ caller }) func _compressChunk(chunk : [Nat8]) : async () {
    assert caller == canisterId();
    gzip_encoder.clear();
    gzip_encoder.encode(chunk);
    switch (gzip_encoder.finish()) {
      case (#single data) List.add(_compress_buf, data);
      case (#chunked _) Runtime.trap("_compressChunk: chunk exceeded outputChunkSize");
    };
  };

  /// Internal: assemble all per-chunk compressed streams, store under `name`,
  /// and evict any stale decoded cache entry.
  public shared ({ caller }) func _finishCompression(name : Text) : async () {
    assert caller == canisterId();
    let streams = List.toArray(_compress_buf);
    List.clear(_compress_buf);
    let compressed = if (streams.size() == 1) #single(streams[0]) else #chunked(streams);
    Map.add(images, Text.compare, name, compressed);
    ignore Map.delete(decoded_cache, Text.compare, name);
  };

  /// Internal: decompress a batch of chunks (each a complete independent gzip stream)
  /// and append results to `_decompress_buf`. Each await gives a fresh instruction budget.
  public shared ({ caller }) func _decompressBatch(batch : [[Nat8]]) : async () {
    assert caller == canisterId();
    for (chunk in batch.vals()) {
      switch (gzip_decoder.decode(chunk)) {
        case (#err(msg)) Runtime.trap("_decompressBatch decode: " # msg);
        case (#ok(_)) {};
      };
      let consume = func(out : [Nat8]) {
        List.addAll(_decompress_buf, out.vals());
      };
      switch (gzip_decoder.finishStreaming(consume)) {
        case (#err(msg)) Runtime.trap("_decompressBatch finishStreaming: " # msg);
        case (#ok(_)) {};
      };
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
          case (#err(msg)) Runtime.trap("decodeImage decode: " # msg);
          case (#ok(_)) {};
        };
        List.clear(_decompress_buf);
        let consume = func(out : [Nat8]) {
          List.addAll(_decompress_buf, out.vals());
        };
        switch (gzip_decoder.finishStreaming(consume)) {
          case (#err(msg)) Runtime.trap("decodeImage finishStreaming: " # msg);
          case (#ok(_)) Map.add(decoded_cache, Text.compare, name, List.toArray(_decompress_buf));
        };
      };
      case (#chunked cs) {
        List.clear(_decompress_buf);
        let n = cs.size();
        var i = 0;
        while (i < n) {
          let hi = Nat.min(i + DECODE_BATCH_SIZE, n);
          let batch = Array.tabulate<[Nat8]>(hi - i, func(j) { cs[i + j] });
          await _decompressBatch(batch);
          i := hi;
        };
        Map.add(decoded_cache, Text.compare, name, List.toArray(_decompress_buf));
      };
    };
  };

  // ── Public API ────────────────────────────────────────────────────────────

  // <5 MiB Images

  /// Compress `data` and store the result under `name`.  Overwrites any existing entry.
  /// For images larger than ~5 MiB use beginImageUpload / uploadImageChunk / finishImageUpload.
  public func storeAndCompressImage(name : Text, data : [Nat8]) : async () {
    gzip_encoder.clear();
    List.clear(_compress_buf);
    if (data.size() < ENCODE_CHUNK_SIZE) {
      gzip_encoder.encode(data);
      let compressed = gzip_encoder.finish();
      Map.add(images, Text.compare, name, compressed);
      ignore Map.delete(decoded_cache, Text.compare, name);
    } else {
      for (chunk in chunks(data, ENCODE_CHUNK_SIZE).vals()) {
        await _compressChunk(chunk);
      };
      await _finishCompression(name);
    };
  };

  /// Decompress and return the image stored under `name`.
  /// Returns null if no image is stored under that name.
  public func getImage(name : Text) : async ?[Nat8] {
    return await getImagePage(name, 0);
  };

  // >5 MiB Images

  /// Begin a chunked upload.  Clears any buffered encoder state from a
  /// previous (possibly incomplete) upload.
  public func beginImageUpload() : async () {
    gzip_encoder.clear();
    List.clear(_compress_buf);
  };

  /// Feed one raw chunk of image data to the encoder.
  /// Each call should supply at most one encoder chunk worth of bytes (≤ ENCODE_CHUNK_SIZE).
  public func uploadImageChunk(chunk : [Nat8]) : async () {
    await _compressChunk(chunk);
  };

  /// Finalize compression and store the result under `name`.
  /// Must be called after `beginImageUpload` + one or more `uploadImageChunk` calls.
  public func finishImageUpload(name : Text) : async () {
    await _finishCompression(name);
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
