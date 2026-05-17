import { test; suite; expect } "mo:test";
import Iter "mo:core/Iter";
import Nat8 "mo:core/Nat8";
import Utils "../../src/utils";
import CircularBuffer "../../src/internal/CircularBuffer";

// ── helpers ───────────────────────────────────────────────────────────────

// Collect all elements of `buf` into an immutable array via values().
func toArray(buf : CircularBuffer.CircularBuffer) : [Nat8] {
  Iter.toArray(buf.values())
};

// ── size / capacity ───────────────────────────────────────────────────────

suite("CircularBuffer size and capacity", func() {

  test("capacity reflects construction argument", func() {
    let b = CircularBuffer.CircularBuffer(16);
    expect.nat(b.capacity()).equal(16);
  });

  test("size is 0 on a fresh buffer", func() {
    let b = CircularBuffer.CircularBuffer(8);
    expect.nat(b.size()).equal(0);
  });

  test("isFull is false on empty buffer", func() {
    let b = CircularBuffer.CircularBuffer(4);
    expect.bool(b.isFull()).isFalse();
  });

  test("size grows with each push up to capacity", func() {
    let b = CircularBuffer.CircularBuffer(4);
    b.push(1);
    expect.nat(b.size()).equal(1);
    b.push(2);
    expect.nat(b.size()).equal(2);
    b.push(3);
    b.push(4);
    expect.nat(b.size()).equal(4);
  });

  test("isFull becomes true once capacity is reached", func() {
    let b = CircularBuffer.CircularBuffer(3);
    b.push(1); b.push(2); b.push(3);
    expect.bool(b.isFull()).isTrue();
  });

  test("size stays at capacity after overflow pushes", func() {
    let b = CircularBuffer.CircularBuffer(4);
    for (_ in Utils.range(0, 10)) b.push(0x42);
    expect.nat(b.size()).equal(4);
    expect.bool(b.isFull()).isTrue();
  });

});

// ── push / get below capacity ─────────────────────────────────────────────

suite("CircularBuffer push/get below capacity", func() {

  test("single push, get(0) = that element", func() {
    let b = CircularBuffer.CircularBuffer(8);
    b.push(0xAB);
    expect.option(b.get(0), Nat8.toText, Nat8.equal).equal(?(0xAB : Nat8));
  });

  test("three pushes, oldest is get(0), newest is get(2)", func() {
    let b = CircularBuffer.CircularBuffer(8);
    b.push(10); b.push(20); b.push(30);
    expect.option(b.get(0), Nat8.toText, Nat8.equal).equal(?(10 : Nat8));
    expect.option(b.get(1), Nat8.toText, Nat8.equal).equal(?(20 : Nat8));
    expect.option(b.get(2), Nat8.toText, Nat8.equal).equal(?(30 : Nat8));
  });

  test("get(i >= size) returns null", func() {
    let b = CircularBuffer.CircularBuffer(8);
    b.push(0xFF);
    expect.option(b.get(1),   Nat8.toText, Nat8.equal).isNull();
    expect.option(b.get(100), Nat8.toText, Nat8.equal).isNull();
  });

  test("get on empty buffer always returns null", func() {
    let b = CircularBuffer.CircularBuffer(4);
    expect.option(b.get(0), Nat8.toText, Nat8.equal).isNull();
  });

});

// ── push exactly at capacity ──────────────────────────────────────────────

suite("CircularBuffer push exactly at capacity", func() {

  test("all slots accessible after filling cap=4 buffer", func() {
    let b = CircularBuffer.CircularBuffer(4);
    b.push(1); b.push(2); b.push(3); b.push(4);
    expect.option(b.get(0), Nat8.toText, Nat8.equal).equal(?(1 : Nat8));
    expect.option(b.get(1), Nat8.toText, Nat8.equal).equal(?(2 : Nat8));
    expect.option(b.get(2), Nat8.toText, Nat8.equal).equal(?(3 : Nat8));
    expect.option(b.get(3), Nat8.toText, Nat8.equal).equal(?(4 : Nat8));
    expect.nat(b.size()).equal(4);
  });

  test("values() after full fill matches push order", func() {
    let b = CircularBuffer.CircularBuffer(4);
    b.push(0xAA); b.push(0xBB); b.push(0xCC); b.push(0xDD);
    expect.array(toArray(b), Nat8.toText, Nat8.equal)
      .equal([0xAA, 0xBB, 0xCC, 0xDD]);
  });

});

