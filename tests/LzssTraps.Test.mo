/// Replica test for LZSS decoder trap behaviour.
///
/// `expect.call(...).reject()` only catches #canister_reject (thrown errors).
/// Traps surface as #canister_error and must be tested with a manual try/catch
/// that checks `Error.code(err) == #canister_error`.

import { test; suite; expect } "mo:test/async";
import Error "mo:core/Error";
import TrapCanister "helpers/TrapCanister";

persistent actor {

  public func runTests() : async () {
    let helper = await (with cycles = 10_000_000_000_000) TrapCanister.TrapCanister();

    await suite("LZSS decoder traps — invalid pointers", func() : async () {

      await test("decode #pointer with backward_offset > output size traps", func() : async () {
        var trapped = false;
        try {
          await helper.decodeBadOffset();
        } catch (err) {
          if (Error.code(err) == #canister_error) { trapped := true };
        };
        expect.bool(trapped).isTrue();
      });

    });

  };

};
