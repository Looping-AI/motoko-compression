import { test; suite; expect } "mo:test";
import Iter "mo:core/Iter";
import Nat "mo:core/Nat";
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
