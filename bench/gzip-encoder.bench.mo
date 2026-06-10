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
    Array.tabulate<Nat8>(
      size,
      func(i) {
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
        };
      },
    );
  };

  func repetitivePayload(size : Nat) : [Nat8] {
    Array.tabulate<Nat8>(size, func(_) { Nat8.fromNat(0xAB) });
  };

  func incompressiblePayload(size : Nat) : [Nat8] {
    var state : Nat = 2_463_534_242;
    Array.tabulate<Nat8>(
      size,
      func(_) {
        state := (state * 1_664_525 + 1_013_904_223) % 4_294_967_296;
        Nat8.fromNat((state / 16_777_216) % 256);
      },
    );
  };

  public func init() : Bench.Bench {
    let bench = Bench.Bench();
    let defaultOpts = Gzip.defaultOptions();

    let mixed1KiB = mixedPayload(1024);
    let mixed10KiB = mixedPayload(10_240);
    let mixed100KiB = mixedPayload(102_400);
    let mixed1MiB = mixedPayload(1_048_576);

    let repetitive1KiB = repetitivePayload(1024);
    let repetitive10KiB = repetitivePayload(10_240);
    let repetitive100KiB = repetitivePayload(102_400);
    let repetitive1MiB = repetitivePayload(1_048_576);

    let incompressible1KiB = incompressiblePayload(1024);
    let incompressible10KiB = incompressiblePayload(10_240);
    let incompressible100KiB = incompressiblePayload(102_400);
    let incompressible1MiB = incompressiblePayload(1_048_576);

    func payloadFor(profile : Text, size : Text) : [Nat8] {
      switch (profile) {
        case ("mixed") {
          switch (size) {
            case ("1KiB") mixed1KiB;
            case ("10KiB") mixed10KiB;
            case ("100KiB") mixed100KiB;
            case ("1MiB") mixed1MiB;
            case (_) Runtime.trap("unexpected encoder size: " # size);
          };
        };
        case ("repetitive") {
          switch (size) {
            case ("1KiB") repetitive1KiB;
            case ("10KiB") repetitive10KiB;
            case ("100KiB") repetitive100KiB;
            case ("1MiB") repetitive1MiB;
            case (_) Runtime.trap("unexpected encoder size: " # size);
          };
        };
        case ("incompressible") {
          switch (size) {
            case ("1KiB") incompressible1KiB;
            case ("10KiB") incompressible10KiB;
            case ("100KiB") incompressible100KiB;
            case ("1MiB") incompressible1MiB;
            case (_) Runtime.trap("unexpected encoder size: " # size);
          };
        };
        case (_) Runtime.trap("unexpected encoder profile: " # profile);
      };
    };

    bench.name("Gzip Encoder");
    bench.description("Compress mixed, repetitive, and incompressible payloads");
    bench.rows(["repetitive", "mixed", "incompressible"]);
    bench.cols(["1KiB", "10KiB", "100KiB", "1MiB"]);
    bench.runner(
      func(row, col) {
        let data = payloadFor(row, col);
        let enc = Gzip.buildEncoder(defaultOpts);
        enc.encode(data);
        enc.finish();
        ignore enc.compressed();
        enc.clear();
      }
    );

    bench;
  };
};
