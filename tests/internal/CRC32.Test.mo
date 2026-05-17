import { test; suite; expect } "mo:test";
import Nat32 "mo:core/Nat32";
import CRC32 "../../src/internal/CRC32";

// ── checksum convenience function ─────────────────────────────────────────

suite("CRC32.checksum", func() {

  test("empty input returns 0x00000000 (standard CRC-32)", func() {
    expect.nat32(CRC32.checksum([])).equal((0x00000000 : Nat32));
  });

  test("single byte 0x61 ('a') returns 0xE8B7BE43", func() {
    expect.nat32(CRC32.checksum([0x61])).equal((0xE8B7BE43 : Nat32));
  });

  test("\"123456789\" returns 0xCBF43926 (canonical IEEE test vector)", func() {
    let data : [Nat8] = [0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39];
    expect.nat32(CRC32.checksum(data)).equal((0xCBF43926 : Nat32));
  });

  test("\"hello\" returns correct CRC-32", func() {
    // CRC-32 of "hello" = 0x3610A686
    let data : [Nat8] = [0x68, 0x65, 0x6C, 0x6C, 0x6F];
    expect.nat32(CRC32.checksum(data)).equal((0x3610A686 : Nat32));
  });

  test("17-byte input exercises singleSlicingUpdate path", func() {
    // input_size >= INIT_SIZE (16) triggers singleSlicingUpdate on the 17th byte
    // CRC-32 of [0x00, 0x01, ..., 0x10]
    let data : [Nat8] = [0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
                         0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F,
                         0x10];
    expect.nat32(CRC32.checksum(data)).equal((0x2C183A19 : Nat32));
  });

});

// ── CRC32 class: incremental API ──────────────────────────────────────────

suite("CRC32.CRC32 class", func() {

  test("update then finish matches checksum", func() {
    let data : [Nat8] = [0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39];
    let crc = CRC32.CRC32();
    crc.update(data);
    expect.nat32(crc.finish()).equal(CRC32.checksum(data));
  });

  test("updateByte one-by-one matches update all-at-once", func() {
    let data : [Nat8] = [0x61, 0x62, 0x63];
    let crc1 = CRC32.CRC32();
    crc1.update(data);
    let expected = crc1.finish();

    let crc2 = CRC32.CRC32();
    for (b in data.vals()) { crc2.updateByte(b) };
    expect.nat32(crc2.finish()).equal(expected);
  });

  test("updateIter matches update", func() {
    let data : [Nat8] = [0x68, 0x65, 0x6C, 0x6C, 0x6F];
    let crc1 = CRC32.CRC32();
    crc1.update(data);
    let expected = crc1.finish();

    let crc2 = CRC32.CRC32();
    crc2.updateIter(data.vals());
    expect.nat32(crc2.finish()).equal(expected);
  });

  test("two update calls equal one combined update", func() {
    let a : [Nat8] = [0x31, 0x32, 0x33];
    let b : [Nat8] = [0x34, 0x35, 0x36];
    let combined : [Nat8] = [0x31, 0x32, 0x33, 0x34, 0x35, 0x36];

    let crc1 = CRC32.CRC32();
    crc1.update(a);
    crc1.update(b);
    let incremental = crc1.finish();

    let crc2 = CRC32.CRC32();
    crc2.update(combined);
    expect.nat32(crc2.finish()).equal(incremental);
  });

  test("reset then finish returns empty CRC 0x00000000", func() {
    let crc = CRC32.CRC32();
    crc.update([0x41, 0x42, 0x43]);
    crc.reset();
    expect.nat32(crc.finish()).equal((0x00000000 : Nat32));
  });

  test("finish resets state automatically", func() {
    let data : [Nat8] = [0x61];
    let crc = CRC32.CRC32();
    crc.update(data);
    let _ = crc.finish(); // first call resets internally
    // second call with no new data should equal checksum([])
    expect.nat32(crc.finish()).equal((0x00000000 : Nat32));
  });

  test("reusable after finish: second checksum is correct", func() {
    let crc = CRC32.CRC32();
    crc.update([0x61]);
    let _ = crc.finish();
    crc.update([0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39]);
    expect.nat32(crc.finish()).equal((0xCBF43926 : Nat32));
  });

});
