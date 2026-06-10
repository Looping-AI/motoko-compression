import Bench "mo:bench";
import Array "mo:core/Array";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Runtime "mo:core/Runtime";
import Text "mo:core/Text";

import Gzip "../src/Gzip";

module {
  func mixedPayload(size : Nat) : [Nat8] {
    let third = size / 3;
    var state : Nat = 2_463_534_242;
    Array.tabulate<Nat8>(size, func(i) {
      if (i < third) {
        // repetitive
        Nat8.fromNat(0xAA);
      } else if (i < third * 2) {
        // progressive
        Nat8.fromNat(i % 251);
      } else {
        // pseudo-random
        state := (state * 1_664_525 + 1_013_904_223) % 4_294_967_296;
        Nat8.fromNat((state / 16_777_216) % 256);
      }
    });
  };

  func chunked(bytes : [Nat8], chunkSize : Nat) : [[Nat8]] {
    let chunkCount : Nat = if (bytes.size() == 0) {
      0;
    } else {
      (bytes.size() + chunkSize - 1) / chunkSize;
    };
    Array.tabulate<[Nat8]>(chunkCount, func(i) {
      let start = i * chunkSize;
      let end = if (start + chunkSize > bytes.size()) bytes.size() else start + chunkSize;
      Array.tabulate<Nat8>(end - start, func(j) { bytes[start + j] });
    });
  };

  func compress(data : [Nat8]) : [Nat8] {
    let enc = Gzip.buildEncoder(Gzip.defaultOptions());
    enc.encode(data);
    enc.finish();
    let out = enc.compressed();
    enc.clear();
    out;
  };

  public func init() : Bench.Bench {
    let bench = Bench.Bench();
    let mixed1KiB = mixedPayload(1024);
    let mixed10KiB = mixedPayload(10_240);
    let mixed100KiB = mixedPayload(102_400);
    let mixed1MiB = mixedPayload(1_048_576);
    let mixed2MiB = mixedPayload(2_097_152);
    let mixed4MiB = mixedPayload(4_194_304);

    let compressedMixed1KiB = compress(mixed1KiB);
    let compressedMixed10KiB = compress(mixed10KiB);
    let compressedMixed100KiB = compress(mixed100KiB);
    let compressedMixed1MiB = compress(mixed1MiB);
    let compressedMixed2MiB = compress(mixed2MiB);
    let compressedMixed4MiB = compress(mixed4MiB);

    let mixed1KiBChunks1KiB = chunked(compressedMixed1KiB, 1024);
    let mixed10KiBChunks1KiB = chunked(compressedMixed10KiB, 1024);
    let mixed100KiBChunks1KiB = chunked(compressedMixed100KiB, 1024);
    let mixed1MiBChunks1KiB = chunked(compressedMixed1MiB, 1024);
    let mixed2MiBChunks1KiB = chunked(compressedMixed2MiB, 1024);
    let mixed4MiBChunks1KiB = chunked(compressedMixed4MiB, 1024);

    func compressedFor(size : Text) : [Nat8] {
      switch (size) {
        case ("1KiB") compressedMixed1KiB;
        case ("10KiB") compressedMixed10KiB;
        case ("100KiB") compressedMixed100KiB;
        case ("1MiB") compressedMixed1MiB;
        case ("2MiB") compressedMixed2MiB;
        case ("4MiB") compressedMixed4MiB;
        case (_) Runtime.trap("unexpected decoder size: " # size);
      };
    };

    func chunksFor(size : Text, mode : Text) : [[Nat8]] {
      switch (mode) {
        case ("1KiB chunks") {
          switch (size) {
            case ("1KiB") mixed1KiBChunks1KiB;
            case ("10KiB") mixed10KiBChunks1KiB;
            case ("100KiB") mixed100KiBChunks1KiB;
            case ("1MiB") mixed1MiBChunks1KiB;
            case ("2MiB") mixed2MiBChunks1KiB;
            case ("4MiB") mixed4MiBChunks1KiB;
            case (_) Runtime.trap("unexpected decoder size: " # size);
          };
        };
        case (_) Runtime.trap("unexpected decoder mode: " # mode);
      };
    };

    func feed(dec : Gzip.Decoder, chunks : [[Nat8]]) {
      for (chunk in chunks.vals()) {
        dec.decode(chunk);
      };
    };

    bench.name("Gzip Decoder");
    bench.description("Decode gzip payloads with one-shot and chunked feeds");
    bench.rows(["1KiB", "10KiB", "100KiB", "1MiB", "2MiB", "4MiB"]);
    bench.cols(["one-shot", "1KiB chunks"]);
    bench.runner(func(row, col) {
      let dec = Gzip.buildDecoder();
      switch (col) {
        case ("one-shot") {
          dec.decode(compressedFor(row));
        };
        case ("1KiB chunks") {
          feed(dec, chunksFor(row, col));
        };
        case (_) Runtime.trap("unexpected decoder mode: " # col);
      };
      switch (dec.finish()) {
        case (#err(msg)) Runtime.trap("decode failed: " # msg);
        case (#ok(_)) {};
      };
      ignore dec.decompressed();
      dec.clear();
    });

    bench;
  };
};
