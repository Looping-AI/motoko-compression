import { test; suite; expect } "mo:test";
import Nat8 "mo:core/Nat8";
import BitBuffer "../../src/internal/BitBuffer";

// ── addBits / getBits ──────────────────────────────────────────────────────

suite(
  "BitBuffer.addBits / getBits",
  func() {

    test(
      "addBits(3, 5) then getBits(0, 3) = 5",
      func() {
        let b = BitBuffer.BitBuffer(8);
        b.addBits(3, 5);
        expect.nat(b.getBits(0, 3)).equal(5);
        expect.nat(b.bitSize()).equal(3);
      },
    );

    test(
      "addBits(8, 0xAB) = full byte",
      func() {
        let b = BitBuffer.BitBuffer(8);
        b.addBits(8, 0xAB);
        expect.nat(b.getBits(0, 8)).equal(0xAB);
      },
    );

    test(
      "addBits(0, x) is no-op",
      func() {
        let b = BitBuffer.BitBuffer(8);
        b.addBits(0, 99);
        expect.nat(b.bitSize()).equal(0);
      },
    );

    test(
      "two consecutive addBits, read each section back",
      func() {
        let b = BitBuffer.BitBuffer(8);
        b.addBits(5, 21); // 21 = 0b10101
        b.addBits(5, 10); // 10 = 0b01010
        expect.nat(b.getBits(0, 5)).equal(21);
        expect.nat(b.getBits(5, 5)).equal(10);
        expect.nat(b.bitSize()).equal(10);
      },
    );

    test(
      "addBits across byte boundary, read back full 16 bits",
      func() {
        let b = BitBuffer.BitBuffer(8);
        b.addBits(16, 0xCAFE);
        expect.nat(b.getBits(0, 16)).equal(0xCAFE);
      },
    );

    test(
      "LSB-first: addBits(3, 6) => bit0=0, bit1=1, bit2=1",
      func() {
        let b = BitBuffer.BitBuffer(8);
        b.addBits(3, 6); // 6 = 0b110: LSB=0, next=1, top=1
        expect.bool(b.getBit(0)).isFalse();
        expect.bool(b.getBit(1)).isTrue();
        expect.bool(b.getBit(2)).isTrue();
      },
    );

    test(
      "unaligned addBits fills remaining byte bits exactly",
      func() {
        let b = BitBuffer.BitBuffer(8);
        b.addBits(3, 7); // 7 = all-ones, positions 0-2
        b.addBits(5, 21); // 21 = 0b10101, positions 3-7
        expect.nat(b.getBits(0, 3)).equal(7);
        expect.nat(b.getBits(3, 5)).equal(21);
        expect.nat(b.byteSize()).equal(1);
      },
    );

  },
);

// ── addByte / getByte ──────────────────────────────────────────────────────

suite(
  "BitBuffer.addByte / getByte",
  func() {

    test(
      "addByte then getByte at offset 0",
      func() {
        let b = BitBuffer.BitBuffer(8);
        b.addByte(0x42);
        expect.nat8(b.getByte(0)).equal(0x42);
      },
    );

    test(
      "two bytes, read both at correct bit offsets",
      func() {
        let b = BitBuffer.BitBuffer(8);
        b.addByte(0xDE);
        b.addByte(0xAD);
        expect.nat8(b.getByte(0)).equal(0xDE);
        expect.nat8(b.getByte(8)).equal(0xAD);
      },
    );

    test(
      "getByte on unaligned bit position",
      func() {
        let b = BitBuffer.BitBuffer(8);
        b.addBits(3, 0);
        b.addByte(0x7F);
        expect.nat8(b.getByte(3)).equal(0x7F);
      },
    );

    test(
      "getByte zero-pads when fewer than 8 bits remain",
      func() {
        let b = BitBuffer.BitBuffer(8);
        b.addBits(4, 15); // 0xF
        expect.nat8(b.getByte(0)).equal(0x0F);
      },
    );

    test(
      "getByte beyond buffer returns 0",
      func() {
        let b = BitBuffer.BitBuffer(8);
        b.addByte(0xFF);
        expect.nat8(b.getByte(100)).equal(0);
      },
    );

  },
);

// ── addBytes / getBytes ────────────────────────────────────────────────────

