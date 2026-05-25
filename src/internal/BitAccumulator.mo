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

import Nat8 "mo:core/Nat8";
import Nat32 "mo:core/Nat32";
import Nat64 "mo:core/Nat64";
import Runtime "mo:core/Runtime";

module {

  public class BitAccumulator(inputBytes : [Nat8]) {
    var hold : Nat64 = 0; // bit accumulator (LSB-first)
    var bits : Nat64 = 0; // number of valid bits currently in hold (0..63)
    var pos : Nat = 0; // index of next byte to load from src

    let src : [Nat8] = inputBytes;
    let srcLen : Nat = inputBytes.size();

    // ── Core hot operations ───────────────────────────────────────────────

    /// Load bytes from input into hold until bits > 56 or input is exhausted.
    /// After refill, hold has at most 64 valid bits in its low-order positions.
    public func refill() {
      while (bits <= 56 and pos < srcLen) {
        hold := hold | (Nat64.fromNat32(Nat32.fromNat8(src[pos])) << bits);
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
      if (pos < srcLen) {
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

    // ── Size queries ──────────────────────────────────────────────────────

    /// Total bits remaining: bits in hold + bits still in input.
    public func bitsLeft() : Nat {
      Nat64.toNat(bits) + (srcLen - pos) * 8;
    };

    /// Number of input bytes not yet loaded into hold.
    public func bytesLeft() : Nat {
      srcLen - pos;
    };

    /// Bit offset consumed so far, relative to the start of the input.
    /// Useful for error reporting.
    public func bitPosition() : Nat {
      pos * 8 - Nat64.toNat(bits);
    };

  };

};
