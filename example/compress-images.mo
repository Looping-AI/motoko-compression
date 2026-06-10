/// Example: Gzip-compressed named image store on the Internet Computer.
///
/// Demonstrates storing and retrieving images with transparent Gzip compression.
/// Images are stored as a single gzip stream and survive canister upgrades.
///
/// ── Small images (≤ ingress limit, ~1–2 MiB) ─────────────────────────────────
///
///   1. `storeAndCompressImage("logo.png", bytes)` — compress and store.
///   2. `getImage("logo.png")`                     — decompress and return.
///   3. `getImagePage("logo.png", page)`           — paginated read from cache (query).
///
/// ── Large images (> ingress limit) ───────────────────────────────────────────
///
/// Upload the raw bytes in chunks (client drives message-size splitting), then
/// request an async decompression job before reading pages:
///
///   1. `beginImageUpload()`              — reset encoder.
///   2. `uploadImageChunk(chunk)` × N    — feed raw bytes; one call per ingress chunk.
///   3. `finishImageUpload("large.png")` — flush gzip stream and store.
///   4. `requestLoadImageJob("large.png")` → JobId
///   5. Poll `getJobStatus(id)` until `#done`.
///   6. `getImagePage("large.png", page)` — cheap query from cache.
///
/// Notes
/// ─────
/// • `getImagePage` returns `null` when the name is unknown and `?[]` when either
///   the image has not yet been loaded into the decoded cache (call
///   `requestLoadImageJob` first) or the page index is past the last byte.
/// • `getImage` uses a one-shot `Gzip.decompress` call; for images > ~21 MiB
///   compressed use `requestLoadImageJob` + `getImagePage` instead.
import Array "mo:core/Array";
import Error "mo:core/Error";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Runtime "mo:core/Runtime";
import Text "mo:core/Text";
import Timer "mo:core/Timer";
import Gzip "../src";

