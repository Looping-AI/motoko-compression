import Array "mo:core/Array";
import Nat8 "mo:core/Nat8";

module {

  /// Instruction limit used by Gzip/Deflate encoders to split work across calls.
  public let INSTRUCTION_LIMIT : Nat = 1_048_576;

  /// Encodes `num` as a little-endian byte array of exactly `nbytes` bytes.
  /// Truncates high bytes silently if `num` overflows `nbytes`.
  public func natToLeBytes(num : Nat, nbytes : Nat) : [Nat8] {
    var n = num;
    Array.tabulate<Nat8>(
      nbytes,
      func _ {
        let b = Nat8.fromNat(n % 256);
        n /= 256;
        b;
      },
    );
  };

  /// Decodes a little-endian byte array to a `Nat`.
  /// Empty array returns 0.
  public func leBytesToNat(bytes : [Nat8]) : Nat {
    Array.foldRight<Nat8, Nat>(bytes, 0, func(b, acc) = acc * 256 + Nat8.toNat(b));
  };

};