// ── eviction on overflow ──────────────────────────────────────────────────

suite("CircularBuffer eviction on overflow", func() {

  test("push cap+1 elements: oldest evicted, size stays at cap", func() {
    let b = CircularBuffer.CircularBuffer(4);
    b.push(1); b.push(2); b.push(3); b.push(4);
    b.push(5); // evicts 1
    expect.nat(b.size()).equal(4);
    expect.option(b.get(0), Nat8.toText, Nat8.equal).equal(?(2 : Nat8));
    expect.option(b.get(3), Nat8.toText, Nat8.equal).equal(?(5 : Nat8));
  });

  test("sequential eviction: each new push evicts the next oldest", func() {
    let b = CircularBuffer.CircularBuffer(3);
    b.push(10); b.push(20); b.push(30); // full: [10,20,30]
    b.push(40); // evicts 10 → [20,30,40]
    expect.array(toArray(b), Nat8.toText, Nat8.equal).equal([20, 30, 40]);
    b.push(50); // evicts 20 → [30,40,50]
    expect.array(toArray(b), Nat8.toText, Nat8.equal).equal([30, 40, 50]);
    b.push(60); // evicts 30 → [40,50,60]
    expect.array(toArray(b), Nat8.toText, Nat8.equal).equal([40, 50, 60]);
  });

  test("wrap-around: push 2*cap elements, last cap retained", func() {
    let cap = 5;
    let b = CircularBuffer.CircularBuffer(cap);
    // push 0..9; last 5 are [5,6,7,8,9]
    for (i in Utils.range(0, 10)) b.push(Nat8.fromNat(i));
    expect.nat(b.size()).equal(cap);
    for (i in Utils.range(0, cap)) {
      expect.option(b.get(i), Nat8.toText, Nat8.equal)
        .equal(?(Nat8.fromNat(5 + i)));
    };
  });

  test("push 3*cap elements, last cap retained", func() {
    let cap = 4;
    let b = CircularBuffer.CircularBuffer(cap);
    // push 0..11; last 4 are [8,9,10,11]
    for (i in Utils.range(0, 12)) b.push(Nat8.fromNat(i));
    expect.nat(b.size()).equal(cap);
    expect.array(toArray(b), Nat8.toText, Nat8.equal).equal([8, 9, 10, 11]);
  });

  test("cap=1 always holds only the last pushed element", func() {
    let b = CircularBuffer.CircularBuffer(1);
    b.push(0xAA);
    expect.option(b.get(0), Nat8.toText, Nat8.equal).equal(?(0xAA : Nat8));
    b.push(0xBB);
    expect.option(b.get(0), Nat8.toText, Nat8.equal).equal(?(0xBB : Nat8));
    expect.nat(b.size()).equal(1);
  });

});

// ── values() iterator ─────────────────────────────────────────────────────

suite("CircularBuffer values()", func() {

  test("empty buffer yields nothing", func() {
    let b = CircularBuffer.CircularBuffer(4);
    expect.array(toArray(b), Nat8.toText, Nat8.equal).equal([]);
  });

  test("partial fill yields elements in push order", func() {
    let b = CircularBuffer.CircularBuffer(8);
    b.push(7); b.push(8); b.push(9);
    expect.array(toArray(b), Nat8.toText, Nat8.equal).equal([7, 8, 9]);
  });

  test("values() after overflow matches get() sequence", func() {
    let b = CircularBuffer.CircularBuffer(4);
    for (i in Utils.range(0, 7)) b.push(Nat8.fromNat(i)); // last 4: [3,4,5,6]
    let via_values = toArray(b);
    let via_get : [Nat8] = [
      switch (b.get(0)) { case (?v) v; case null (0xFF : Nat8) },
      switch (b.get(1)) { case (?v) v; case null (0xFF : Nat8) },
      switch (b.get(2)) { case (?v) v; case null (0xFF : Nat8) },
      switch (b.get(3)) { case (?v) v; case null (0xFF : Nat8) },
    ];
    expect.array(via_values, Nat8.toText, Nat8.equal).equal(via_get);
  });

  test("multiple values() calls on same buffer are independent", func() {
    let b = CircularBuffer.CircularBuffer(4);
    b.push(1); b.push(2); b.push(3);
    let first  = Iter.toArray(b.values());
    let second = Iter.toArray(b.values());
    expect.array(first, Nat8.toText, Nat8.equal).equal(second);
  });

});

