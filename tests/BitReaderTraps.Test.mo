/// Replica test for BitReader trap behaviour.
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

    await suite("BitReader traps — bounds checking", func() : async () {

      await test("peekBit traps on empty reader", func() : async () {
        var trapped = false;
        try {
          await helper.peekBitOnEmpty();
        } catch (err) {
          if (Error.code(err) == #canister_error) { trapped := true };
        };
        expect.bool(trapped).isTrue();
      });

      await test("readBits(9) traps when only 8 bits available", func() : async () {
        var trapped = false;
        try {
          await helper.readBitsOverflow();
        } catch (err) {
          if (Error.code(err) == #canister_error) { trapped := true };
        };
        expect.bool(trapped).isTrue();
      });

      await test("skipBits(9) traps when only 8 bits available", func() : async () {
        var trapped = false;
        try {
          await helper.skipBitsOverflow();
        } catch (err) {
          if (Error.code(err) == #canister_error) { trapped := true };
        };
        expect.bool(trapped).isTrue();
      });

      await test("peekByte traps on empty reader", func() : async () {
        var trapped = false;
        try {
          await helper.peekByteOnEmpty();
        } catch (err) {
          if (Error.code(err) == #canister_error) { trapped := true };
        };
        expect.bool(trapped).isTrue();
      });

    });

  };

};
