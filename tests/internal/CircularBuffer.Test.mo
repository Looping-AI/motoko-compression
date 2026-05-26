import { test; suite; expect } "mo:test";
import Array "mo:core/Array";
import Nat8 "mo:core/Nat8";
import Nat32 "mo:core/Nat32";
import CircularBuffer "../../src/internal/CircularBuffer";

// ── helpers ───────────────────────────────────────────────────────────────

// Collect all elements of `buf` into an immutable array.
func toArray(buf : CircularBuffer.CircularBuffer) : [Nat8] {
  Array.tabulate<Nat8>(
    buf.size(),
    func(i) {
      buf.getUnchecked(Nat32.fromNat(i));
    },
  );
};

// ── size / capacity ───────────────────────────────────────────────────────

suite(
  "CircularBuffer size and capacity",
  func() {

    test(
      "size is 0 on a fresh buffer",
      func() {
        let b = CircularBuffer.CircularBuffer(8);
        expect.nat(b.size()).equal(0);
      },
    );

    test(
      "size grows with each push up to capacity",
      func() {
        let b = CircularBuffer.CircularBuffer(4);
        b.push(1);
        expect.nat(b.size()).equal(1);
        b.push(2);
        expect.nat(b.size()).equal(2);
        b.push(3);
        b.push(4);
        expect.nat(b.size()).equal(4);
      },
    );

    test(
      "size stays at capacity after overflow pushes",
      func() {
        let b = CircularBuffer.CircularBuffer(4);
        var _j = 0;
        while (_j < 10) { b.push(0x42); _j += 1 };
        expect.nat(b.size()).equal(4);
      },
    );

  },
);

// ── push / get below capacity ─────────────────────────────────────────────

suite(
  "CircularBuffer push/get below capacity",
  func() {

    test(
      "single push, get(0) = that element",
      func() {
        let b = CircularBuffer.CircularBuffer(8);
        b.push(0xAB);
        expect.nat8(b.getUnchecked(0)).equal(0xAB);
      },
    );

    test(
      "three pushes, oldest is get(0), newest is get(2)",
      func() {
        let b = CircularBuffer.CircularBuffer(8);
        b.push(10);
        b.push(20);
        b.push(30);
        expect.nat8(b.getUnchecked(0)).equal(10);
        expect.nat8(b.getUnchecked(1)).equal(20);
        expect.nat8(b.getUnchecked(2)).equal(30);
      },
    );

  },
);

// ── push exactly at capacity ──────────────────────────────────────────────

suite(
  "CircularBuffer push exactly at capacity",
  func() {

    test(
      "all slots accessible after filling cap=4 buffer",
      func() {
        let b = CircularBuffer.CircularBuffer(4);
        b.push(1);
        b.push(2);
        b.push(3);
        b.push(4);
        expect.nat8(b.getUnchecked(0)).equal(1);
        expect.nat8(b.getUnchecked(1)).equal(2);
        expect.nat8(b.getUnchecked(2)).equal(3);
        expect.nat8(b.getUnchecked(3)).equal(4);
        expect.nat(b.size()).equal(4);
      },
    );

    test(
      "push order preserved after full fill",
      func() {
        let b = CircularBuffer.CircularBuffer(4);
        b.push(0xAA);
        b.push(0xBB);
        b.push(0xCC);
        b.push(0xDD);
        expect.array(toArray(b), Nat8.toText, Nat8.equal).equal([0xAA, 0xBB, 0xCC, 0xDD]);
      },
    );

  },
);

// ── eviction on overflow ──────────────────────────────────────────────────

suite(
  "CircularBuffer eviction on overflow",
  func() {

    test(
      "push cap+1 elements: oldest evicted, size stays at cap",
      func() {
        let b = CircularBuffer.CircularBuffer(4);
        b.push(1);
        b.push(2);
        b.push(3);
        b.push(4);
        b.push(5); // evicts 1
        expect.nat(b.size()).equal(4);
        expect.nat8(b.getUnchecked(0)).equal(2);
        expect.nat8(b.getUnchecked(3)).equal(5);
      },
    );

    test(
      "sequential eviction: each new push evicts the next oldest",
      func() {
        let b = CircularBuffer.CircularBuffer(4);
        b.push(10);
        b.push(20);
        b.push(30);
        b.push(40); // full: [10,20,30,40]
        b.push(50); // evicts 10 → [20,30,40,50]
        expect.array(toArray(b), Nat8.toText, Nat8.equal).equal([20, 30, 40, 50]);
        b.push(60); // evicts 20 → [30,40,50,60]
        expect.array(toArray(b), Nat8.toText, Nat8.equal).equal([30, 40, 50, 60]);
        b.push(70); // evicts 30 → [40,50,60,70]
        expect.array(toArray(b), Nat8.toText, Nat8.equal).equal([40, 50, 60, 70]);
      },
    );

    test(
      "wrap-around: push 2*cap elements, last cap retained",
      func() {
        let cap = 8;
        let b = CircularBuffer.CircularBuffer(cap);
        // push 0..15; last 8 are [8,9,10,11,12,13,14,15]
        var i = 0;
        while (i < 16) { b.push(Nat8.fromNat(i)); i += 1 };
        expect.nat(b.size()).equal(cap);
        var j = 0;
        while (j < cap) {
          expect.nat8(b.getUnchecked(Nat32.fromNat(j))).equal(Nat8.fromNat(8 + j));
          j += 1;
        };
      },
    );

    test(
      "push 3*cap elements, last cap retained",
      func() {
        let cap = 4;
        let b = CircularBuffer.CircularBuffer(cap);
        // push 0..11; last 4 are [8,9,10,11]
        var i = 0;
        while (i < 12) { b.push(Nat8.fromNat(i)); i += 1 };
        expect.nat(b.size()).equal(cap);
        expect.array(toArray(b), Nat8.toText, Nat8.equal).equal([8, 9, 10, 11]);
      },
    );

    test(
      "cap=1 always holds only the last pushed element",
      func() {
        let b = CircularBuffer.CircularBuffer(1);
        b.push(0xAA);
        expect.nat8(b.getUnchecked(0)).equal(0xAA);
        b.push(0xBB);
        expect.nat8(b.getUnchecked(0)).equal(0xBB);
        expect.nat(b.size()).equal(1);
      },
    );

  },
);

