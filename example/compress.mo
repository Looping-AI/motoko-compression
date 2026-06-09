/// Example: general-purpose Gzip compression on the Internet Computer.
///
/// Two usage modes depending on payload size:
///
/// ── Small payloads (≤ 6 MiB uncompressed or ≤ 21 MiB compressed) ────────────────────────────────
///
/// Call `compress()` / `decompress()` directly — both complete in a single
/// message with no timer overhead.
///
/// If you only need one direction, use the Gzip convenience helpers instead
/// of spinning up the full encoder+decoder pair:
///
///   // Encoding only:
///   let compressed = Gzip.compress(enc, rawBytes);      // [Nat8]
///   let compressed = Gzip.compressText(enc, text);      // [Nat8]
///   let compressed = Gzip.compressBlob(enc, blob);      // [Nat8]
///
///   // Decoding only:
///   let result = Gzip.decompress(dec, compressed);      // Result<[Nat8], Text>
///
///   Keep `enc` and `dec` as `transient let` canister fields and reuse them
///   across calls — each helper calls `clear()` internally so state never leaks.
///
/// Usage (small):
///   1. Call `generateBytes(n_bytes)` to populate raw data (n_bytes ≤ 6 MiB).
///   2. Call `compress()` — returns once compressed output is ready.
///   3. Call `decompress()` — returns once decompressed output is ready.
///   4. Compare `getGeneratedData()` pages with `getDecompressedData()` pages.
///
/// ── Large payloads (> 6 MiB uncompressed or > 21 MiB compressed) ────────────────────────────────
///
/// ICP caps instructions per message (~40 B); a single call can safely process
/// at most ~6 MiB of raw input to be compressed OR ~21 MiB of compressed input
/// to be decompressed. For larger data use the timer-driven job queue:
/// each timer tick processes one chunk with a fresh instruction budget;
/// callers submit a job and poll until done.
///
/// Usage (large):
///   1. Call `generateBytes(n_bytes)` to populate raw data (n_bytes > 6 MiB).
///   2. Call `requestCompressJob()` → receive a JobId.
///   3. Poll `getJobStatus(id)` until `#done`.
///   4. Call `requestDecompressJob()` → receive a JobId.
///   5. Poll `getJobStatus(id)` until `#done`.
///   6. Compare `getGeneratedData()` pages with `getDecompressedData()` pages.
import Array "mo:core/Array";
import Error "mo:core/Error";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat64 "mo:core/Nat64";
import Blob "mo:core/Blob";
import Random "mo:core/Random";
import Runtime "mo:core/Runtime";
import Timer "mo:core/Timer";
import Gzip "../src/Gzip/lib";