suite(
  "BitBuffer.addBytes / getBytes",
  func() {

    test(
      "addBytes round-trip",
      func() {
        let b = BitBuffer.BitBuffer(8);
        let data : [Nat8] = [0x01, 0x02, 0x03, 0x04];
        b.addBytes(data);
        let result = b.getBytes(0, 4);
        expect.array(result, Nat8.toText, Nat8.equal).equal(data);
      },
    );

    test(
      "getBytes at non-zero startBit",
      func() {
        let b = BitBuffer.BitBuffer(8);
        b.addBytes([0x00, 0xAA, 0xBB]);
        let result = b.getBytes(8, 2);
        expect.array(result, Nat8.toText, Nat8.equal).equal([0xAA, 0xBB]);
      },
    );

    test(
      "addBytes after a full aligned byte",
      func() {
        let b = BitBuffer.BitBuffer(8);
        b.addBits(8, 0);
        b.addBytes([0xCA, 0xFE]);
        let result = b.getBytes(8, 2);
        expect.array(result, Nat8.toText, Nat8.equal).equal([0xCA, 0xFE]);
      },
    );

  },
);

// ── byteAlign ─────────────────────────────────────────────────────────────

suite(
  "BitBuffer.byteAlign",
  func() {

    test(
      "already aligned is no-op",
      func() {
        let b = BitBuffer.BitBuffer(8);
        b.addByte(0xFF);
        b.byteAlign();
        expect.nat(b.bitSize()).equal(8);
        expect.nat(b.byteSize()).equal(1);
      },
    );

    test(
      "pads partial byte to 8 bits",
      func() {
        let b = BitBuffer.BitBuffer(8);
        b.addBits(3, 5);
        b.byteAlign();
        expect.nat(b.bitSize()).equal(8);
        expect.nat(b.byteSize()).equal(1);
      },
    );

    test(
      "existing data preserved after byteAlign",
      func() {
        let b = BitBuffer.BitBuffer(8);
        b.addBits(3, 5);
        b.byteAlign();
        expect.nat(b.getBits(0, 3)).equal(5);
      },
    );

    test(
      "byteAlign then addByte produces correct layout",
      func() {
        let b = BitBuffer.BitBuffer(8);
        b.addBits(3, 7);
        b.byteAlign();
        b.addByte(0xAB);
        expect.nat(b.bitSize()).equal(16);
        expect.nat8(b.getByte(8)).equal(0xAB);
      },
    );

    test(
      "empty buffer byteAlign is no-op",
      func() {
        let b = BitBuffer.BitBuffer(8);
        b.byteAlign();
        expect.nat(b.bitSize()).equal(0);
      },
    );

  },
);

// ── dropBits ──────────────────────────────────────────────────────────────

suite(
  "BitBuffer.dropBits",
  func() {

    test(
      "drop 3 bits, remaining bits shift to position 0",
      func() {
        // 0xB2 = 178 = 0b10110010; bits [3..7] = 0b10110 = 22
        let b = BitBuffer.BitBuffer(8);
        b.addBits(8, 0xB2);
        b.dropBits(3);
        expect.nat(b.bitSize()).equal(5);
        expect.nat(b.getBits(0, 5)).equal(22);
      },
    );

    test(
      "drop a full byte, next byte accessible at position 0",
      func() {
        let b = BitBuffer.BitBuffer(8);
        b.addByte(0xDE);
        b.addByte(0xAD);
        b.dropBits(8);
        expect.nat(b.bitSize()).equal(8);
        expect.nat8(b.getByte(0)).equal(0xAD);
      },
    );

    test(
      "drop all bits leaves bitSize = 0",
      func() {
        let b = BitBuffer.BitBuffer(8);
        b.addBits(6, 42); // 42 = 0b101010
        b.dropBits(6);
        expect.nat(b.bitSize()).equal(0);
      },
    );

    test(
      "drop zero bits is no-op",
      func() {
        let b = BitBuffer.BitBuffer(8);
        b.addByte(0xAA);
        b.dropBits(0);
        expect.nat(b.bitSize()).equal(8);
        expect.nat8(b.getByte(0)).equal(0xAA);
      },
    );

    test(
      "drop then add more bits",
      func() {
        let b = BitBuffer.BitBuffer(8);
        b.addByte(0xFF);
        b.dropBits(8);
        b.addByte(0x42);
        expect.nat(b.bitSize()).equal(8);
        expect.nat8(b.getByte(0)).equal(0x42);
      },
    );

  },
);

// ── clear ─────────────────────────────────────────────────────────────────

