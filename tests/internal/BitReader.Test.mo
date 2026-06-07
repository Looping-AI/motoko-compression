import { test; suite; expect } "mo:test";
import Nat8 "mo:core/Nat8";
import BitReader "../../src/internal/BitReader";

// ── Test data ────────────────────────────────────────────────────────────────
// 0xA5 = 0b10100101  — bits LSB-first: 1,0,1,0,0,1,0,1
// 0x42 = 0b01000010  — bits LSB-first: 0,1,0,0,0,0,1,0

suite(
  "peekBit / readBit",
  func() {
    test(
      "peekBit returns correct first bit",
      func() {
        let r = BitReader.fromBytes([0xA5 : Nat8]);
        expect.bool(r.peekBit()).isTrue();
      },
    );

    test(
      "peekBit is idempotent (does not advance)",
      func() {
        let r = BitReader.fromBytes([0xA5 : Nat8]);
        ignore r.peekBit();
        ignore r.peekBit();
        expect.nat(r.getPosition()).equal(0);
      },
    );

    test(
      "readBit advances offset by 1",
      func() {
        let r = BitReader.fromBytes([0xA5 : Nat8]);
        ignore r.readBit();
        expect.nat(r.getPosition()).equal(1);
      },
    );

    test(
      "readBit sequence reads LSB-first bits of 0xA5",
      func() {
        let r = BitReader.fromBytes([0xA5 : Nat8]);
        // 0xA5 = 10100101 → bits LSB-first: 1,0,1,0,0,1,0,1
        expect.bool(r.readBit()).isTrue();
        expect.bool(r.readBit()).isFalse();
        expect.bool(r.readBit()).isTrue();
        expect.bool(r.readBit()).isFalse();
        expect.bool(r.readBit()).isFalse();
        expect.bool(r.readBit()).isTrue();
        expect.bool(r.readBit()).isFalse();
        expect.bool(r.readBit()).isTrue();
      },
    );
  },
);

suite(
  "peekBits / readBits",
  func() {
    test(
      "peekBits(3) on 0xA5 = 5 (bits: 1,0,1 → 1+0+4)",
      func() {
        let r = BitReader.fromBytes([0xA5 : Nat8]);
        expect.nat(r.peekBits(3)).equal(5);
      },
    );

    test(
      "peekBits is non-mutating",
      func() {
        let r = BitReader.fromBytes([0xA5 : Nat8]);
        let v1 = r.peekBits(3);
        let v2 = r.peekBits(3);
        expect.nat(v1).equal(v2);
        expect.nat(r.getPosition()).equal(0);
      },
    );

    test(
      "readBits(3) on 0xA5 = 5 and advances by 3",
      func() {
        let r = BitReader.fromBytes([0xA5 : Nat8]);
        expect.nat(r.readBits(3)).equal(5);
        expect.nat(r.getPosition()).equal(3);
      },
    );

    test(
      "readBits(8) returns full byte value",
      func() {
        let r = BitReader.fromBytes([0x42 : Nat8]);
        expect.nat(r.readBits(8)).equal(0x42);
      },
    );

    test(
      "readBits across two bytes",
      func() {
        // [0xA5, 0x42]: first 8 bits = 0xA5, next 8 bits = 0x42
        let r = BitReader.fromBytes([0xA5 : Nat8, 0x42 : Nat8]);
        expect.nat(r.readBits(8)).equal(0xA5);
        expect.nat(r.readBits(8)).equal(0x42);
      },
    );
  },
);

suite(
  "skipBits",
  func() {
    test(
      "skipBits advances offset",
      func() {
        let r = BitReader.fromBytes([0xA5 : Nat8]);
        r.skipBits(3);
        expect.nat(r.getPosition()).equal(3);
      },
    );

    test(
      "skipBits then readBit reads correct bit",
      func() {
        // 0xA5 bits: 1,0,1,0,0,1,0,1 — after skipping 3, next bit is bit[3]=0
        let r = BitReader.fromBytes([0xA5 : Nat8]);
        r.skipBits(3);
        expect.bool(r.readBit()).isFalse();
      },
    );
  },
);

suite(
  "peekByte / readByte",
  func() {
    test(
      "readByte on 0xA5 = 165",
      func() {
        let r = BitReader.fromBytes([0xA5 : Nat8]);
        expect.nat8(r.readByte()).equal(0xA5);
      },
    );

    test(
      "peekByte does not advance offset",
      func() {
        let r = BitReader.fromBytes([0xA5 : Nat8]);
        ignore r.peekByte();
        expect.nat(r.getPosition()).equal(0);
      },
    );

    test(
      "peekByte and readByte return the same value",
      func() {
        let r = BitReader.fromBytes([0xA5 : Nat8]);
        let peeked = r.peekByte();
        let read = r.readByte();
        expect.nat8(peeked).equal(read);
      },
    );

    test(
      "sequential readByte reads two bytes",
      func() {
        let r = BitReader.fromBytes([0xA5 : Nat8, 0x42 : Nat8]);
        expect.nat8(r.readByte()).equal(0xA5);
        expect.nat8(r.readByte()).equal(0x42);
      },
    );
  },
);

