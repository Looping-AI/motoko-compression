import Array "mo:core/Array";
import Iter "mo:core/Iter";
import Nat8 "mo:core/Nat8";

module {

  /// Instruction limit used by Gzip/Deflate encoders to split work across calls.
  public let INSTRUCTION_LIMIT : Nat = 1_048_576;

  /// Returns the ceiling of `num / divisor`.
  public func divCeil(num : Nat, divisor : Nat) : Nat {
    (num + (divisor - 1)) / divisor;
  };

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

  /// Decodes a big-endian byte array to a `Nat`.
  /// Empty array returns 0.
  public func bytesToNat(bytes : [Nat8]) : Nat {
    Array.foldLeft<Nat8, Nat>(bytes, 0, func(acc, b) = acc * 256 + Nat8.toNat(b));
  };

  /// Decodes a little-endian byte array to a `Nat`.
  /// Empty array returns 0.
  public func leBytesToNat(bytes : [Nat8]) : Nat {
    Array.foldRight<Nat8, Nat>(bytes, 0, func(b, acc) = acc * 256 + Nat8.toNat(b));
  };

  /// Returns an equality function for `[A]` given an element equality function.
  public func arrayEqual<A>(eq : (A, A) -> Bool) : ([A], [A]) -> Bool {
    func(a, b) = Array.equal(a, b, eq);
  };

  /// Returns an exclusive range iterator [lo, hi).
  /// Yields lo, lo+1, ..., hi-1. Returns empty if lo >= hi.
  public func range(lo : Nat, hi : Nat) : Iter.Iter<Nat> {
    object {
      var i = lo;
      public func next() : ?Nat {
        if (i >= hi) return null;
        let j = i;
        i += 1;
        ?j;
      };
    };
  };

  /// Returns a reverse exclusive range iterator (hi, lo].
  /// Yields hi-1, hi-2, ..., lo. Returns empty if hi <= lo.
  public func revRange(hi : Nat, lo : Nat) : Iter.Iter<Nat> {
    object {
      var i = hi;
      public func next() : ?Nat {
        if (i <= lo) return null;
        i -= 1;
        ?i;
      };
    };
  };

  /// Returns true if two iterators produce equal sequences under the given equality function.
  /// Consumes both iterators.
  public func iterEqual<T>(a : Iter.Iter<T>, b : Iter.Iter<T>, eq : (T, T) -> Bool) : Bool {
    loop {
      switch (a.next(), b.next()) {
        case (null, null) return true;
        case (?x, ?y) { if (not eq(x, y)) return false };
        case _ return false;
      };
    };
  };

};