suite(
  "BitBuffer.clear",
  func() {

    test(
      "clear resets bitSize to 0",
      func() {
        let b = BitBuffer.BitBuffer(8);
        b.addBytes([0xDE, 0xAD, 0xBE, 0xEF]);
        b.clear();
        expect.nat(b.bitSize()).equal(0);
        expect.nat(b.byteSize()).equal(0);
      },
    );

    test(
      "can write and read after clear",
      func() {
        let b = BitBuffer.BitBuffer(8);
        b.addBytes([0xFF, 0xFF]);
        b.clear();
        b.addByte(0x42);
        expect.nat8(b.getByte(0)).equal(0x42);
        expect.nat(b.bitSize()).equal(8);
      },
    );

    test(
      "clear resets dropBits offset too",
      func() {
        let b = BitBuffer.BitBuffer(8);
        b.addBits(16, 0xABCD);
        b.dropBits(8);
        b.clear();
        b.addByte(0x99);
        expect.nat8(b.getByte(0)).equal(0x99);
        expect.nat(b.bitSize()).equal(8);
      },
    );

  },
);

// ── capacity growth ────────────────────────────────────────────────────────

suite(
  "BitBuffer capacity growth",
  func() {

    test(
      "writing 64 bytes triggers multiple capacity doublings",
      func() {
        let b = BitBuffer.BitBuffer(8); // initial cap = 8 bytes
        var i = 0;
        while (i < 64) {
          b.addByte(Nat8.fromNat(i));
          i += 1;
        };
        expect.nat(b.byteSize()).equal(64);
        expect.nat8(b.getByte(0)).equal(0);
        expect.nat8(b.getByte(8)).equal(1);
        expect.nat8(b.getByte(8 * 63)).equal(63);
      },
    );

    test(
      "BitBuffer.new() works like BitBuffer(0)",
      func() {
        let b = BitBuffer.new();
        b.addBits(4, 15);
        expect.nat(b.bitSize()).equal(4);
        expect.nat(b.getBits(0, 4)).equal(15);
      },
    );

  },
);

// ── unaligned multi-byte writes ───────────────────────────────────────────

suite(
  "BitBuffer unaligned multi-byte writes",
  func() {

    test(
      "addBits(3, 7) then addBits(13, 0x1ABC) round-trips",
      func() {
        let b = BitBuffer.BitBuffer(8);
        b.addBits(3, 7);
        b.addBits(13, 0x1ABC);
        expect.nat(b.bitSize()).equal(16);
        expect.nat(b.getBits(0, 3)).equal(7);
        expect.nat(b.getBits(3, 13)).equal(0x1ABC);
      },
    );

    test(
      "addBits at offset 5 spanning 3 bytes",
      func() {
        let b = BitBuffer.BitBuffer(8);
        b.addBits(5, 17); // value at bits [0..4]
        b.addBits(20, 0xABCDE); // bits [5..24], spans bytes 0,1,2,3
        expect.nat(b.bitSize()).equal(25);
        expect.nat(b.getBits(0, 5)).equal(17);
        expect.nat(b.getBits(5, 20)).equal(0xABCDE);
      },
    );

    test(
      "high bits of value above n are ignored",
      func() {
        let b = BitBuffer.BitBuffer(8);
        // 0xFF has 8 set bits; only low 3 should be written
        b.addBits(3, 0xFF);
        expect.nat(b.bitSize()).equal(3);
        expect.nat(b.getBits(0, 3)).equal(7); // low 3 of 0xFF
      },
    );

  },
);

// ── unaligned multi-byte reads ────────────────────────────────────────────

suite(
  "BitBuffer unaligned multi-byte reads",
  func() {

    test(
      "getBits across 3 byte boundaries from unaligned start",
      func() {
        let b = BitBuffer.BitBuffer(8);
        b.addBytes([0x12, 0x34, 0x56]);
        // 24-bit little-endian value is 0x563412
        // bits [5..21] (17 bits) of 0x563412
        let full = 0x563412;
        let expected = (full / 32) % (2 ** 17); // >> 5, mask 17 bits
        expect.nat(b.getBits(5, 17)).equal(expected);
      },
    );

    test(
      "getBits at offset 7 spanning byte boundary (1 + 8 + 1 = 10 bits)",
      func() {
        let b = BitBuffer.BitBuffer(8);
        b.addBytes([0xAA, 0xBB]); // 0xBBAA little-endian = 48042
        let expected = (0xBBAA / 128) % (2 ** 10); // >> 7, mask 10
        expect.nat(b.getBits(7, 10)).equal(expected);
      },
    );

    test(
      "getBits(i, 0) returns 0",
      func() {
        let b = BitBuffer.BitBuffer(8);
        b.addByte(0xFF);
        expect.nat(b.getBits(3, 0)).equal(0);
      },
    );

    test(
      "getBytes(_, 0) returns empty array",
      func() {
        let b = BitBuffer.BitBuffer(8);
        b.addByte(0xAB);
        let result = b.getBytes(0, 0);
        expect.array(result, Nat8.toText, Nat8.equal).equal([]);
      },
    );

  },
);

