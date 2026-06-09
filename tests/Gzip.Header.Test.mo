import { test; suite; expect } "mo:test";
import Array "mo:core/Array";
import Int "mo:core/Int";
import Nat8 "mo:core/Nat8";
import Runtime "mo:core/Runtime";
import BitBuffer "../src/internal/BitBuffer";
import BitReader "../src/internal/BitReader";
import Header "../src/Gzip/Header";

// ── Helpers ───────────────────────────────────────────────────────────────

/// Encode `h` with `lzss` level, then decode and return the result.
func roundTrip(
  h : Header.Header,
  lzss : { #best; #fast; #balance },
) : { #ok : Header.Header; #err : Text } {
  let bb = BitBuffer.new();
  Header.encode(bb, h, lzss);
  let bytes = bb.getBytes(0, bb.byteSize());
  let reader = BitReader.fromBytes(bytes);
  Header.decode(reader);
};

func expectOk(res : { #ok : Header.Header; #err : Text }) : Header.Header {
  switch res {
    case (#ok(h)) h;
    case (#err(msg)) Runtime.trap("expected #ok, got #err: " # msg);
  };
};

func expectErr(res : { #ok : Header.Header; #err : Text }, label_ : Text) {
  switch res {
    case (#ok(_)) Runtime.trap(label_ # ": expected #err but got #ok");
    case (#err(_)) {};
  };
};

// ── Suite: OS byte conversion ─────────────────────────────────────────────

suite(
  "osToByte / byteToOs round-trip",
  func() {

    let pairs : [(Header.Os, Nat8)] = [
      (#FatFs, 0x00),
      (#Amiga, 0x01),
      (#Vms, 0x02),
      (#Unix, 0x03),
      (#VmCms, 0x04),
      (#AtariTos, 0x05),
      (#Hpfs, 0x06),
      (#Macintosh, 0x07),
      (#ZSystem, 0x08),
      (#CpM, 0x09),
      (#Tops20, 0x0a),
      (#Ntfs, 0x0b),
      (#Qdos, 0x0c),
      (#AcornRiscos, 0x0d),
      (#Unknown, 0xff),
    ];

    test(
      "osToByte maps every variant to its RFC byte",
      func() {
        for ((os, expected) in pairs.vals()) {
          expect.nat8(Header.osToByte(os)).equal(expected);
        };
      },
    );

    test(
      "byteToOs round-trips for all known OS bytes",
      func() {
        for ((os, byte_) in pairs.vals()) {
          expect.nat8(Header.osToByte(Header.byteToOs(byte_))).equal(byte_);
        };
      },
    );

    test(
      "byteToOs returns #Unknown for unrecognised byte 0x42",
      func() {
        switch (Header.byteToOs(0x42)) {
          case (#Unknown) {};
          case (other) Runtime.trap("expected #Unknown, got " # debug_show other);
        };
      },
    );
  },
);

// ── Suite: Minimal header round-trip ─────────────────────────────────────

suite(
  "Minimal header round-trip",
  func() {

    let minimal : Header.Header = {
      is_text = false;
      is_verified = false;
      extra_fields = [];
      filename = null;
      comment = null;
      modification_time = 0;
      xfl = 0x00;
      os = #Unix;
    };

    test(
      "minimal header encodes to exactly 10 bytes",
      func() {
        let bb = BitBuffer.new();
        Header.encode(bb, minimal, #balance);
        expect.nat(bb.byteSize()).equal(10);
      },
    );

    test(
      "minimal header round-trips without error",
      func() {
        let h = expectOk(roundTrip(minimal, #balance));
        expect.bool(h.is_text).equal(false);
        expect.bool(h.is_verified).equal(false);
        expect.nat(h.extra_fields.size()).equal(0);
        expect.nat(Int.toNat(h.modification_time)).equal(0);
      },
    );

    test(
      "magic bytes: first byte 0x1F",
      func() {
        let bb = BitBuffer.new();
        Header.encode(bb, minimal, #balance);
        let bytes = bb.getBytes(0, bb.byteSize());
        expect.nat8(bytes[0]).equal(0x1f);
      },
    );

    test(
      "magic bytes: second byte 0x8B",
      func() {
        let bb = BitBuffer.new();
        Header.encode(bb, minimal, #balance);
        let bytes = bb.getBytes(0, bb.byteSize());
        expect.nat8(bytes[1]).equal(0x8b);
      },
    );

    test(
      "compression method byte is 0x08 (deflate)",
      func() {
        let bb = BitBuffer.new();
        Header.encode(bb, minimal, #balance);
        let bytes = bb.getBytes(0, bb.byteSize());
        expect.nat8(bytes[2]).equal(0x08);
      },
    );
  },
);

// ── Suite: XFL derivation from LZSS level ────────────────────────────────

suite(
  "XFL byte derived from LZSS level",
  func() {

    let base : Header.Header = {
      is_text = false;
      is_verified = false;
      extra_fields = [];
      filename = null;
      comment = null;
      modification_time = 0;
      xfl = 0x00;
      os = #Unix;
    };

    test(
      "#best → XFL = 0x02",
      func() {
        let h = expectOk(roundTrip(base, #best));
        expect.nat8(h.xfl).equal(0x02);
      },
    );

    test(
      "#fast → XFL = 0x04",
      func() {
        let h = expectOk(roundTrip(base, #fast));
        expect.nat8(h.xfl).equal(0x04);
      },
    );

    test(
      "#balance → XFL = 0x00",
      func() {
        let h = expectOk(roundTrip(base, #balance));
        expect.nat8(h.xfl).equal(0x00);
      },
    );
  },
);

// ── Suite: Optional fields ────────────────────────────────────────────────

suite(
  "Optional fields round-trip",
  func() {

    test(
      "filename survives encode/decode",
      func() {
        let h : Header.Header = {
          is_text = false;
          is_verified = false;
          extra_fields = [];
          filename = ?"hello.txt";
          comment = null;
          modification_time = 0;
          xfl = 0x00;
          os = #Unix;
        };
        let decoded = expectOk(roundTrip(h, #balance));
        switch (decoded.filename) {
          case (?"hello.txt") {};
          case (other) Runtime.trap("expected ?\"hello.txt\", got " # debug_show other);
        };
      },
    );

    test(
      "comment survives encode/decode",
      func() {
        let h : Header.Header = {
          is_text = false;
          is_verified = false;
          extra_fields = [];
          filename = null;
          comment = ?"a comment";
          modification_time = 0;
          xfl = 0x00;
          os = #Unix;
        };
        let decoded = expectOk(roundTrip(h, #balance));
        switch (decoded.comment) {
          case (?"a comment") {};
          case (other) Runtime.trap("expected ?\"a comment\", got " # debug_show other);
        };
      },
    );

    test(
      "filename and comment both present",
      func() {
        let h : Header.Header = {
          is_text = false;
          is_verified = false;
          extra_fields = [];
          filename = ?"data.bin";
          comment = ?"generated";
          modification_time = 42;
          xfl = 0x00;
          os = #Macintosh;
        };
        let decoded = expectOk(roundTrip(h, #fast));
        switch (decoded.filename) {
          case (?"data.bin") {};
          case (other) Runtime.trap("filename: got " # debug_show other);
        };
        switch (decoded.comment) {
          case (?"generated") {};
          case (other) Runtime.trap("comment: got " # debug_show other);
        };
        expect.nat(Int.toNat(decoded.modification_time)).equal(42);
      },
    );

    test(
      "is_text flag survives round-trip",
      func() {
        let h : Header.Header = {
          is_text = true;
          is_verified = false;
          extra_fields = [];
          filename = null;
          comment = null;
          modification_time = 0;
          xfl = 0x00;
          os = #Unix;
        };
        let decoded = expectOk(roundTrip(h, #balance));
        expect.bool(decoded.is_text).equal(true);
      },
    );

    test(
      "OS field survives round-trip",
      func() {
        let h : Header.Header = {
          is_text = false;
          is_verified = false;
          extra_fields = [];
          filename = null;
          comment = null;
          modification_time = 0;
          xfl = 0x00;
          os = #Ntfs;
        };
        let decoded = expectOk(roundTrip(h, #balance));
        switch (decoded.os) {
          case (#Ntfs) {};
          case (other) Runtime.trap("expected #Ntfs, got " # debug_show other);
        };
      },
    );
  },
);

// ── Suite: FEXTRA round-trip ──────────────────────────────────────────────

suite(
  "FEXTRA round-trip",
  func() {

    test(
      "single extra field survives encode/decode",
      func() {
        let h : Header.Header = {
          is_text = false;
          is_verified = false;
          extra_fields = [{ ids = (0x41, 0x70); data = [1, 2, 3] }];
          filename = null;
          comment = null;
          modification_time = 0;
          xfl = 0x00;
          os = #Unix;
        };
        let decoded = expectOk(roundTrip(h, #balance));
        expect.nat(decoded.extra_fields.size()).equal(1);
        let f = decoded.extra_fields[0];
        expect.nat8(f.ids.0).equal(0x41);
        expect.nat8(f.ids.1).equal(0x70);
        expect.nat(f.data.size()).equal(3);
        expect.nat8(f.data[0]).equal(1);
        expect.nat8(f.data[1]).equal(2);
        expect.nat8(f.data[2]).equal(3);
      },
    );

    test(
      "two extra fields survive encode/decode",
      func() {
        let h : Header.Header = {
          is_text = false;
          is_verified = false;
          extra_fields = [
            { ids = (0x01, 0x02); data = [0xAA, 0xBB] },
            { ids = (0x03, 0x04); data = [0xCC] },
          ];
          filename = null;
          comment = null;
          modification_time = 0;
          xfl = 0x00;
          os = #Unix;
        };
        let decoded = expectOk(roundTrip(h, #balance));
        expect.nat(decoded.extra_fields.size()).equal(2);
        expect.nat8(decoded.extra_fields[0].ids.0).equal(0x01);
        expect.nat8(decoded.extra_fields[1].ids.0).equal(0x03);
      },
    );
  },
);

// ── Suite: FHCRC (is_verified) ───────────────────────────────────────────

suite(
  "FHCRC header checksum",
  func() {

    test(
      "is_verified=true: round-trip succeeds and flag preserved",
      func() {
        let h : Header.Header = {
          is_text = false;
          is_verified = true;
          extra_fields = [];
          filename = null;
          comment = null;
          modification_time = 0;
          xfl = 0x00;
          os = #Unix;
        };
        let decoded = expectOk(roundTrip(h, #balance));
        expect.bool(decoded.is_verified).equal(true);
      },
    );

    test(
      "FHCRC with filename: round-trip succeeds",
      func() {
        let h : Header.Header = {
          is_text = false;
          is_verified = true;
          extra_fields = [];
          filename = ?"crc_test.bin";
          comment = null;
          modification_time = 100;
          xfl = 0x00;
          os = #Unix;
        };
        let decoded = expectOk(roundTrip(h, #best));
        expect.bool(decoded.is_verified).equal(true);
        switch (decoded.filename) {
          case (?"crc_test.bin") {};
          case (other) Runtime.trap("filename: got " # debug_show other);
        };
      },
    );

    test(
      "tampered FHCRC byte triggers checksum error",
      func() {
        let h : Header.Header = {
          is_text = false;
          is_verified = true;
          extra_fields = [];
          filename = null;
          comment = null;
          modification_time = 0;
          xfl = 0x00;
          os = #Unix;
        };
        let bb = BitBuffer.new();
        Header.encode(bb, h, #balance);
        let bytes = bb.getBytes(0, bb.byteSize());
        // Flip the last byte (second byte of the CRC16 field)
        let tampered = Array.tabulate<Nat8>(
          bytes.size(),
          func(i) {
            if (i == bytes.size() - 1) bytes[i] ^ 0xFF else bytes[i];
          },
        );
        let reader = BitReader.fromBytes(tampered);
        expectErr(Header.decode(reader), "tampered CRC16");
      },
    );
  },
);

// ── Suite: Decode error paths ─────────────────────────────────────────────

suite(
  "decode error paths",
  func() {

    test(
      "wrong magic byte 0 → #err",
      func() {
        // Replace first magic byte with 0x00
        let bytes : [Nat8] = [0x00, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03];
        let reader = BitReader.fromBytes(bytes);
        expectErr(Header.decode(reader), "bad magic byte 0");
      },
    );

    test(
      "wrong magic byte 1 → #err",
      func() {
        // Replace second magic byte with 0x00
        let bytes : [Nat8] = [0x1f, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03];
        let reader = BitReader.fromBytes(bytes);
        expectErr(Header.decode(reader), "bad magic byte 1");
      },
    );

    test(
      "unsupported compression method → #err",
      func() {
        // Byte 2 = 0x09 (not deflate)
        let bytes : [Nat8] = [0x1f, 0x8b, 0x09, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03];
        let reader = BitReader.fromBytes(bytes);
        expectErr(Header.decode(reader), "unsupported compression method");
      },
    );
  },
);
