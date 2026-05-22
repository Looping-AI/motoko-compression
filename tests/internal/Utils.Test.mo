import { test; suite; expect } "mo:test";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Utils "../../src/internal/utils";

// ── nat_to_le_bytes ────────────────────────────────────────────────────────

suite(
  "Utils.nat_to_le_bytes",
  func() {

    test(
      "zero fills with zeros",
      func() {
        let result = Utils.natToLeBytes(0, 4);
        expect.array(result, Nat8.toText, Nat8.equal).equal([0, 0, 0, 0]);
      },
    );

    test(
      "single byte value",
      func() {
        let result = Utils.natToLeBytes(42, 1);
        expect.array(result, Nat8.toText, Nat8.equal).equal([42]);
      },
    );

    test(
      "little-endian ordering: LSB first",
      func() {
        // 0x0102 = 258 → LE bytes [0x02, 0x01]
        let result = Utils.natToLeBytes(258, 2);
        expect.array(result, Nat8.toText, Nat8.equal).equal([2, 1]);
      },
    );

    test(
      "four-byte encoding",
      func() {
        // 0x01020304 = 16909060
        let result = Utils.natToLeBytes(16909060, 4);
        expect.array(result, Nat8.toText, Nat8.equal).equal([4, 3, 2, 1]);
      },
    );

    test(
      "extra bytes are zero-padded",
      func() {
        let result = Utils.natToLeBytes(1, 4);
        expect.array(result, Nat8.toText, Nat8.equal).equal([1, 0, 0, 0]);
      },
    );

  },
);

// ── le_bytes_to_nat ────────────────────────────────────────────────────────

suite(
  "Utils.le_bytes_to_nat",
  func() {

    test(
      "empty array returns 0",
      func() {
        expect.nat(Utils.leBytesToNat([])).equal(0);
      },
    );

    test(
      "single byte",
      func() {
        expect.nat(Utils.leBytesToNat([42])).equal(42);
      },
    );

    test(
      "two bytes little-endian",
      func() {
        // [0x02, 0x01] = 258
        expect.nat(Utils.leBytesToNat([2, 1])).equal(258);
      },
    );

    test(
      "four bytes little-endian",
      func() {
        // [0x04, 0x03, 0x02, 0x01] = 16909060
        expect.nat(Utils.leBytesToNat([4, 3, 2, 1])).equal(16909060);
      },
    );

    test(
      "roundtrip with nat_to_le_bytes",
      func() {
        let n = 123456789;
        let encoded = Utils.natToLeBytes(n, 4);
        expect.nat(Utils.leBytesToNat(encoded)).equal(n);
      },
    );

    test(
      "roundtrip preserves zero",
      func() {
        let encoded = Utils.natToLeBytes(0, 4);
        expect.nat(Utils.leBytesToNat(encoded)).equal(0);
      },
    );

  },
);