// ── interleaved read / write / drop ───────────────────────────────────────

suite(
  "BitBuffer interleaved sequences",
  func() {

    test(
      "dropBits to partial-byte position, then multi-byte read",
      func() {
        let b = BitBuffer.BitBuffer(8);
        b.addBytes([0x12, 0x34, 0x56, 0x78]);
        b.dropBits(3); // 29 bits remain
        expect.nat(b.bitSize()).equal(29);
        // Equivalent to reading from bit 3 of original little-endian 0x78563412
        let full = 0x78563412;
        let expected = (full / 8) % (2 ** 16); // >> 3, mask 16
        expect.nat(b.getBits(0, 16)).equal(expected);
      },
    );

    test(
      "write, drop partial, write more, read both segments",
      func() {
        let b = BitBuffer.BitBuffer(8);
        b.addBits(11, 0x5A5);
        b.dropBits(3);
        b.addBits(5, 21);
        // After dropBits(3): 8 bits remain (bits [3..10] of 0x5A5)
        // Then 5 more bits at the tail
        let firstSegment = (0x5A5 / 8) % (2 ** 8);
        expect.nat(b.bitSize()).equal(13);
        expect.nat(b.getBits(0, 8)).equal(firstSegment);
        expect.nat(b.getBits(8, 5)).equal(21);
      },
    );

    test(
      "streaming decoder pattern: read header, drop, read payload",
      func() {
        let b = BitBuffer.BitBuffer(8);
        b.addBits(3, 5); // "header" = 5
        b.addBits(13, 0x1ABC); // "payload" = 0x1ABC
        let hdr = b.getBits(0, 3);
        b.dropBits(3);
        let payload = b.getBits(0, 13);
        expect.nat(hdr).equal(5);
        expect.nat(payload).equal(0x1ABC);
        expect.nat(b.bitSize()).equal(13);
      },
    );

  },
);

// ── round-trip property ───────────────────────────────────────────────────

suite(
  "BitBuffer round-trip property",
  func() {

    test(
      "addBits/getBits round-trip across (n, v) grid",
      func() {
        let cases : [(Nat, Nat)] = [
          (1, 0),
          (1, 1),
          (3, 5),
          (3, 7),
          (5, 21),
          (5, 31),
          (7, 100),
          (8, 0),
          (8, 0xAB),
          (8, 0xFF),
          (11, 0x5A5),
          (13, 0x1ABC),
          (16, 0xCAFE),
          (16, 0xFFFF),
          (17, 0x1FFFF),
          (20, 0xABCDE),
          (24, 0x123456),
          (32, 0xDEADBEEF),
        ];
        for ((n, v) in cases.vals()) {
          let b = BitBuffer.BitBuffer(8);
          b.addBits(n, v);
          let masked = v % (2 ** n);
          expect.nat(b.getBits(0, n)).equal(masked);
          expect.nat(b.bitSize()).equal(n);
        };
      },
    );

  },
);

// ── clear() after partial drop + write ────────────────────────────────────

suite(
  "BitBuffer.clear edge cases",
  func() {

    test(
      "clear after partial dropBits + addBits resets cleanly",
      func() {
        let b = BitBuffer.BitBuffer(8);
        b.addBits(11, 0x7FF);
        b.dropBits(3);
        b.addBits(5, 17);
        b.clear();
        expect.nat(b.bitSize()).equal(0);
        expect.nat(b.byteSize()).equal(0);
        // Fresh writes should start from a clean slate
        b.addBits(8, 0xAB);
        expect.nat(b.getBits(0, 8)).equal(0xAB);
      },
    );

    test(
      "clear after capacity growth still allows writes",
      func() {
        let b = BitBuffer.BitBuffer(8);
        var i = 0;
        while (i < 32) {
          b.addByte(Nat8.fromNat(i % 256));
          i += 1;
        };
        b.clear();
        expect.nat(b.bitSize()).equal(0);
        b.addByte(0x42);
        expect.nat8(b.getByte(0)).equal(0x42);
      },
    );

  },
);
