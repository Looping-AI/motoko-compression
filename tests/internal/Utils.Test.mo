import { test; suite; expect } "mo:test";
import Iter "mo:core/Iter";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Utils "../../src/internal/utils";

// ── range ──────────────────────────────────────────────────────────────────

suite(
  "Utils.range",
  func() {

    test(
      "normal range produces correct sequence",
      func() {
        let result = Iter.toArray(Utils.range(0, 5));
        expect.array(result, Nat.toText, Nat.equal).equal([0, 1, 2, 3, 4]);
      },
    );

    test(
      "range from non-zero start",
      func() {
        let result = Iter.toArray(Utils.range(3, 7));
        expect.array(result, Nat.toText, Nat.equal).equal([3, 4, 5, 6]);
      },
    );

    test(
      "range(n, n) is empty",
      func() {
        let result = Iter.toArray(Utils.range(3, 3));
        expect.array(result, Nat.toText, Nat.equal).equal([]);
      },
    );

    test(
      "range(0, 0) is empty",
      func() {
        let result = Iter.toArray(Utils.range(0, 0));
        expect.array(result, Nat.toText, Nat.equal).equal([]);
      },
    );

    test(
      "range(0, 1) yields single element",
      func() {
        let result = Iter.toArray(Utils.range(0, 1));
        expect.array(result, Nat.toText, Nat.equal).equal([0]);
      },
    );

    test(
      "range end is exclusive",
      func() {
        let result = Iter.toArray(Utils.range(0, 3));
        // must NOT contain 3
        expect.array(result, Nat.toText, Nat.equal).equal([0, 1, 2]);
      },
    );

    test(
      "range lo > hi is empty",
      func() {
        let result = Iter.toArray(Utils.range(5, 2));
        expect.array(result, Nat.toText, Nat.equal).equal([]);
      },
    );

  },
);

// ── revRange ───────────────────────────────────────────────────────────────

suite(
  "Utils.revRange",
  func() {

    test(
      "normal revRange counts down",
      func() {
        let result = Iter.toArray(Utils.revRange(5, 0));
        expect.array(result, Nat.toText, Nat.equal).equal([4, 3, 2, 1, 0]);
      },
    );

    test(
      "revRange from partial range",
      func() {
        let result = Iter.toArray(Utils.revRange(7, 3));
        expect.array(result, Nat.toText, Nat.equal).equal([6, 5, 4, 3]);
      },
    );

    test(
      "revRange(n, n) is empty",
      func() {
        let result = Iter.toArray(Utils.revRange(3, 3));
        expect.array(result, Nat.toText, Nat.equal).equal([]);
      },
    );

    test(
      "revRange(0, 0) is empty",
      func() {
        let result = Iter.toArray(Utils.revRange(0, 0));
        expect.array(result, Nat.toText, Nat.equal).equal([]);
      },
    );

    test(
      "revRange(1, 0) yields single element zero",
      func() {
        let result = Iter.toArray(Utils.revRange(1, 0));
        expect.array(result, Nat.toText, Nat.equal).equal([0]);
      },
    );

    test(
      "revRange hi < lo is empty",
      func() {
        let result = Iter.toArray(Utils.revRange(2, 5));
        expect.array(result, Nat.toText, Nat.equal).equal([]);
      },
    );

    test(
      "revRange is reverse of range",
      func() {
        let forward = Iter.toArray(Utils.range(0, 5));
        let backward = Iter.toArray(Utils.revRange(5, 0));
        // forward reversed should equal backward
        var i = 0;
        for (v in backward.vals()) {
          expect.nat(v).equal(forward[4 - i]);
          i += 1;
        };
      },
    );

  },
);

// ── INSTRUCTION_LIMIT ──────────────────────────────────────────────────────

suite(
  "Utils.INSTRUCTION_LIMIT",
  func() {

    test(
      "value is 1_048_576",
      func() {
        expect.nat(Utils.INSTRUCTION_LIMIT).equal(1_048_576);
      },
    );

  },
);

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
