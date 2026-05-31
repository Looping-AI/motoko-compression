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

  // ── Constants ─────────────────────────────────────────────────────────────

  transient let MB = 1_024 * 1_024;

  transient let PAGE_SIZE : Nat = 2 * MB - 512;

  // ── Stable state ──────────────────────────────────────────────────────────

  var rawData : ?[Nat8] = null;
  var compressed : ?Gzip.EncodedResponse = null;
  var decompressed : ?[Nat8] = null;

  // Job queue
  var nextJobId : Nat = 0;
  var activeJobId : ?Nat = null;
  var jobKind : { #compress; #decompress } = #compress;
  var chunkIdx : Nat = 0;
  var chunkTotal : Nat = 0;
  var completedJobs : [(Nat, CompletedJob)] = [];

  // ── Transient state ───────────────────────────────────────────────────────

  transient let gzipEncoder = Gzip.EncoderBuilder().build();

  // Fixed Huffman maps bytes 0x90–0xFF to 9-bit codes → up to 12.5% expansion on
  // incompressible data. Keep input slices at 7/8 of outputChunkSize so that
  // finish() always returns #single regardless of byte-value distribution.
  transient let ENCODE_CHUNK_SIZE : Nat = gzipEncoder.outputChunkSize() * 7 / 8;

  transient let gzipDecoder = Gzip.Decoder();

  transient let compressBuf = List.empty<[Nat8]>();

  transient let decompressBuf = List.empty<Nat8>();

  /// Pre-split chunks for the active job (compress input or decompress input).
  transient var activeChunks : ?[[Nat8]] = null;

  transient var timerHandle : ?Timer.TimerId = null;

  // ── Helpers ───────────────────────────────────────────────────────────────

  func splitChunks(bytes : [Nat8], size : Nat) : [[Nat8]] {
    let n = bytes.size();
    if (n == 0 or size == 0) return [bytes];
    let count = n / size + (if (n % size != 0) 1 else 0);
    Array.tabulate<[Nat8]>(
      count,
      func(i) {
        let lo = i * size;
        let hi = Nat.min(lo + size, n);
        Array.tabulate<Nat8>(hi - lo, func(j) { bytes[lo + j] });
      },
    );
  };

  func pageOf(bytes : [Nat8], page : Nat) : [Nat8] {
    let lo = page * PAGE_SIZE;
    let n = bytes.size();
    if (lo >= n) return [];
    let hi = Nat.min(lo + PAGE_SIZE, n);
    Array.tabulate<Nat8>(hi - lo, func(i) { bytes[lo + i] });
  };

  // ── Job lifecycle ─────────────────────────────────────────────────────────

  func markJobDone() {
    switch (activeJobId) {
      case (?id) {
        completedJobs := Array.concat(completedJobs, [(id, #done)]);
        activeJobId := null;
        activeChunks := null;
        timerHandle := null;
      };
      case null {};
    };
  };

  func markJobFailed(msg : Text) {
    switch (activeJobId) {
      case (?id) {
        completedJobs := Array.concat(completedJobs, [(id, #failed msg)]);
        activeJobId := null;
        activeChunks := null;
        timerHandle := null;
        gzipDecoder.clear();
      };
      case null {};
    };
  };

  // ── Timer callbacks ───────────────────────────────────────────────────────

  func tickCompress() : async () {
    var trapped = true;
    try {
      let ?cs = activeChunks else {
        markJobFailed("compress: no input chunks");
        return;
      };
      if (chunkIdx < chunkTotal) {
        gzipEncoder.clear();
        gzipEncoder.encode(cs[chunkIdx]);
        switch (gzipEncoder.finish()) {
          case (#single bytes) List.add(compressBuf, bytes);
          case (#chunked _) Runtime.trap("tickCompress: chunk exceeded outputChunkSize");
        };
        chunkIdx += 1;
        timerHandle := ?Timer.setTimer<system>(#nanoseconds 0, tickCompress);
      } else {
        let streams = List.toArray(compressBuf);
        List.clear(compressBuf);
        compressed := ?(if (streams.size() == 1) #single(streams[0]) else #chunked(streams));
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
      let ?cs = activeChunks else {
        markJobFailed("decompress: no input chunks");
        return;
      };
      if (chunkIdx < chunkTotal) {
        switch (gzipDecoder.decode(cs[chunkIdx])) {
          case (#err msg) { markJobFailed("decompress decode: " # msg); return };
          case (#ok _) {};
        };
        switch (gzipDecoder.finish()) {
          case (#err msg) { markJobFailed("decompress finish: " # msg); return };
          case (#ok result) List.addAll(decompressBuf, result.bytes.vals());
        };
        chunkIdx += 1;
        timerHandle := ?Timer.setTimer<system>(#nanoseconds 0, tickDecompress);
      } else {
        decompressed := ?List.toArray(decompressBuf);
        List.clear(decompressBuf);
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
    if (activeJobId != null) {
      markJobFailed("canister upgraded mid-job");
    };
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

  /// Return a 2 MiB page of the compressed output bytes (0-indexed).
  public query func getCompressedData(page : Nat) : async [Nat8] {
    let ?comp = compressed else return [];
    let bytes = switch (comp) {
      case (#single data) data;
      case (#chunked cs) Array.flatten<Nat8>(cs);
    };
    pageOf(bytes, page);
  };

  // ── Direct (single-message) compress / decompress ────────────────────────

  /// Compress rawData in a single message (no timer). Best for small payloads
  /// that fit within the per-message instruction limit (~40 B instructions).
  public func compress() : async () {
    let bytes = switch (rawData) { case (?d) d; case null [] };
    let cs = splitChunks(bytes, ENCODE_CHUNK_SIZE);
    List.clear(compressBuf);
    for (chunk in cs.vals()) {
      gzipEncoder.clear();
      gzipEncoder.encode(chunk);
      switch (gzipEncoder.finish()) {
        case (#single b) List.add(compressBuf, b);
        case (#chunked _) Runtime.trap("compress: chunk exceeded outputChunkSize");
      };
    };
    let streams = List.toArray(compressBuf);
    compressed := ?(if (streams.size() == 1) #single(streams[0]) else #chunked(streams));
  };

  /// Decompress compressed data in a single message (no timer). Best for small payloads.
  public func decompress() : async () {
    let ?comp = compressed else Runtime.trap("decompress: no compressed data");
    let cs = switch (comp) {
      case (#single d) [d];
      case (#chunked chunks) chunks;
    };
    gzipDecoder.clear();
    List.clear(decompressBuf);
    for (chunk in cs.vals()) {
      switch (gzipDecoder.decode(chunk)) {
        case (#err msg) Runtime.trap("decompress decode: " # msg);
        case (#ok _) {};
      };
      switch (gzipDecoder.finish()) {
        case (#err msg) Runtime.trap("decompress finish: " # msg);
        case (#ok result) List.addAll(decompressBuf, result.bytes.vals());
      };
    };
    decompressed := ?List.toArray(decompressBuf);
  };

  // ── Job submission ────────────────────────────────────────────────────────

  /// Request a compression job. Returns the JobId immediately.
  /// Only one job may be active at a time — traps if one is already running.
  public func requestCompressJob() : async JobId {
    assert activeJobId == null;
    let id = nextJobId;
    nextJobId += 1;

    let bytes = switch (rawData) { case (?d) d; case null [] };
    let cs = splitChunks(bytes, ENCODE_CHUNK_SIZE);
    activeChunks := ?cs;
    chunkIdx := 0;
    chunkTotal := cs.size();
    jobKind := #compress;
    activeJobId := ?id;
    List.clear(compressBuf);

    timerHandle := ?Timer.setTimer<system>(#nanoseconds 0, tickCompress);
    id;
  };

  /// Request a decompression job. Returns the JobId immediately.
  /// Only one job may be active at a time — traps if one is already running.
  /// Traps if no compressed data is available.
  public func requestDecompressJob() : async JobId {
    assert activeJobId == null;
    let ?comp = compressed else Runtime.trap("requestDecompressJob: no compressed data");
    let id = nextJobId;
    nextJobId += 1;

    let cs = switch (comp) {
      case (#single d) [d];
      case (#chunked chunks) chunks;
    };
    activeChunks := ?cs;
    chunkIdx := 0;
    chunkTotal := cs.size();
    jobKind := #decompress;
    activeJobId := ?id;
    gzipDecoder.clear();
    List.clear(decompressBuf);

    timerHandle := ?Timer.setTimer<system>(#nanoseconds 0, tickDecompress);
    id;
  };

  // ── Job status & management ───────────────────────────────────────────────

  /// Poll the status of a job by its JobId.
  /// Returns `null` if the id is unknown (never submitted or already cleared).
  public query func getJobStatus(id : JobId) : async ?JobStatus {
    if (activeJobId == ?id) {
      return ?(
        switch (jobKind) {
          case (#compress) #compressing { index = chunkIdx; total = chunkTotal };
          case (#decompress) #decompressing {
            index = chunkIdx;
            total = chunkTotal;
          };
        }
      );
    };
    for ((jid, status) in completedJobs.vals()) {
      if (jid == id) {
        return ?(
          switch (status) {
            case (#done) #done;
            case (#failed msg) #failed msg;
          }
        );
      };
    };
    null;
  };

  /// Discard a completed job record, freeing its slot in the history.
  public func clearJob(id : JobId) : async () {
    completedJobs := Array.filter<(Nat, CompletedJob)>(
      completedJobs,
      func((jid, _)) { jid != id },
    );
  };

  // ── Result retrieval ──────────────────────────────────────────────────────

  /// Return a 2 MiB page of the decompressed bytes (0-indexed).
  public query func getDecompressedData(page : Nat) : async [Nat8] {
    let ?d = decompressed else return [];
    pageOf(d, page);
  };

};
