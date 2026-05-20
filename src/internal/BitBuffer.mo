/// Bit-level read/write buffer.
///
/// Bits are packed LSB-first within each byte (DEFLATE convention):
///   addBits(3, 5)  --  value 5 = binary 101, writes bits [1, 0, 1]
///                      into positions [0, 1, 2] of the current byte.
///
/// Write position: tracked by `writeBit` (total bits appended).
/// Read  position: tracked by `readBit`  (bits dropped from the front).
/// `bitSize() = writeBit - readBit`.
///
/// The backing array never shrinks; it doubles in capacity when full.

import Prim "mo:⛔";
import Runtime "mo:core/Runtime";
import Nat8 "mo:core/Nat8";
import Nat32 "mo:core/Nat32";
import Iter "mo:core/Iter";
import Array "mo:core/Array";

module {

  let BYTE : Nat = 8;

  // Precomputed bit masks — MASKS8[k] / MASKS32[k] = 2^k − 1 for k in 0..8.
  // Used to avoid bignum `2 ** k` exponentiation in the inner read/write loops.
  let MASKS8 : [Nat8] = [0, 1, 3, 7, 15, 31, 63, 127, 255];
  let MASKS32 : [Nat32] = [0, 1, 3, 7, 15, 31, 63, 127, 255];

  public class BitBuffer(initCapacity : Nat) {

    // ── Backing store ─────────────────────────────────────────────────────
    var cap : Nat = if (initCapacity == 0) 8 else initCapacity;
    var buf : [var Nat8] = Prim.Array_init<Nat8>(cap, (0 : Nat8));

    var writeBit : Nat = 0; // total bits written
    var readBit : Nat = 0; // logical bits dropped from front

    // ── Internal helpers ─────────────────────────────────────────────────

    // Grow `buf` so that it can hold at least `needed` bytes.
    // Copies only the live bytes (0 .. ceil(writeBit/8)).
    func ensureCapacity(needed : Nat) {
      if (needed <= cap) return;
      while (cap < needed) cap *= 2;
      let newBuf = Prim.Array_init<Nat8>(cap, (0 : Nat8));
      let live = (writeBit + BYTE - 1) / BYTE;
      var i = 0;
      while (i < live) { newBuf[i] := buf[i]; i += 1 };
      buf := newBuf;
    };

    // ── Size queries ─────────────────────────────────────────────────────

    /// Number of unread bits currently stored.
    public func bitSize() : Nat { writeBit - readBit };

    /// Number of bytes needed to hold the current unread bits.
    public func byteSize() : Nat { (bitSize() + BYTE - 1) / BYTE };

    // ── Write operations ─────────────────────────────────────────────────

    /// Append a single bit (true = 1, false = 0).
    public func addBit(bit : Bool) {
      let byteIdx = writeBit / BYTE;
      let bitIdx = writeBit % BYTE;
      ensureCapacity(byteIdx + 1);
      if (bit) buf[byteIdx] := Nat8.bitset(buf[byteIdx], bitIdx);
      writeBit += 1;
    };

    /// Append the low `n` bits of `value`, LSB first.
    /// E.g. addBits(3, 5) writes bits [1, 0, 1] (5 = binary 101).
    /// High bits of `value` above bit `n-1` are ignored.
    public func addBits(n : Nat, value : Nat) {
      if (n == 0) return;
      // Pre-grow once for the entire write instead of once per byte-boundary.
      ensureCapacity((writeBit + n - 1) / BYTE + 1);
      var remaining = n;
      // Nat32 avoids bignum `2**take`, `v % 2**take`, `v /= 2**take` on every
      // iteration. Safe for all practical n (max DEFLATE symbol ≤ 29 bits).
      var v : Nat32 = Nat32.fromNat(value);
      while (remaining > 0) {
        let byteIdx = writeBit / BYTE;
        let bitIdx = writeBit % BYTE;
        let take = if (remaining < BYTE - bitIdx) remaining else BYTE - bitIdx;
        let bits = Nat32.toNat8(v & MASKS32[take]);
        buf[byteIdx] := buf[byteIdx] | (bits << Nat8.fromNat(bitIdx));
        v := Nat32.bitshiftRight(v, Nat32.fromNat(take));
        writeBit += take;
        remaining -= take;
      };
    };

    /// Append one byte.
    public func addByte(b : Nat8) { addBits(BYTE, Nat8.toNat(b)) };

    /// Append an array of bytes.
    ///
    /// Fast path: when the write position is byte-aligned (the common case —
    /// buffer is fresh, or after `byteAlign()`), bytes are copied directly into
    /// `buf` with a single `ensureCapacity` call and no bit-packing arithmetic.
    ///
    /// Slow path: unaligned write position — pre-sizes once so that all inner
    /// `ensureCapacity` calls inside the per-byte loop are no-ops.
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
        let take = if (remaining < BYTE - bitIdx) remaining else BYTE - bitIdx;
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
      if (abs % BYTE == 0 and avail - i >= BYTE) return buf[abs / BYTE];

      let n = if (avail - i < BYTE) avail - i else BYTE;
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
    /// Bits in the partial byte beyond the current `writeBit` are already 0.
    public func byteAlign() {
      let offset = writeBit % BYTE;
      if (offset != 0) writeBit += BYTE - offset;
    };

    /// Discard the first `n` bits from the logical read position.
    /// Traps if `n > bitSize()`.
    public func dropBits(n : Nat) {
      if (n > bitSize()) Runtime.trap("BitBuffer.dropBits: cannot drop more bits than available");
      readBit += n;
    };

    /// Reset the buffer to empty, zeroing the live region.
    public func clear() {
      let live = (writeBit + BYTE - 1) / BYTE;
      var i = 0;
      while (i < live) { buf[i] := 0; i += 1 };
      writeBit := 0;
      readBit := 0;
    };

    // ── Iteration ─────────────────────────────────────────────────────────

    /// Iterate over bytes from the logical read position to the end.
    /// Traps if `readBit` is not byte-aligned (mid-byte iteration is ambiguous).
    /// Callers that mix `dropBits` with `bytes()` must `dropBits` in multiples of 8
    /// or `byteAlign` the read side via their own accounting before iterating.
    public func bytes() : Iter.Iter<Nat8> {
      if (readBit % BYTE != 0) {
        Runtime.trap("BitBuffer.bytes: readBit is not byte-aligned");
      };
      let startByte = readBit / BYTE;
      let endByte = (writeBit + BYTE - 1) / BYTE;
      object {
        var pos = startByte;
        public func next() : ?Nat8 {
          if (pos >= endByte) return null;
          let b = buf[pos];
          pos += 1;
          ?b;
        };
      };
    };

  }; // end class BitBuffer

  // ── Module-level constructor helpers (matches reference API) ─────────────

  /// Create an empty BitBuffer with default initial capacity.
  public func new() : BitBuffer { BitBuffer(0) };

};