shared ({ caller = _owner }) persistent actor class Compression() = self {

  // ── Types ─────────────────────────────────────────────────────────────────

  public type JobId = Nat;

  public type JobStatus = {
    #compressing : { index : Nat; total : Nat };
    #decompressing : { index : Nat; total : Nat };
    #done;
    #failed : Text;
  };

  type CompletedJob = { #done; #failed : Text };

  type ActiveJob = {
    id : Nat;
    kind : { #compress; #decompress };
    // compress: input bytes encoded so far; decompress: output bytes produced.
    var offset : Nat;
    // Total uncompressed size (rawData.size() captured at job start).
    total : Nat;
  };

  type JobState = {
    var nextJobId : Nat;
    var activeJob : ?ActiveJob;
    completedJobs : Map.Map<Nat, CompletedJob>;
  };

  // ── Constants ─────────────────────────────────────────────────────────────

  transient let MB = 1_024 * 1_024;

  transient let PAGE_SIZE : Nat = 2 * MB - 512;

  // ── Stable state ──────────────────────────────────────────────────────────

  var rawData : [Nat8] = [];

  // Job queue
  let jobState : JobState = {
    var nextJobId = 0;
    var activeJob = null;
    completedJobs = Map.empty();
  };

  // ── Transient state ───────────────────────────────────────────────────────

  // Uncompressed input bytes fed to the encoder per compress tick. Encode is
  // the heavy side (~2.7 B instructions/MiB), so 6 MiB/tick stays well within
  // the per-message instruction limit.
  transient let ENCODE_INPUT_SLICE : Nat = 6 * MB;

  // Live streaming codecs — always-live singletons; reused across jobs via
  // clear(). Transient: an upgrade discards them and `postupgrade` fails any
  // in-progress job accordingly.
  transient let encoder : Gzip.Encoder = Gzip.EncoderBuilder().build();
  transient let decoder : Gzip.Decoder = Gzip.Decoder();

  transient var timerHandle : ?Timer.TimerId = null;

  // ── Helpers ───────────────────────────────────────────────────────────────

  func pageOf(bytes : [Nat8], page : Nat) : [Nat8] {
    let lo = page * PAGE_SIZE;
    let n = bytes.size();
    if (lo >= n) return [];
    let hi = Nat.min(lo + PAGE_SIZE, n);
    Array.tabulate<Nat8>(hi - lo, func(i) { bytes[lo + i] });
  };

  // ── Job lifecycle ─────────────────────────────────────────────────────────

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

  // ── Timer callbacks ───────────────────────────────────────────────────────

  func tickCompress() : async () {
    var trapped = true;
    try {
      let ?job = jobState.activeJob else {
        markJobFailed("compress: no active job");
        return;
      };
      let #compress = job.kind else {
        markJobFailed("compress: wrong job kind");
        return;
      };
      let rawLen = rawData.size();

      if (job.offset < rawLen) {
        // Encode the next input slice into the shared gzip stream. The encoder's
        // on-output callback drains completed bytes into the internal accumulator.
        let lo = job.offset;
        let hi = Nat.min(lo + ENCODE_INPUT_SLICE, rawLen);
        let slice = Array.tabulate<Nat8>(hi - lo, func(j) { rawData[lo + j] });
        encoder.encode(slice);
        job.offset := hi;
        timerHandle := ?Timer.setTimer<system>(#nanoseconds 0, tickCompress);
      } else {
        // All input encoded — flush the final block + footer.
        encoder.finish();
        markJobDone();
      };
      trapped := false;
    } catch (e) {
      markJobFailed("compress trap: " # Error.message(e));
      trapped := false;
    } finally {
      // finally is always called, even after a trap (unlike catch).
      if (trapped) markJobFailed("compress: unhandled trap");
    };
  };

  func tickDecompress() : async () {
    var trapped = true;
    try {
      let ?job = jobState.activeJob else {
        markJobFailed("decompress: no active job");
        return;
      };
      let #decompress = job.kind else {
        markJobFailed("decompress: wrong job kind");
        return;
      };

      switch (decoder.step(#default)) {
        case (#err msg) { markJobFailed("decompress step: " # msg); return };
        case (#ok(#more)) {
          job.offset := decoder.decompressedSize();
          timerHandle := ?Timer.setTimer<system>(#nanoseconds 0, tickDecompress);
        };
        case (#ok(#done)) {
          job.offset := decoder.decompressedSize();
          markJobDone();
        };
      };
      trapped := false;
    } catch (e) {
      markJobFailed("decompress trap: " # Error.message(e));
      trapped := false;
    } finally {
      // finally is always called, even after a trap (unlike catch).
      if (trapped) markJobFailed("decompress: unhandled trap");
    };
  };

  // ── Upgrade hook ──────────────────────────────────────────────────────────

  system func postupgrade() {
    // Timers do not survive upgrades — mark any in-progress job as failed.
    markJobFailed("canister upgraded mid-job");
  };

  // ── Latency baseline ──────────────────────────────────────────────────────

  public func ping() : async Text { "pong" };

  // ── Data generation ───────────────────────────────────────────────────────

  /// Fill the canister with `n_bytes` of structured test data split into thirds:
  ///   - first third:  constant byte (0xAA) — tests run-length compressibility
  ///   - middle third: pseudo-random bytes  — tests incompressible data
  ///   - last third:   sequential 0–255 loop — tests pattern compressibility
  public func generateBytes(n_bytes : Nat) : async () {
    let third = n_bytes / 3;

    // 1. Fetch secure entropy block
    let entropy = await Random.blob();
    let entropyBytes = Blob.toArray(entropy);

    // 2. Seed a local fast PRNG from the 32-byte entropy block
    var seedVal : Nat64 = 0;
    let size = entropyBytes.size();
    var j = 0;
    while (j < 8 and j < size) {
      seedVal := (seedVal << (8 : Nat64)) | Nat8.toNat64(entropyBytes[j]);
      j += 1;
    };
    if (seedVal == 0) {
      seedVal := 123456789 : Nat64;
    };

    var prngState = seedVal;
    let xorshift64 = func() : Nat64 {
      var x = prngState;
      x := x ^ (x << (13 : Nat64));
      x := x ^ (x >> (7 : Nat64));
      x := x ^ (x << (17 : Nat64));
      prngState := x;
      x;
    };

    var randVal : Nat64 = 0;
    var randBitsLeft = 0;

    // 3. Tabulate the entire immutable array in a single synchronous pass
    rawData := Array.tabulate<Nat8>(
      n_bytes,
      func(i) {
        if (i < third) {
          0xAA;
        } else if (i < 2 * third) {
          if (randBitsLeft == 0) {
            randVal := xorshift64();
            randBitsLeft := 8;
          };
          let b = Nat64.toNat8(randVal & (0xFF : Nat64));
          randVal := randVal >> (8 : Nat64);
          randBitsLeft -= 1;
          b;
        } else {
          Nat8.fromNat(i % 256);
        };
      },
    );
  };

  /// Return a 2 MiB page of the raw generated bytes (0-indexed).
  public query func getGeneratedData(page : Nat) : async [Nat8] {
    pageOf(rawData, page);
  };

  // ── Read Data ───────────────────────────────────────────────────────

  /// Return a 2 MiB page of the compressed output bytes (0-indexed).
  public query func getCompressedData(page : Nat) : async [Nat8] {
    if (encoder.chunks().size() == 0) return [];
    pageOf(Array.flatten(encoder.chunks()), page);
  };

  /// Return a 2 MiB page of the decompressed bytes (0-indexed).
  public query func getDecompressedData(page : Nat) : async [Nat8] {
    if (decoder.chunks().size() == 0) return [];
    pageOf(Array.flatten(decoder.chunks()), page);
  };

  // ── Direct (single-message) compress / decompress ────────────────────────

  /// Compress rawData in a single message (no timer). Best for small payloads
  /// that fit within the per-message instruction limit (~40 B instructions).
  public func compress() : async () {
    encoder.clear();
    encoder.encode(rawData);
    encoder.finish();
  };

  /// Decompress compressed data in a single message (no timer). Best for small payloads.
  public func decompress() : async () {
    if (encoder.chunks().size() == 0) Runtime.trap("decompress: no compressed data");
    decoder.clear();
    decoder.decode(encoder.compressed());
    switch (decoder.finish()) {
      case (#err msg) Runtime.trap("decompress finish: " # msg);
      case (#ok _) {};
    };
  };

  // ── Job submission ────────────────────────────────────────────────────────

  /// Request a compression job. Returns the JobId immediately.
  /// Only one job may be active at a time — traps if one is already running.
  public func requestCompressJob() : async JobId {
    let null = jobState.activeJob else Runtime.trap("requestCompressJob: job already active");
    let id = jobState.nextJobId;
    jobState.nextJobId += 1;

    // Reset the encoder singleton; output accumulates internally across ticks
    // and is readable via encoder.chunks() once finish() is called.
    encoder.clear();

    jobState.activeJob := ?{
      id;
      kind = #compress;
      var offset = 0;
      total = rawData.size();
    };

    timerHandle := ?Timer.setTimer<system>(#nanoseconds 0, tickCompress);
    id;
  };

  /// Request a decompression job. Returns the JobId immediately.
  /// Only one job may be active at a time — traps if one is already running.
  /// Traps if no compressed data is available.
  public func requestDecompressJob() : async JobId {
    let null = jobState.activeJob else Runtime.trap("requestDecompressJob: job already active");
    if (encoder.chunks().size() == 0) Runtime.trap("requestDecompressJob: no compressed data");

    let id = jobState.nextJobId;
    jobState.nextJobId += 1;

    // Reset the decoder singleton, feed every chunk from the encoder, and
    // parse the header. Per-tick step() does the heavy decompression work.
    decoder.clear();
    for (chunk in encoder.chunks().vals()) {
      decoder.decode(chunk);
    };
    switch (decoder.start()) {
      case (#err msg) Runtime.trap("requestDecompressJob: start: " # msg);
      case (#ok _) {};
    };

    jobState.activeJob := ?{
      id;
      kind = #decompress;
      var offset = 0;
      total = rawData.size();
    };

    timerHandle := ?Timer.setTimer<system>(#nanoseconds 0, tickDecompress);
    id;
  };

  // ── Job status & management ───────────────────────────────────────────────

  /// Poll the status of a job by its JobId.
  /// Returns `null` if the id is unknown (never submitted or already cleared).
  public func getJobStatus(id : JobId) : async ?JobStatus {
    switch (jobState.activeJob) {
      case (?job) if (job.id == id) {
        return ?(
          switch (job.kind) {
            case (#compress) #compressing {
              index = job.offset;
              total = job.total;
            };
            case (#decompress) #decompressing {
              index = job.offset;
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

  /// Release all temporary canister data: raw input,
  /// compressed output, and decompressed output.
  /// Call this after retrieving results to reclaim heap space.
  public func clearAll() : async () {
    rawData := [];
    encoder.clear();
    decoder.clear();
  };

};
