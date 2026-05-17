import Iter "mo:core/Iter";

module {

  /// Returns an exclusive range iterator [lo, hi).
  /// Yields lo, lo+1, ..., hi-1. Returns empty if lo >= hi.
  public func range(lo : Nat, hi : Nat) : Iter.Iter<Nat> {
    object {
      var i = lo;
      public func next() : ?Nat {
        if (i >= hi) return null;
        let j = i;
        i += 1;
        ?j
      };
    }
  };

  /// Returns a reverse exclusive range iterator (hi, lo].
  /// Yields hi-1, hi-2, ..., lo. Returns empty if hi <= lo.
  public func revRange(hi : Nat, lo : Nat) : Iter.Iter<Nat> {
    object {
      var i = hi;
      public func next() : ?Nat {
        if (i <= lo) return null;
        i -= 1;
        ?i
      };
    }
  };

  /// Returns true if two iterators produce equal sequences under the given equality function.
  /// Consumes both iterators.
  public func iterEqual<T>(a : Iter.Iter<T>, b : Iter.Iter<T>, eq : (T, T) -> Bool) : Bool {
    loop {
      switch (a.next(), b.next()) {
        case (null, null) return true;
        case (?x, ?y) { if (not eq(x, y)) return false };
        case _ return false;
      }
    };
  };

}
