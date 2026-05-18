/// Consolidated replica tests for trap behaviour across all modules.
///
/// A single TrapCanister is instantiated once and reused across all suites,
/// avoiding the multi-second canister-install overhead of separate test files.
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

    // ── BitReader traps ───────────────────────────────────────────────────

    await suite("BitReader traps — bounds checking", func() : async () {

      await test("peekBit traps on empty reader", func() : async () {
        var trapped = false;
        try { await helper.peekBitOnEmpty() } catch (err) {
          if (Error.code(err) == #canister_error) { trapped := true };
        };
        expect.bool(trapped).isTrue();
      });

      await test("readBits(9) traps when only 8 bits available", func() : async () {
        var trapped = false;
        try { await helper.readBitsOverflow() } catch (err) {
          if (Error.code(err) == #canister_error) { trapped := true };
        };
        expect.bool(trapped).isTrue();
      });

      await test("skipBits(9) traps when only 8 bits available", func() : async () {
        var trapped = false;
        try { await helper.skipBitsOverflow() } catch (err) {
          if (Error.code(err) == #canister_error) { trapped := true };
        };
        expect.bool(trapped).isTrue();
      });

      await test("peekByte traps on empty reader", func() : async () {
        var trapped = false;
        try { await helper.peekByteOnEmpty() } catch (err) {
          if (Error.code(err) == #canister_error) { trapped := true };
        };
        expect.bool(trapped).isTrue();
      });

    });

    // ── LZSS traps ────────────────────────────────────────────────────────

    await suite("LZSS decoder traps — invalid pointers", func() : async () {

      await test("decode #pointer with backward_offset > output size traps", func() : async () {
        var trapped = false;
        try { await helper.decodeBadOffset() } catch (err) {
          if (Error.code(err) == #canister_error) { trapped := true };
        };
        expect.bool(trapped).isTrue();
      });

    });

    // ── Deflate traps ─────────────────────────────────────────────────────

    await suite("Deflate encoder traps — invalid construction", func() : async () {

      await test("buildEncoder raw with block_size > 65535 traps", func() : async () {
        var trapped = false;
        try { await helper.buildEncoderRawOversized() } catch (err) {
          if (Error.code(err) == #canister_error) { trapped := true };
        };
        expect.bool(trapped).isTrue();
      });

    });

  };

};
