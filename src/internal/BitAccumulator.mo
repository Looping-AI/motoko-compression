/// Zlib-style Nat64 bit accumulator for LSB-first bit streams (DEFLATE).
///
/// The `hold` register accumulates bytes from the input LSB-first so that the
/// current bits are always in the low-order positions of `hold`.
///
/// Typical decode inner-loop usage:
///   1. `acc.refill()` — load up to 8 bytes from input (no-op if bits > 56).
///   2. `acc.peekNat(n)` — read n bits without consuming them.
///   3. `acc.drop(n)` — consume the n bits.
///
/// All hot operations are Nat64 arithmetic — no heap allocation, no bignum.

import Array "mo:core/Array";
import Nat8 "mo:core/Nat8";
import Nat64 "mo:core/Nat64";
import Runtime "mo:core/Runtime";

module {

  /// Bit accumulator over a slice `[start, start + len)` of a `[var Nat8]`
  /// backing store. The slice form lets callers (e.g. the Gzip decoder) feed
  /// the deflate stream straight from an existing buffer with no intermediate
  /// copy. Use the `fromArray` / `fromSlice` helpers below to construct one.
  public class BitAccumulator(input : [var Nat8], start : Nat, len : Nat) {
    var hold : Nat64 = 0; // bit accumulator (LSB-first)
    var bits : Nat64 = 0; // number of valid bits currently in hold (0..63)
    var pos : Nat = start; // absolute index of next byte to load from src

    let src : [var Nat8] = input;
    let base : Nat = start; // absolute index of the first slice byte
    let endPos : Nat = start + len; // absolute one-past-the-last slice byte

    // ── Core hot operations ───────────────────────────────────────────────

    /// Load bytes from input into hold until bits > 56 or input is exhausted.
    /// After refill, hold has at most 64 valid bits in its low-order positions.
    public func refill() {
      while (bits <= 56 and pos < endPos) {
        hold := hold | (Nat64.fromNat8(src[pos]) << bits);
        bits += 8;
        pos += 1;
      };
    };

    /// Return the lowest `n` bits of hold as Nat64 without consuming them.
    /// Caller must have called refill() to ensure bits ≥ n.
    public func peek(n : Nat) : Nat64 {
      hold & (((1 : Nat64) << Nat64.fromNat(n)) - 1);
    };

    /// Return the lowest `n` bits of hold as Nat without consuming them.
    public func peekNat(n : Nat) : Nat {
      Nat64.toNat(peek(n));
    };

    /// Consume `n` bits from hold. Must have bits ≥ n.
    public func drop(n : Nat) {
      hold := hold >> Nat64.fromNat(n);
      bits -= Nat64.fromNat(n);
    };

    // ── Composite reads ───────────────────────────────────────────────────

    /// Refill, then read and consume `n` bits as Nat.
    public func readBits(n : Nat) : Nat {
      refill();
      let v = peekNat(n);
      drop(n);
      v;
    };

    /// Refill, then read and consume 1 bit as Bool.
    public func readBit() : Bool {
      readBits(1) != 0;
    };

    /// Read one byte, draining hold first, then reading directly from src.
    /// Used for stored-block (type 0) byte-level reads.
    public func readByte() : Nat8 {
      if (bits >= 8) {
        let b = Nat8.fromNat(peekNat(8));
        hold := hold >> (8 : Nat64);
        bits -= 8;
        return b;
      };
      if (pos < endPos) {
        let b = src[pos];
        pos += 1;
        return b;
      };
      Runtime.trap("BitAccumulator.readByte: stream exhausted");
    };

    // ── Alignment ─────────────────────────────────────────────────────────

    /// Discard the partial-byte bits remaining in the current input byte so
    /// that the stream is byte-aligned.
    ///
    /// In DEFLATE this is called before reading a stored block's LEN/NLEN.
    /// If `bits % 8 == 0` the stream is already aligned; this is a no-op.
    public func byteAlign() {
      let rem = bits % 8;
      if (rem != 0) {
        hold := hold >> rem;
        bits -= rem;
      };
    };

    // ── Hot-path state access (for inlined decode loops) ─────────────────

    /// Snapshot hold/bits/pos for transfer to function-local variables.
    public func snapshotAcc() : (Nat64, Nat64, Nat) { (hold, bits, pos) };

    /// Restore hold/bits/pos from function-local variables.
    public func restoreAcc(h : Nat64, b : Nat64, p : Nat) {
      hold := h;
      bits := b;
      pos := p;
    };

    /// Raw input bytes — used by inlined refill loops.
    public func getBytes() : [var Nat8] { src };

    /// Absolute end index of the slice — used by inlined refill loops as the
    /// `pos` upper bound (compared against the absolute `pos`).
    public func getBytesLen() : Nat { endPos };

    // ── Size queries ──────────────────────────────────────────────────────

    /// Total bits remaining: bits in hold + bits still in input.
    public func bitsLeft() : Nat {
      Nat64.toNat(bits) + (endPos - pos) * 8;
    };

    /// Number of input bytes not yet loaded into hold.
    public func bytesLeft() : Nat {
      endPos - pos;
    };

    /// Bit offset consumed so far, relative to the start of the slice.
    /// Useful for error reporting and for locating a trailing footer.
    public func bitPosition() : Nat {
      (pos - base) * 8 - Nat64.toNat(bits);
    };

  };

  // ── Constructors ───────────────────────────────────────────────────────

  /// Build an accumulator over an immutable byte array. The bytes are copied
  /// into a fresh mutable buffer (`Array.toVarArray`); use `fromSlice` to avoid
  /// the copy when the data already lives in a `[var Nat8]`.
  public func fromArray(inputBytes : [Nat8]) : BitAccumulator {
    BitAccumulator(Array.toVarArray<Nat8>(inputBytes), 0, inputBytes.size());
  };

  /// Build an accumulator over the slice `[start, start + len)` of `src`
  /// without copying. The caller must keep `src` unmodified for the lifetime
  /// of the accumulator.
  public func fromSlice(src : [var Nat8], start : Nat, len : Nat) : BitAccumulator {
    BitAccumulator(src, start, len);
  };

};