shared ({ caller = _owner }) persistent actor class ImageStore() = self {

  // ── Types ──────────────────────────────────────────────────────────────────

  public type JobId = Nat;

  public type JobStatus = {
    #loading : { name : Text; offset : Nat; total : Nat };
    #done;
    #failed : Text;
  };

  type CompletedJob = { #done; #failed : Text };

  type ActiveJob = {
    id : Nat;
    kind : { #loadImage : { name : Text } };
    var offset : Nat;
    total : Nat; // compressed.size() — used as progress denominator
  };

  type JobState = {
    var nextJobId : Nat;
    var activeJob : ?ActiveJob;
    completedJobs : Map.Map<Nat, CompletedJob>;
  };

  // ── Stable state ───────────────────────────────────────────────────────────

  // Stable (no `transient`) — survives canister upgrades.
  let images = Map.empty<Text, [Nat8]>();

  let jobState : JobState = {
    var nextJobId = 0;
    var activeJob = null;
    completedJobs = Map.empty();
  };

  // ── Transient state ────────────────────────────────────────────────────────

  transient let decodedCache = Map.empty<Text, [Nat8]>();
  transient let encoder : Gzip.Encoder = Gzip.EncoderBuilder().build();
  transient let decoder : Gzip.Decoder = Gzip.Decoder();
  transient var timerHandle : ?Timer.TimerId = null;

  transient let MB : Nat = 1_024 * 1_024;
  transient let PAGE_SIZE : Nat = 2 * MB - 512;

  // ── Helpers ────────────────────────────────────────────────────────────────

  func pageOf(data : [Nat8], page : Nat) : [Nat8] {
    let lo = page * PAGE_SIZE;
    let n = data.size();
    if (lo >= n) return [];
    let hi = Nat.min(lo + PAGE_SIZE, n);
    Array.tabulate<Nat8>(hi - lo, func(i) { data[lo + i] });
  };

  // ── Job lifecycle ──────────────────────────────────────────────────────────

  func markJobDone() {
    switch (jobState.activeJob) {
      case (?job) {
        Map.add(jobState.completedJobs, Nat.compare, job.id, #done);
        jobState.activeJob := null;
        timerHandle := null;
      };
      case null {};
    };
  };

  func markJobFailed(msg : Text) {
    switch (jobState.activeJob) {
      case (?job) {
        Map.add(jobState.completedJobs, Nat.compare, job.id, #failed msg);
        jobState.activeJob := null;
        timerHandle := null;
      };
      case null {};
    };
  };

  // ── Timer callback ─────────────────────────────────────────────────────────

  func tickLoad() : async () {
    var trapped = true;
    try {
      let ?job = jobState.activeJob else {
        markJobFailed("loadImage: no active job");
        return;
      };
      let #loadImage { name } = job.kind;
      switch (decoder.step(#default)) {
        case (#err msg) { markJobFailed("loadImage step: " # msg); return };
        case (#ok(#more)) {
          job.offset := decoder.decompressedSize();
          timerHandle := ?Timer.setTimer<system>(#nanoseconds 0, tickLoad);
        };
        case (#ok(#done)) {
          job.offset := decoder.decompressedSize();
          // decompressed() performs a single O(n) merge — only call it once on #done.
          Map.add(decodedCache, Text.compare, name, decoder.decompressed());
          markJobDone();
        };
      };
      trapped := false;
    } catch (e) {
      markJobFailed("loadImage trap: " # Error.message(e));
      trapped := false;
    } finally {
      if (trapped) markJobFailed("loadImage: unhandled trap");
    };
  };

  // ── Upgrade hook ───────────────────────────────────────────────────────────

  system func postupgrade() {
    // Timers do not survive upgrades — mark any in-progress job as failed.
    markJobFailed("canister upgraded mid-job");
  };

  // ── Small image upload ─────────────────────────────────────────────────────

  /// Compress `data` and store the result under `name`.
  /// Handles payloads that fit within one ingress message (practical limit ~1–2 MiB).
  /// For larger images use beginImageUpload / uploadImageChunk / finishImageUpload.
  public func storeAndCompressImage(name : Text, data : [Nat8]) : async () {
    let compressed = Gzip.compress(encoder, data);
    Map.add(images, Text.compare, name, compressed);
    ignore Map.delete(decodedCache, Text.compare, name);
  };

  // ── Large image upload ─────────────────────────────────────────────────────

  /// Begin a chunked upload.  Resets the encoder for a fresh gzip stream.
  public func beginImageUpload() : async () {
    encoder.clear();
  };

  /// Feed one raw chunk of image data to the encoder.
  /// Each call is a separate ingress message with its own instruction budget —
  /// no self-call needed.  Supply at most ~2 MiB per call (ingress limit).
  public func uploadImageChunk(chunk : [Nat8]) : async () {
    encoder.encode(chunk);
  };

  /// Finalize compression and store the result under `name`.
  /// Must be called after beginImageUpload + one or more uploadImageChunk calls.
  public func finishImageUpload(name : Text) : async () {
    encoder.finish();
    Map.add(images, Text.compare, name, encoder.compressed());
    ignore Map.delete(decodedCache, Text.compare, name);
    encoder.clear();
  };

  // ── Small image retrieval (< 2 MiB) ──────────────────────────────────────────────────

  /// Decompress and return the full image stored under `name`.
  /// Returns null if no image is stored under that name.
  /// Uses a one-shot Gzip.decompress call; since IC return can't be bigger than ~2 MiB,
  /// Please use requestLoadImageJob + getImagePage instead.
  public func getImage(name : Text) : async ?[Nat8] {
    switch (Map.get(decodedCache, Text.compare, name)) {
      case (?data) ?data;
      case null {
        switch (Map.get(images, Text.compare, name)) {
          case null null;
          case (?compressed) {
            switch (Gzip.decompress(decoder, compressed)) {
              case (#err msg) Runtime.trap("getImage: " # msg);
              case (#ok bytes) {
                Map.add(decodedCache, Text.compare, name, bytes);
                ?bytes;
              };
            };
          };
        };
      };
    };
  };

  // ── Async decompression job ────────────────────────────────────────────────

  /// Request an async decompression job for the image stored under `name`.
  /// Returns null if the name is not found.  Returns ?JobId on success.
  /// Only one job may be active at a time — traps if one is already running.
  /// Poll getJobStatus until #done, then use getImagePage to read pages.
  public func requestLoadImageJob(name : Text) : async ?JobId {
    switch (Map.get(images, Text.compare, name)) {
      case null null;
      case (?compressed) {
        let null = jobState.activeJob else Runtime.trap("requestLoadImageJob: job already active");
        let id = jobState.nextJobId;
        jobState.nextJobId += 1;

        decoder.clear();
        decoder.decode(compressed);
        switch (decoder.start()) {
          case (#err msg) Runtime.trap("requestLoadImageJob: start: " # msg);
          case (#ok _) {};
        };

        jobState.activeJob := ?{
          id;
          kind = #loadImage { name };
          var offset = 0;
          total = compressed.size();
        };

        timerHandle := ?Timer.setTimer<system>(#nanoseconds 0, tickLoad);
        ?id;
      };
    };
  };

  /// Poll the status of a job by its JobId.
  /// Returns null if the id is unknown (never submitted or already cleared).
  public func getJobStatus(id : JobId) : async ?JobStatus {
    switch (jobState.activeJob) {
      case (?job) if (job.id == id) {
        return ?(
          switch (job.kind) {
            case (#loadImage { name }) #loading {
              name;
              offset = job.offset;
              total = job.total;
            };
          }
        );
      };
      case _ {};
    };
    switch (Map.get(jobState.completedJobs, Nat.compare, id)) {
      case (?#done) ?#done;
      case (?#failed msg) ?(#failed msg);
      case null null;
    };
  };

  // ── Paginated retrieval (query) ────────────────────────────────────────────

  /// Return one page of the decompressed image stored under `name` (0-indexed).
  ///
  /// Return values:
  ///   null   — image not stored under this name.
  ///   ?[]    — image exists but not yet in decoded cache (call requestLoadImageJob
  ///            first), or page index is past the last byte.
  ///   ?bytes — one page of decompressed image data.
  public query func getImagePage(name : Text, page : Nat) : async ?[Nat8] {
    switch (Map.get(decodedCache, Text.compare, name)) {
      case (?data) ?(pageOf(data, page));
      case null {
        switch (Map.get(images, Text.compare, name)) {
          case null null;
          case _ ?([] : [Nat8]);
        };
      };
    };
  };

  // ── Maintenance ────────────────────────────────────────────────────────────

  /// Remove the image stored under `name` from both the compressed store and
  /// the decoded cache.
  public func clearImage(name : Text) : async () {
    ignore Map.delete(images, Text.compare, name);
    ignore Map.delete(decodedCache, Text.compare, name);
  };
};
