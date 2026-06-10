/// Bit-level reader backed by `internal/BitBuffer`.
///
/// Bits are consumed LSB-first (DEFLATE convention).
/// `offset` tracks how many bits have been read from the front of the buffer.
///
/// All reads are bounds-checked; violating the bounds traps.

import Nat "mo:core/Nat";
import Runtime "mo:core/Runtime";
import BitBuffer "BitBuffer";

module {

  /// Bit-level sequential reader backed by an internal `BitBuffer`.
  /// Bits are consumed LSB-first (DEFLATE convention).
  public class BitReader(initCapacity : Nat) {
    var offset = 0;
    let bitbuffer = BitBuffer.BitBuffer(initCapacity);

    // Invariant: available = bitbuffer.bitSize()
    // (readable bits at offset = 0, i.e. the upper bound on reads).
    // isValid(n) ≡ n + offset <= available.  Kept in sync by addBytes,
    // clearRead, and clear so the hot read path never calls bitbuffer.bitSize().
    var available = 0;

    // ── Bit-level reads ───────────────────────────────────────────────────

    /// Return the next bit without advancing the read position.
    public func peekBit() : Bool {
      if (offset >= available) {
        Runtime.trap("BitReader.peekBit: out of bounds or empty");
      };
      bitbuffer.getBit(offset);
    };

    /// Consume and return the next bit.
    public func readBit() : Bool {
      let bit = peekBit();
      offset += 1;
      bit;
    };

    /// Return the next `n` bits as a Nat (LSB-first) without advancing.
    public func peekBits(n : Nat) : Nat {
      if (n + offset > available) {
        Runtime.trap("BitReader.peekBits: out of bounds at offset");
      };
      bitbuffer.getBits(offset, n);
    };

    /// Consume and return the next `n` bits as a Nat (LSB-first).
    public func readBits(n : Nat) : Nat {
      let bits = peekBits(n);
      offset += n;
      bits;
    };

    // ── Byte-level reads ──────────────────────────────────────────────────

    /// Return the next byte without advancing the read position.
    public func peekByte() : Nat8 {
      if (8 + offset > available) {
        Runtime.trap("BitReader.peekByte: out of bounds");
      };
      // Dead branch removed: after bounds check, bitSize() >= 8 is guaranteed.
      bitbuffer.getByte(offset);
    };

    /// Consume and return the next byte.
    public func readByte() : Nat8 {
      let byte = peekByte();
      offset += 8;
      byte;
    };

    /// Consume up to `nbytes` bytes (clamped to available `byteSize()`).
    public func readBytes(nbytes : Nat) : [Nat8] {
      let minBytes = Nat.min(nbytes, byteSize());
      let result = bitbuffer.getBytes(offset, minBytes);
      offset += minBytes * 8;
      result;
    };

    // ── Size queries ──────────────────────────────────────────────────────

    /// Number of readable bits (excludes already-consumed and hidden tail bits).
    public func bitSize() : Nat {
      if (offset <= available) available - offset else 0;
    };

    /// Ceiling of available bits / 8 (rounds up for a partial trailing byte).
    public func byteSize() : Nat { (bitSize() + 7) / 8 };

    /// Expose the readable region as an in-place slice `(store, startByte, len)`
    /// of the underlying buffer, avoiding the copy that `readBytes` performs.
    /// Valid only when the read position is byte-aligned; traps otherwise.
    /// `store[startByte ..< startByte + len]` are the `byteSize()` readable bytes.
    public func readableSlice() : ([var Nat8], Nat, Nat) {
      let startBit = bitbuffer.readBitPos() + offset;
      if (startBit % 8 != 0) {
        Runtime.trap("BitReader.readableSlice: read position not byte-aligned");
      };
      (bitbuffer.store(), startBit / 8, byteSize());
    };

    // ── Alignment ─────────────────────────────────────────────────────────

    /// Skip the remaining bits in the last partial byte of readable data,
    /// so that `bitSize()` becomes a multiple of 8.
    public func byteAlign() {
      let size = bitSize();
      if (size % 8 != 0) {
        offset += (size % 8);
      };
    };

    // ── Position ──────────────────────────────────────────────────────────

    /// Return the current bit-offset (number of bits consumed so far).
    public func getPosition() : Nat { offset };

    /// Seek to an absolute bit-offset.
    public func setPosition(pos : Nat) { offset := pos };

    // ── State management ──────────────────────────────────────────────────

    /// Reset the read position to the beginning (data is preserved).
    public func reset() { offset := 0 };

    /// Discard all bits consumed so far from the underlying buffer and
    /// reset the read position. Reduces memory usage on long streams.
    public func clearRead() {
      available -= offset;
      bitbuffer.dropBits(offset);
      offset := 0;
    };

    /// Reset to a fully empty state (clears buffer, offset, and available count).
    public func clear() {
      offset := 0;
      available := 0;
      bitbuffer.clear();
    };

    // ── Write ─────────────────────────────────────────────────────────────

    /// Append bytes to the end of the buffer for future reading.
    public func addBytes(bytes : [Nat8]) {
      bitbuffer.addBytes(bytes);
      available += bytes.size() * 8;
    };

  };

  /// Convenience constructor: create a BitReader pre-loaded with `bytes`.
  public func fromBytes(bytes : [Nat8]) : BitReader {
    let reader = BitReader(bytes.size());
    reader.addBytes(bytes);
    reader;
  };

};