suite(
  "readBytes",
  func() {
    test(
      "readBytes reads correct values and advances",
      func() {
        let r = BitReader.fromBytes([0xA5 : Nat8, 0x42 : Nat8]);
        let bytes = r.readBytes(2);
        expect.array(bytes, Nat8.toText, Nat8.equal).equal([0xA5 : Nat8, 0x42 : Nat8]);
        expect.nat(r.getPosition()).equal(16);
      },
    );

    test(
      "readBytes clamps to available byteSize",
      func() {
        let r = BitReader.fromBytes([0xA5 : Nat8]);
        let bytes = r.readBytes(5); // only 1 byte available
        expect.array(bytes, Nat8.toText, Nat8.equal).equal([0xA5 : Nat8]);
      },
    );
  },
);

suite(
  "byteAlign",
  func() {
    test(
      "byteAlign after 1 bit consumed skips 7 bits to empty",
      func() {
        // 1 byte loaded, 1 bit read → bitSize=7, byteAlign skips 7 → bitSize=0
        let r = BitReader.fromBytes([0xA5 : Nat8]);
        ignore r.readBit();
        r.byteAlign();
        expect.nat(r.bitSize()).equal(0);
      },
    );

    test(
      "byteAlign on byte-aligned data is a no-op",
      func() {
        let r = BitReader.fromBytes([0xA5 : Nat8]);
        r.byteAlign(); // bitSize=8, 8%8=0 → no change
        expect.nat(r.bitSize()).equal(8);
      },
    );

    test(
      "byteAlign leaves clean multiple of 8 bits",
      func() {
        // 2 bytes, read 1 bit → bitSize=15, byteAlign skips 7 → bitSize=8
        let r = BitReader.fromBytes([0xA5 : Nat8, 0x42 : Nat8]);
        ignore r.readBit();
        r.byteAlign();
        expect.nat(r.bitSize()).equal(8);
      },
    );
  },
);

suite(
  "getPosition / setPosition",
  func() {
    test(
      "seek back and re-read same byte",
      func() {
        let r = BitReader.fromBytes([0xA5 : Nat8, 0x42 : Nat8]);
        ignore r.readByte(); // advance past 0xA5
        let pos = r.getPosition(); // = 8
        ignore r.readBit(); // advance 1 more
        r.setPosition(pos); // seek back to byte boundary
        expect.nat8(r.readByte()).equal(0x42);
      },
    );
  },
);

suite(
  "reset",
  func() {
    test(
      "reset restores offset to 0, data preserved",
      func() {
        let r = BitReader.fromBytes([0xA5 : Nat8]);
        ignore r.readBits(5);
        r.reset();
        expect.nat(r.getPosition()).equal(0);
        expect.bool(r.peekBit()).isTrue(); // bit 0 of 0xA5 = 1
      },
    );
  },
);

suite(
  "clearRead",
  func() {
    test(
      "clearRead drops consumed bits, offset resets to 0",
      func() {
        let r = BitReader.fromBytes([0xA5 : Nat8, 0x42 : Nat8]);
        ignore r.readByte(); // consume 0xA5
        r.clearRead(); // drop 8 bits, offset → 0
        expect.nat(r.bitSize()).equal(8);
        expect.nat8(r.readByte()).equal(0x42);
      },
    );
  },
);

suite(
  "clear",
  func() {
    test(
      "clear empties buffer completely",
      func() {
        let r = BitReader.fromBytes([0xA5 : Nat8, 0x42 : Nat8]);
        r.clear();
        expect.nat(r.bitSize()).equal(0);
        expect.nat(r.getPosition()).equal(0);
      },
    );
  },
);

suite(
  "addBytes / fromBytes",
  func() {
    test(
      "addBytes appends data for reading",
      func() {
        let r = BitReader.BitReader(0);
        r.addBytes([0xA5 : Nat8]);
        expect.nat(r.bitSize()).equal(8);
        expect.nat8(r.readByte()).equal(0xA5);
      },
    );

    test(
      "fromBytes initialises reader with data",
      func() {
        let r = BitReader.fromBytes([0xA5 : Nat8]);
        expect.nat(r.bitSize()).equal(8);
        expect.nat8(r.readByte()).equal(0xA5);
      },
    );
  },
);