// ── clear ────────────────────────────────────────────────────────────────

suite("CircularBuffer clear", func() {

  test("clear resets size to 0", func() {
    let b = CircularBuffer.CircularBuffer(4);
    b.push(1); b.push(2); b.push(3);
    b.clear();
    expect.nat(b.size()).equal(0);
    expect.bool(b.isFull()).isFalse();
  });

  test("get on cleared buffer returns null", func() {
    let b = CircularBuffer.CircularBuffer(4);
    b.push(0xFF); b.push(0xFF);
    b.clear();
    expect.option(b.get(0), Nat8.toText, Nat8.equal).isNull();
  });

  test("can push and read correctly after clear", func() {
    let b = CircularBuffer.CircularBuffer(4);
    b.push(0xAA); b.push(0xBB);
    b.clear();
    b.push(0x11); b.push(0x22);
    expect.array(toArray(b), Nat8.toText, Nat8.equal).equal([0x11, 0x22]);
    expect.nat(b.size()).equal(2);
  });

  test("clear after overflow then refill works correctly", func() {
    let b = CircularBuffer.CircularBuffer(3);
    b.push(1); b.push(2); b.push(3); b.push(4); // overflow once
    b.clear();
    b.push(0xAA); b.push(0xBB); b.push(0xCC);
    expect.array(toArray(b), Nat8.toText, Nat8.equal).equal([0xAA, 0xBB, 0xCC]);
  });

  test("capacity is unchanged by clear", func() {
    let b = CircularBuffer.CircularBuffer(8);
    b.push(1); b.push(2);
    b.clear();
    expect.nat(b.capacity()).equal(8);
  });

});

// ── LZSS sliding-window simulation ───────────────────────────────────────

suite("CircularBuffer LZSS sliding-window simulation", func() {

  test("32768-capacity window: push and read back last element", func() {
    let b = CircularBuffer.CircularBuffer(32768);
    b.push(0xDE);
    expect.option(b.get(0), Nat8.toText, Nat8.equal).equal(?(0xDE : Nat8));
    expect.nat(b.size()).equal(1);
  });

  test("filling 32768 window then checking oldest and newest", func() {
    let b = CircularBuffer.CircularBuffer(32768);
    for (i in Utils.range(0, 32768)) b.push(Nat8.fromNat(i % 256));
    expect.nat(b.size()).equal(32768);
    expect.bool(b.isFull()).isTrue();
    // oldest = i=0 → value 0
    expect.option(b.get(0), Nat8.toText, Nat8.equal).equal(?(0 : Nat8));
    // newest = i=32767 → 32767 % 256 = 255
    expect.option(b.get(32767), Nat8.toText, Nat8.equal).equal(?(255 : Nat8));
  });

  test("one overflow evicts exactly one element from 32768 window", func() {
    let b = CircularBuffer.CircularBuffer(32768);
    for (i in Utils.range(0, 32768)) b.push(Nat8.fromNat(i % 256));
    b.push(0x42); // evicts slot 0 (value 0)
    expect.nat(b.size()).equal(32768);
    // new oldest is i=1 → value 1
    expect.option(b.get(0), Nat8.toText, Nat8.equal).equal(?(1 : Nat8));
    // newest is 0x42
    expect.option(b.get(32767), Nat8.toText, Nat8.equal).equal(?(0x42 : Nat8));
  });

});
