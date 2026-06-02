/// Example: general-purpose Gzip compression on the Internet Computer.
///
/// Demonstrates how to compress and decompress arbitrary byte data safely
/// within the ICP instruction-limit using a timer-driven job queue.
///
/// Each timer tick processes one chunk with a fresh instruction budget;
/// callers submit a job and poll `getJobStatus(id)` until `#done`.
///
/// Usage:
///   1. Call `generateBytes(size_mb)` to fill the canister with pseudo-random data.
///   2. Call `requestCompressJob()` → receive a JobId.
///   3. Poll `getJobStatus(id)` until `#done`.
///   4. Call `requestDecompressJob()` → receive a JobId.
///   5. Poll `getJobStatus(id)` until `#done`.
///   6. Compare `getGeneratedData()` pages with `getDecompressedData()` pages.
import Array "mo:core/Array";
import Error "mo:core/Error";
import List "mo:core/List";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat64 "mo:core/Nat64";
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
    kind : {
      #compress : { chunkSize : Nat };
      #decompress : { chunks : [[Nat8]] };
    };
    var chunkIdx : Nat;
    chunkTotal : Nat;
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

  var rawData : ?[Nat8] = null;
  let compressed : List.List<[Nat8]> = List.empty();
  let decompressed : List.List<[Nat8]> = List.empty();

  // Job queue
  let jobState : JobState = {
    var nextJobId = 0;
    var activeJob = null;
    completedJobs = Map.empty();
  };

  // ── Transient state ───────────────────────────────────────────────────────

  // Non-final blocks use fixed Huffman (worst case 9/8 expansion). Solving
  // N × (9b+10)/(8b) + 18 ≤ s for N gives the safe input slice size.
  transient let ENCODE_CHUNK_SIZE : Nat = do {
    let enc = Gzip.EncoderBuilder().build();
    let s = enc.outputChunkSize();
    let b = enc.deflateBlockSize();
    (s - 18) * 8 * b / (9 * b + 10);
  };

  // Decode is ~5–10× cheaper per byte than encode. Each Gzip stream costs ~7B
  // instructions. Start at 1 (same throughput as current) and tune upward with
  // perf data — e.g. set to 5 to batch 5 streams per tick at ~35B instructions.
  transient let DECODE_BATCH_SIZE : Nat = 3;

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
      let #compress { chunkSize } = job.kind else {
        markJobFailed("compress: wrong job kind");
        return;
      };
      let ?raw = rawData else {
        markJobFailed("compress: no raw data");
        return;
      };
      if (job.chunkIdx < job.chunkTotal) {
        let lo = job.chunkIdx * chunkSize;
        let hi = Nat.min(lo + chunkSize, raw.size());
        let chunk = Array.tabulate<Nat8>(hi - lo, func(j) { raw[lo + j] });
        let gzipEncoder = Gzip.EncoderBuilder().build();
        gzipEncoder.encode(chunk);
        switch (gzipEncoder.finish()) {
          case (#single bytes) List.add(compressed, bytes);
          case (#chunked _) Runtime.trap("tickCompress: chunk exceeded outputChunkSize");
        };
        job.chunkIdx += 1;
        timerHandle := ?Timer.setTimer<system>(#nanoseconds 0, tickCompress);
      } else {
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
      let #decompress { chunks } = job.kind else {
        markJobFailed("decompress: wrong job kind");
        return;
      };
      let batchEnd = Nat.min(job.chunkIdx + DECODE_BATCH_SIZE, job.chunkTotal);
      label batch while (job.chunkIdx < batchEnd) {
        let gzipDecoder = Gzip.Decoder();
        switch (gzipDecoder.decode(chunks[job.chunkIdx])) {
          case (#err msg) { markJobFailed("decompress decode: " # msg); return };
          case (#ok _) {};
        };
        switch (gzipDecoder.finish()) {
          case (#err msg) { markJobFailed("decompress finish: " # msg); return };
          case (#ok result) List.add(decompressed, result.bytes);
        };
        job.chunkIdx += 1;
      };
      if (job.chunkIdx < job.chunkTotal) {
        timerHandle := ?Timer.setTimer<system>(#nanoseconds 0, tickDecompress);
      } else {
        markJobDone();
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
    let rng = Random.seed(42 : Nat64);
    let third = n_bytes / 3;
    rawData := ?Array.tabulate<Nat8>(
      n_bytes,
      func(i) {
        if (i < third) {
          0xAA;
        } else if (i < 2 * third) {
          rng.nat8();
        } else {
          Nat8.fromNat(i % 256);
        };
      },
    );
  };

  /// Return a 2 MiB page of the raw generated bytes (0-indexed).
  public query func getGeneratedData(page : Nat) : async [Nat8] {
    switch (rawData) {
      case (?d) pageOf(d, page);
      case null [];
    };
  };

  // ── Read Data ───────────────────────────────────────────────────────

  /// Return a 2 MiB page of the compressed output bytes (0-indexed).
  public query func getCompressedData(page : Nat) : async [Nat8] {
    if (List.size(compressed) == 0) return [];
    pageOf(Array.flatten<Nat8>(List.toArray(compressed)), page);
  };

  /// Return a 2 MiB page of the decompressed bytes (0-indexed).
  public query func getDecompressedData(page : Nat) : async [Nat8] {
    if (List.size(decompressed) == 0) return [];
    pageOf(Array.flatten<Nat8>(List.toArray(decompressed)), page);
  };

  // ── Direct (single-message) compress / decompress ────────────────────────

  /// Compress rawData in a single message (no timer). Best for small payloads
  /// that fit within the per-message instruction limit (~40 B instructions).
  public func compress() : async () {
    let bytes = switch (rawData) { case (?d) d; case null [] };
    List.clear(compressed);
    let gzipEncoder = Gzip.EncoderBuilder().build();
    gzipEncoder.encode(bytes);
    switch (gzipEncoder.finish()) {
      case (#single b) List.add(compressed, b);
      case (#chunked _) Runtime.trap("compress: chunk exceeded outputChunkSize");
    };
  };

  /// Decompress compressed data in a single message (no timer). Best for small payloads.
  public func decompress() : async () {
    if (List.size(compressed) == 0) Runtime.trap("decompress: no compressed data");
    List.clear(decompressed);
    let ?chunk = List.first(compressed) else Runtime.trap("decompress: unexpectedly more than one chunk");
    let gzipDecoder = Gzip.Decoder();
    switch (gzipDecoder.decode(chunk)) {
      case (#err msg) Runtime.trap("decompress decode: " # msg);
      case (#ok _) {};
    };
    switch (gzipDecoder.finish()) {
      case (#err msg) Runtime.trap("decompress finish: " # msg);
      case (#ok result) List.add(decompressed, result.bytes);
    };
  };

  // ── Job submission ────────────────────────────────────────────────────────

  /// Request a compression job. Returns the JobId immediately.
  /// Only one job may be active at a time — traps if one is already running.
  public func requestCompressJob() : async JobId {
    let null = jobState.activeJob else Runtime.trap("requestCompressJob: job already active");
    let id = jobState.nextJobId;
    jobState.nextJobId += 1;

    List.clear(compressed);
    let bytes = switch (rawData) { case (?d) d; case null [] };
    let n = bytes.size();
    let chunkTotal = if (n == 0 or ENCODE_CHUNK_SIZE == 0) 1 else n / ENCODE_CHUNK_SIZE + (if (n % ENCODE_CHUNK_SIZE != 0) 1 else 0);
    jobState.activeJob := ?{
      id;
      kind = #compress { chunkSize = ENCODE_CHUNK_SIZE };
      var chunkIdx = 0;
      chunkTotal;
    };

    timerHandle := ?Timer.setTimer<system>(#nanoseconds 0, tickCompress);
    id;
  };

  /// Request a decompression job. Returns the JobId immediately.
  /// Only one job may be active at a time — traps if one is already running.
  /// Traps if no compressed data is available.
  public func requestDecompressJob() : async JobId {
    let null = jobState.activeJob else Runtime.trap("requestDecompressJob: job already active");
    if (List.size(compressed) == 0) Runtime.trap("requestDecompressJob: no compressed data");
    List.clear(decompressed);

    let cs = List.toArray(compressed);
    let id = jobState.nextJobId;
    jobState.nextJobId += 1;

    jobState.activeJob := ?{
      id;
      kind = #decompress { chunks = cs };
      var chunkIdx = 0;
      chunkTotal = cs.size();
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
            case (#compress _) #compressing {
              index = job.chunkIdx;
              total = job.chunkTotal;
            };
            case (#decompress _) #decompressing {
              index = job.chunkIdx;
              total = job.chunkTotal;
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
    rawData := null;
    List.clear(compressed);
    List.clear(decompressed);
  };

};
