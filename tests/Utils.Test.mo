import { test; suite; expect } "mo:test";
import Iter "mo:core/Iter";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Utils "../src/utils";

// ── range ──────────────────────────────────────────────────────────────────

suite("Utils.range", func() {

  test("normal range produces correct sequence", func() {
    let result = Iter.toArray(Utils.range(0, 5));
    expect.array(result, Nat.toText, Nat.equal).equal([0, 1, 2, 3, 4]);
  });

  test("range from non-zero start", func() {
    let result = Iter.toArray(Utils.range(3, 7));
    expect.array(result, Nat.toText, Nat.equal).equal([3, 4, 5, 6]);
  });

  test("range(n, n) is empty", func() {
    let result = Iter.toArray(Utils.range(3, 3));
    expect.array(result, Nat.toText, Nat.equal).equal([]);
  });

  test("range(0, 0) is empty", func() {
    let result = Iter.toArray(Utils.range(0, 0));
    expect.array(result, Nat.toText, Nat.equal).equal([]);
  });

  test("range(0, 1) yields single element", func() {
    let result = Iter.toArray(Utils.range(0, 1));
    expect.array(result, Nat.toText, Nat.equal).equal([0]);
  });

  test("range end is exclusive", func() {
    let result = Iter.toArray(Utils.range(0, 3));
    // must NOT contain 3
    expect.array(result, Nat.toText, Nat.equal).equal([0, 1, 2]);
  });

  test("range lo > hi is empty", func() {
    let result = Iter.toArray(Utils.range(5, 2));
    expect.array(result, Nat.toText, Nat.equal).equal([]);
  });

});

// ── revRange ───────────────────────────────────────────────────────────────

suite("Utils.revRange", func() {

  test("normal revRange counts down", func() {
    let result = Iter.toArray(Utils.revRange(5, 0));
    expect.array(result, Nat.toText, Nat.equal).equal([4, 3, 2, 1, 0]);
  });

  test("revRange from partial range", func() {
    let result = Iter.toArray(Utils.revRange(7, 3));
    expect.array(result, Nat.toText, Nat.equal).equal([6, 5, 4, 3]);
  });

  test("revRange(n, n) is empty", func() {
    let result = Iter.toArray(Utils.revRange(3, 3));
    expect.array(result, Nat.toText, Nat.equal).equal([]);
  });

  test("revRange(0, 0) is empty", func() {
    let result = Iter.toArray(Utils.revRange(0, 0));
    expect.array(result, Nat.toText, Nat.equal).equal([]);
  });

  test("revRange(1, 0) yields single element zero", func() {
    let result = Iter.toArray(Utils.revRange(1, 0));
    expect.array(result, Nat.toText, Nat.equal).equal([0]);
  });

  test("revRange hi < lo is empty", func() {
    let result = Iter.toArray(Utils.revRange(2, 5));
    expect.array(result, Nat.toText, Nat.equal).equal([]);
  });

  test("revRange is reverse of range", func() {
    let forward = Iter.toArray(Utils.range(0, 5));
    let backward = Iter.toArray(Utils.revRange(5, 0));
    // forward reversed should equal backward
    var i = 0;
    for (v in backward.vals()) {
      expect.nat(v).equal(forward[4 - i]);
      i += 1;
    };
  });

});

// ── iterEqual ──────────────────────────────────────────────────────────────

suite("Utils.iterEqual", func() {

  test("equal sequences return true", func() {
    let a = [1, 2, 3].vals();
    let b = [1, 2, 3].vals();
    expect.bool(Utils.iterEqual(a, b, Nat.equal)).isTrue();
  });

  test("different values return false", func() {
    let a = [1, 2, 3].vals();
    let b = [1, 2, 4].vals();
    expect.bool(Utils.iterEqual(a, b, Nat.equal)).isFalse();
  });

  test("a shorter than b returns false", func() {
    let a = [1, 2].vals();
    let b = [1, 2, 3].vals();
    expect.bool(Utils.iterEqual(a, b, Nat.equal)).isFalse();
  });

  test("b shorter than a returns false", func() {
    let a = [1, 2, 3].vals();
    let b = [1, 2].vals();
    expect.bool(Utils.iterEqual(a, b, Nat.equal)).isFalse();
  });

  test("both empty return true", func() {
    let a = ([] : [Nat]).vals();
    let b = ([] : [Nat]).vals();
    expect.bool(Utils.iterEqual(a, b, Nat.equal)).isTrue();
  });

  test("one empty one non-empty return false", func() {
    let a = ([] : [Nat]).vals();
    let b = [1].vals();
    expect.bool(Utils.iterEqual(a, b, Nat.equal)).isFalse();
  });

  test("single-element equal sequences return true", func() {
    let a = [42].vals();
    let b = [42].vals();
    expect.bool(Utils.iterEqual(a, b, Nat.equal)).isTrue();
  });

  test("iterEqual uses provided eq function", func() {
    // custom eq that treats all values as equal
    let always = func(_ : Nat, _ : Nat) : Bool { true };
    let a = [1, 2, 3].vals();
    let b = [9, 9, 9].vals();
    expect.bool(Utils.iterEqual(a, b, always)).isTrue();
  });

  test("range iterators equal themselves", func() {
    expect.bool(Utils.iterEqual(Utils.range(0, 10), Utils.range(0, 10), Nat.equal)).isTrue();
  });

  test("range and revRange are not equal", func() {
    expect.bool(Utils.iterEqual(Utils.range(0, 5), Utils.revRange(5, 0), Nat.equal)).isFalse();
  });

});

