/// Bit-level read/write buffer.
///
/// Bits are packed LSB-first within each byte (DEFLATE convention):
///   addBits(3, 5)  --  value 5 = binary 101, writes bits [1, 0, 1]
///                      into positions [0, 1, 2] of the current byte.
///
/// Write position: tracked by `writeBit` (total logical bits appended).
/// Read  position: tracked by `readBit`  (bits dropped from the front).
/// `bitSize() = writeBit - readBit`.
///
/// Implementation uses a Nat64 shift-register accumulator (zlib bi_buf pattern).
/// Bits accumulate in `acc`; complete bytes are drained to `buf` in one pass,
/// and the partial byte is written to `buf` immediately so reads are always valid.
/// This eliminates per-iteration `writeBit/8` and `writeBit%8` div/mod in the
/// DEFLATE symbol-emission hot path.
///
/// The backing array never shrinks; it doubles in capacity when full.

import Prim "mo:⛔";
import Runtime "mo:core/Runtime";
import Nat8 "mo:core/Nat8";
import Nat32 "mo:core/Nat32";
import Nat64 "mo:core/Nat64";
import Array "mo:core/Array";

module {

  let BYTE : Nat = 8;

  // Precomputed bit masks — MASKS8[k] = 2^k − 1 for k in 0..8.
  // Used by the read path (getBits / getByte).
  let MASKS8 : [Nat8] = [0, 1, 3, 7, 15, 31, 63, 127, 255];

  public class BitBuffer(initCapacity : Nat) {

    // ── Backing store ─────────────────────────────────────────────────────
    var cap : Nat = if (initCapacity == 0) 8 else initCapacity;
    var buf : [var Nat8] = Prim.Array_init<Nat8>(cap, (0 : Nat8));

    // `writeBit`: total logical bits appended (same semantics as before).
    // `acc`:      Nat64 shift register accumulating bits for the current
    //             partial byte.  `acc`'s low `(writeBit % 8)` bits hold the
    //             pending partial byte; higher bits are always 0.
    //             The partial byte is also written to `buf[writeBit/8]`
    //             immediately after every addBits call, so reads are always
    //             valid without any flush step.
    var writeBit : Nat = 0;
    var acc : Nat64 = 0;

    var readBit : Nat = 0; // logical bits dropped from front

    // ── Internal helpers ─────────────────────────────────────────────────

    // Grow `buf` so that it can hold at least `needed` bytes.
    // Copies only the live bytes (0 .. min(ceil(writeBit/8), oldCap)).
    // oldCap bounds the copy because callers may increment `writeBit` before
    // calling ensureCapacity, making ceil(writeBit/8) exceed the old buf size.
    func ensureCapacity(needed : Nat) {
      if (needed <= cap) return;
      let oldCap = cap;
      while (cap < needed) cap *= 2;
      let newBuf = Prim.Array_init<Nat8>(cap, (0 : Nat8));
      let live : Nat = (writeBit + BYTE - 1) / BYTE;
      let toCopy = if (live < oldCap) live else oldCap;
      var i = 0;
      while (i < toCopy) { newBuf[i] := buf[i]; i += 1 };
      buf := newBuf;
    };

    // ── Size queries ─────────────────────────────────────────────────────

    /// Number of unread bits currently stored.
    public func bitSize() : Nat { writeBit - readBit };

    /// Number of bytes needed to hold the current unread bits.
    public func byteSize() : Nat { (bitSize() + BYTE - 1) / BYTE };

    /// Absolute write position in bits (total bits appended). On the encode
    /// path `readBit == 0`, so this equals the logical bit length. Used to
    /// record a patch point for `setBitTrue`.
    public func writeBitPos() : Nat { writeBit };

    // ── Write operations ─────────────────────────────────────────────────

    /// Append the low `n` bits of `value`, LSB first.
    /// E.g. addBits(3, 5) writes bits [1, 0, 1] (5 = binary 101).
    /// High bits of `value` above bit `n-1` are masked off.
    ///
    /// Algorithm (zlib bi_buf pattern):
    ///   1. Mask `value` to `n` bits and merge into `acc` at the current
    ///      bit offset within the partial byte.
    ///   2. Drain complete bytes from `acc` to `buf` in a single loop.
    ///   3. Write the residual partial byte (if any) to `buf[writeBit/8]`
    ///      so that read operations always see up-to-date data.
    public func addBits(n : Nat, value : Nat) {
      if (n == 0) return;
      let bitOff = writeBit % BYTE; // bit position within current byte
      let physByte = writeBit / BYTE; // index of current partial byte in buf

      // Mask to low n bits and merge into accumulator.
      let mask : Nat64 = Nat64.bitshiftLeft((1 : Nat64), Nat64.fromNat(n)) - 1;
      let v : Nat64 = Nat64.bitand(Nat64.fromNat(value), mask);
      acc := Nat64.bitor(acc, Nat64.bitshiftLeft(v, Nat64.fromNat(bitOff)));

      writeBit += n;

      // How many complete bytes did we produce (and must drain from acc)?
      // = (bitOff + n) / 8  — computed before updating writeBit would be cleaner,
      // but using the updated writeBit: completeBytes = writeBit/8 - physByte.
      // To avoid Nat underflow the compiler would flag, derive from (bitOff + n).
      let totalInAcc = bitOff + n; // bits now in acc (may span multiple bytes)
      let completeBytes = totalInAcc / BYTE;
      let newPartial = totalInAcc % BYTE; // bits remaining in acc after drain
      // Total bytes to allocate: complete drained bytes + 1 for residual partial byte
      // (written so reads always see up-to-date data).
      let needBytes = completeBytes + (if (newPartial != 0) 1 else 0);

      ensureCapacity(physByte + needBytes);

      // Drain complete bytes from acc to buf.
      var i = 0;
      while (i < completeBytes) {
        buf[physByte + i] := Nat64.toNat8(Nat64.bitand(acc, 255));
        acc := Nat64.bitshiftRight(acc, 8);
        i += 1;
      };

      // Write residual partial byte to buf (acc still holds its low bits).
      if (newPartial != 0) {
        buf[physByte + completeBytes] := Nat64.toNat8(Nat64.bitand(acc, 255));
      };
    };

    /// Append two adjacent bit fields in a single accumulator merge & drain.
    ///
    /// Append four adjacent bit fields in a single accumulator merge & drain.
    ///
    /// Equivalent to two `addBits2` calls but pays the `acc` merge,
    /// `ensureCapacity` check, and partial-byte writeback cost once instead
    /// of twice.  Used by the DEFLATE pointer-emit path to fuse
    /// (length-code, length-extra, distance-code, distance-extra) into one
    /// operation.
    ///
    /// Any `nN` may be 0 (no-op for that field).
    /// Requires `(writeBit % 8) + n1 + n2 + n3 + n4 <= 64` — satisfied for
    /// DEFLATE (max 15-bit code + 5-bit extra + 15-bit code + 13-bit extra =
    /// 48 bits; with 7-bit partial offset the worst case is 55 ≤ 64).
    public func addBits4(n1 : Nat, v1 : Nat, n2 : Nat, v2 : Nat, n3 : Nat, v3 : Nat, n4 : Nat, v4 : Nat) {
      let n = n1 + n2 + n3 + n4;
      if (n == 0) return;
      let bitOff = writeBit % BYTE;
      let physByte = writeBit / BYTE;

      let mask1 : Nat64 = Nat64.bitshiftLeft((1 : Nat64), Nat64.fromNat(n1)) - 1;
      let mask2 : Nat64 = Nat64.bitshiftLeft((1 : Nat64), Nat64.fromNat(n2)) - 1;
      let mask3 : Nat64 = Nat64.bitshiftLeft((1 : Nat64), Nat64.fromNat(n3)) - 1;
      let mask4 : Nat64 = Nat64.bitshiftLeft((1 : Nat64), Nat64.fromNat(n4)) - 1;
      let w1 : Nat64 = Nat64.bitand(Nat64.fromNat(v1), mask1);
      let w2 : Nat64 = Nat64.bitand(Nat64.fromNat(v2), mask2);
      let w3 : Nat64 = Nat64.bitand(Nat64.fromNat(v3), mask3);
      let w4 : Nat64 = Nat64.bitand(Nat64.fromNat(v4), mask4);
      let combined : Nat64 = Nat64.bitor(
        Nat64.bitor(w1, Nat64.bitshiftLeft(w2, Nat64.fromNat(n1))),
        Nat64.bitor(
          Nat64.bitshiftLeft(w3, Nat64.fromNat(n1 + n2)),
          Nat64.bitshiftLeft(w4, Nat64.fromNat(n1 + n2 + n3)),
        ),
      );
      acc := Nat64.bitor(acc, Nat64.bitshiftLeft(combined, Nat64.fromNat(bitOff)));

      writeBit += n;

      let totalInAcc = bitOff + n;
      let completeBytes = totalInAcc / BYTE;
      let newPartial = totalInAcc % BYTE;
      let needBytes = completeBytes + (if (newPartial != 0) 1 else 0);

      ensureCapacity(physByte + needBytes);

      var i = 0;
      while (i < completeBytes) {
        buf[physByte + i] := Nat64.toNat8(Nat64.bitand(acc, 255));
        acc := Nat64.bitshiftRight(acc, 8);
        i += 1;
      };

      if (newPartial != 0) {
        buf[physByte + completeBytes] := Nat64.toNat8(Nat64.bitand(acc, 255));
      };
    };

    /// Set the bit at absolute write position `pos` to 1, patching a
    /// previously-written 0 bit in place (e.g. DEFLATE's BFINAL flag, which
    /// the fixed direct-emit path writes as 0 before the block's finality is
    /// known). Only valid on the encode path (`readBit == 0`); `pos` must be
    /// < writeBit and the target bit must currently be 0.
    public func setBitTrue(pos : Nat) {
      let byteIdx = pos / BYTE;
      let bitIdx = pos % BYTE;
      buf[byteIdx] := Nat8.bitor(buf[byteIdx], Nat8.bitshiftLeft((1 : Nat8), Nat8.fromNat(bitIdx)));
      // Keep the accumulator consistent if the patched bit is still in the
      // current partial byte (acc mirrors the low bits of buf[writeBit/8]).
      if (byteIdx == writeBit / BYTE) {
        acc := Nat64.bitor(acc, Nat64.bitshiftLeft((1 : Nat64), Nat64.fromNat(bitIdx)));
      };
    };

    /// Append one byte.
    public func addByte(b : Nat8) { addBits(BYTE, Nat8.toNat(b)) };

    /// Append an array of bytes.
    ///
    /// Fast path: when the write position is byte-aligned (`acc == 0`), bytes
    /// are copied directly into `buf` with a single `ensureCapacity` call and
    /// no bit-packing arithmetic.
    ///
    /// Slow path: pending partial bits in acc — pre-sizes once so inner
    /// addByte calls never trigger ensureCapacity.
    public func addBytes(bs : [Nat8]) {
      let n = bs.size();
      if (n == 0) return;
      if (writeBit % BYTE == 0) {
        let startByte = writeBit / BYTE;
        ensureCapacity(startByte + n);
        var i = 0;
        while (i < n) { buf[startByte + i] := bs[i]; i += 1 };
        writeBit += n * BYTE;
      } else {
        ensureCapacity(writeBit / BYTE + n + 1);
        for (b in bs.vals()) addByte(b);
      };
    };

    /// Pre-grow the backing store to hold at least `bytes` bytes without
    /// changing any logical state.  Callers that know the eventual write size
    /// upfront can call this once to eliminate all doubling reallocations.
    public func reserve(bytes : Nat) { ensureCapacity(bytes) };

    // ── Read operations ───────────────────────────────────────────────────

    /// Direct access to the backing store. Combined with `readBitPos()`, lets
    /// byte-aligned consumers read the live region in place without copying.
    /// The reference is only valid until the next write that grows `buf`.
    public func store() : [var Nat8] { buf };

    /// Absolute bit offset of the logical read position within `store()`
    /// (i.e. how many bits have been dropped from the front via `dropBits`).
    public func readBitPos() : Nat { readBit };

    /// Read the bit at logical position `i` (0 = first unread bit).
    public func getBit(i : Nat) : Bool {
      let abs = i + readBit;
      let byteIdx = abs / BYTE;
      let bitIdx = abs % BYTE;
      Nat8.bittest(buf[byteIdx], bitIdx);
    };

    /// Read `n` bits at logical bit position `i`, returned as a Nat (LSB first).
    public func getBits(i : Nat, n : Nat) : Nat {
      var bits : Nat32 = 0;
      var accumulated : Nat32 = 0;
      let abs = i + readBit;
      var byteIdx = abs / BYTE;
      var bitIdx = abs % BYTE;
      var remaining = n;
      while (remaining > 0) {
        let available : Nat = BYTE - bitIdx;
        let take : Nat = if (remaining < available) remaining else available;
        let shifted = buf[byteIdx] >> Nat8.fromNat(bitIdx);
        let extracted = shifted & MASKS8[take];
        bits := bits | (Nat32.fromNat8(extracted) << accumulated);
        accumulated += Nat32.fromNat(take);
        remaining -= take;
        byteIdx += 1;
        bitIdx := 0;
      };
      Nat32.toNat(bits);
    };

    /// Read up to 8 bits at bit position `i`, zero-padding if fewer bits remain.
    /// This is the `getBitsWithPotentialPartialEnd` equivalent from the reference.
    public func getByte(i : Nat) : Nat8 {
      let avail = bitSize();
      if (i >= avail) return 0;

      // Fast path: byte-aligned and a full byte is available — single array read,
      // skipping the getBits loop and all Nat32↔Nat conversions.
      let abs = i + readBit;
      let remaining_bits : Nat = avail - i;
      if (abs % BYTE == 0 and remaining_bits >= BYTE) return buf[abs / BYTE];

      let n : Nat = if (remaining_bits < BYTE) remaining_bits else BYTE;
      Nat8.fromNat(getBits(i, n));
    };

    /// Read `nbytes` bytes starting at bit position `startBit`.
    public func getBytes(startBit : Nat, nbytes : Nat) : [Nat8] {
      Array.tabulate<Nat8>(
        nbytes,
        func(i) {
          getByte(startBit + i * BYTE);
        },
      );
    };

    // ── Control operations ────────────────────────────────────────────────

    /// Pad to the next byte boundary by advancing `writeBit`.
    /// The partial accumulator byte (already written to buf) is zero-padded
    /// in the high bits; acc is cleared so the next write starts fresh.
    public func byteAlign() {
      let offset = writeBit % BYTE;
      if (offset != 0) {
        writeBit += BYTE - offset;
        acc := 0;
      };
    };

    /// Discard the first `n` bits from the logical read position.
    /// Traps if `n > bitSize()`.
    public func dropBits(n : Nat) {
      if (n > bitSize()) Runtime.trap("BitBuffer.dropBits: cannot drop more bits than available");
      readBit += n;
    };

    /// Drain all complete bytes from the write buffer, returning them as a
    /// fresh array.  Any partial trailing byte (when `writeBit % 8 != 0`) is
    /// relocated to `buf[0]` and `writeBit` is set to the remaining bit count,
    /// so subsequent writes continue correctly.
    ///
    /// Traps if `readBit != 0` (only valid on the encode path where nothing
    /// has been read back from the buffer).
    public func drainCompleteBytes() : [Nat8] {
      if (readBit != 0) Runtime.trap("BitBuffer.drainCompleteBytes: readBit != 0");
      let totalBytes = writeBit / BYTE;
      let partialBits = writeBit % BYTE;
      let result = Array.tabulate<Nat8>(totalBytes, func(i) { buf[i] });
      if (partialBits != 0) {
        buf[0] := buf[totalBytes];
      };
      writeBit := partialBits;
      // acc already holds only the partial-byte bits (low `partialBits` bits);
      // no change needed — it is consistent with buf[0].
      result;
    };

    /// Reset the buffer to empty, zeroing the live region.
    public func clear() {
      let live : Nat = (writeBit + BYTE - 1) / BYTE;
      var i = 0;
      while (i < live) { buf[i] := 0; i += 1 };
      writeBit := 0;
      readBit := 0;
      acc := 0;
    };

  }; // end class BitBuffer

  // ── Module-level constructor helpers (matches reference API) ─────────────

  /// Create an empty BitBuffer with default initial capacity.
  public func new() : BitBuffer { BitBuffer(0) };

};