// ── clear ────────────────────────────────────────────────────────────────

suite(
  "CircularBuffer clear",
  func() {

    test(
      "clear resets size to 0",
      func() {
        let b = CircularBuffer.CircularBuffer(4);
        b.push(1);
        b.push(2);
        b.push(3);
        b.clear();
        expect.nat(b.size()).equal(0);
      },
    );

    test(
      "can push and read correctly after clear",
      func() {
        let b = CircularBuffer.CircularBuffer(4);
        b.push(0xAA);
        b.push(0xBB);
        b.clear();
        b.push(0x11);
        b.push(0x22);
        expect.array(toArray(b), Nat8.toText, Nat8.equal).equal([0x11, 0x22]);
        expect.nat(b.size()).equal(2);
      },
    );

    test(
      "clear after overflow then refill works correctly",
      func() {
        let b = CircularBuffer.CircularBuffer(4);
        b.push(1);
        b.push(2);
        b.push(3);
        b.push(4);
        b.push(5); // overflow once
        b.clear();
        b.push(0xAA);
        b.push(0xBB);
        b.push(0xCC);
        b.push(0xDD);
        expect.array(toArray(b), Nat8.toText, Nat8.equal).equal([0xAA, 0xBB, 0xCC, 0xDD]);
      },
    );

  },
);

// ── popFront ────────────────────────────────────────────────────────────

suite(
  "CircularBuffer popFront",
  func() {

    test(
      "popFrontUnchecked removes oldest element and shrinks size",
      func() {
        let b = CircularBuffer.CircularBuffer(4);
        b.push(10);
        b.push(20);
        b.push(30);
        let first = b.popFrontUnchecked();
        expect.nat8(first).equal(10);
        expect.nat(b.size()).equal(2);
        expect.nat8(b.getUnchecked(0)).equal(20);
        expect.nat8(b.getUnchecked(1)).equal(30);
        let second = b.popFrontUnchecked();
        expect.nat8(second).equal(20);
        expect.nat(b.size()).equal(1);
      },
    );

  },
);

// ── LZSS sliding-window simulation ───────────────────────────────────────

suite(
  "CircularBuffer LZSS sliding-window simulation",
  func() {

    test(
      "32768-capacity window: push and read back last element",
      func() {
        let b = CircularBuffer.CircularBuffer(32768);
        b.push(0xDE);
        expect.nat8(b.getUnchecked(0)).equal(0xDE);
        expect.nat(b.size()).equal(1);
      },
    );

    test(
      "filling 32768 window then checking oldest and newest",
      func() {
        let b = CircularBuffer.CircularBuffer(32768);
        var i = 0;
        while (i < 32768) { b.push(Nat8.fromNat(i % 256)); i += 1 };
        expect.nat(b.size()).equal(32768);
        // oldest = i=0 → value 0
        expect.nat8(b.getUnchecked(0)).equal(0);
        // newest = i=32767 → 32767 % 256 = 255
        expect.nat8(b.getUnchecked(32767)).equal(255);
      },
    );

    test(
      "one overflow evicts exactly one element from 32768 window",
      func() {
        let b = CircularBuffer.CircularBuffer(32768);
        var i = 0;
        while (i < 32768) { b.push(Nat8.fromNat(i % 256)); i += 1 };
        b.push(0x42); // evicts slot 0 (value 0)
        expect.nat(b.size()).equal(32768);
        // new oldest is i=1 → value 1
        expect.nat8(b.getUnchecked(0)).equal(1);
        // newest is 0x42
        expect.nat8(b.getUnchecked(32767)).equal(0x42);
      },
    );

  },
);