// ── INSTRUCTION_LIMIT ──────────────────────────────────────────────────────

suite("Utils.INSTRUCTION_LIMIT", func() {

  test("value is 1_048_576", func() {
    expect.nat(Utils.INSTRUCTION_LIMIT).equal(1_048_576);
  });

});

// ── div_ceil ───────────────────────────────────────────────────────────────

suite("Utils.div_ceil", func() {

  test("10 / 3 = ceil 4", func() {
    expect.nat(Utils.div_ceil(10, 3)).equal(4);
  });

  test("exact division returns quotient", func() {
    expect.nat(Utils.div_ceil(9, 3)).equal(3);
  });

  test("divisor larger than num returns 1", func() {
    expect.nat(Utils.div_ceil(1, 5)).equal(1);
  });

  test("0 / any returns 0", func() {
    expect.nat(Utils.div_ceil(0, 7)).equal(0);
  });

  test("div_ceil(n, 1) = n", func() {
    expect.nat(Utils.div_ceil(100, 1)).equal(100);
  });

});

// ── nat_to_le_bytes ────────────────────────────────────────────────────────

suite("Utils.nat_to_le_bytes", func() {

  test("zero fills with zeros", func() {
    let result = Utils.nat_to_le_bytes(0, 4);
    expect.array(result, Nat8.toText, Nat8.equal).equal([0, 0, 0, 0]);
  });

  test("single byte value", func() {
    let result = Utils.nat_to_le_bytes(42, 1);
    expect.array(result, Nat8.toText, Nat8.equal).equal([42]);
  });

  test("little-endian ordering: LSB first", func() {
    // 0x0102 = 258 → LE bytes [0x02, 0x01]
    let result = Utils.nat_to_le_bytes(258, 2);
    expect.array(result, Nat8.toText, Nat8.equal).equal([2, 1]);
  });

  test("four-byte encoding", func() {
    // 0x01020304 = 16909060
    let result = Utils.nat_to_le_bytes(16909060, 4);
    expect.array(result, Nat8.toText, Nat8.equal).equal([4, 3, 2, 1]);
  });

  test("extra bytes are zero-padded", func() {
    let result = Utils.nat_to_le_bytes(1, 4);
    expect.array(result, Nat8.toText, Nat8.equal).equal([1, 0, 0, 0]);
  });

});

// ── bytes_to_nat ───────────────────────────────────────────────────────────

suite("Utils.bytes_to_nat", func() {

  test("empty array returns 0", func() {
    expect.nat(Utils.bytes_to_nat([])).equal(0);
  });

  test("single byte", func() {
    expect.nat(Utils.bytes_to_nat([42])).equal(42);
  });

  test("two bytes big-endian", func() {
    // [0x01, 0x02] = 258
    expect.nat(Utils.bytes_to_nat([1, 2])).equal(258);
  });

  test("four bytes big-endian", func() {
    // [0x01, 0x02, 0x03, 0x04] = 16909060
    expect.nat(Utils.bytes_to_nat([1, 2, 3, 4])).equal(16909060);
  });

});

// ── le_bytes_to_nat ────────────────────────────────────────────────────────

suite("Utils.le_bytes_to_nat", func() {

  test("empty array returns 0", func() {
    expect.nat(Utils.le_bytes_to_nat([])).equal(0);
  });

  test("single byte", func() {
    expect.nat(Utils.le_bytes_to_nat([42])).equal(42);
  });

  test("two bytes little-endian", func() {
    // [0x02, 0x01] = 258
    expect.nat(Utils.le_bytes_to_nat([2, 1])).equal(258);
  });

  test("four bytes little-endian", func() {
    // [0x04, 0x03, 0x02, 0x01] = 16909060
    expect.nat(Utils.le_bytes_to_nat([4, 3, 2, 1])).equal(16909060);
  });

  test("roundtrip with nat_to_le_bytes", func() {
    let n = 123456789;
    let encoded = Utils.nat_to_le_bytes(n, 4);
    expect.nat(Utils.le_bytes_to_nat(encoded)).equal(n);
  });

  test("roundtrip preserves zero", func() {
    let encoded = Utils.nat_to_le_bytes(0, 4);
    expect.nat(Utils.le_bytes_to_nat(encoded)).equal(0);
  });

});

// ── array_equal ────────────────────────────────────────────────────────────

suite("Utils.array_equal", func() {

  let natEq = Utils.array_equal<Nat>(Nat.equal);

  test("two empty arrays are equal", func() {
    expect.bool(natEq([], [])).isTrue();
  });

  test("equal arrays return true", func() {
    expect.bool(natEq([1, 2, 3], [1, 2, 3])).isTrue();
  });

  test("arrays with different values return false", func() {
    expect.bool(natEq([1, 2, 3], [1, 2, 4])).isFalse();
  });

  test("arrays of different lengths return false", func() {
    expect.bool(natEq([1, 2], [1, 2, 3])).isFalse();
  });

  test("uses provided equality function", func() {
    let alwaysEq = Utils.array_equal<Nat>(func(_, _) = true);
    expect.bool(alwaysEq([1, 2], [9, 9])).isTrue();
  });

});

