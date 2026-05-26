import Nat8 "mo:core/Nat8";

module {

  /// Direct callback consumer for LZSS encoder output.
  ///
  /// Replaces the prior `LzssEntry` variant + `Sink.add(entry)` design:
  /// emitting a literal or pointer no longer allocates a heap variant cell.
  /// This is the only encoder→consumer interface.
  public type MatchSink = {
    /// A byte that had no match in the look-back window.
    onLiteral : (byte : Nat8) -> ();
    /// A back-reference. `backward_offset` ∈ [1, MATCH_WINDOW_SIZE],
    /// `length` ∈ [3, MATCH_MAX_SIZE].
    onPointer : (backward_offset : Nat, length : Nat) -> ();
  };

  /// Controls the size of the search window and thus the speed/ratio trade-off.
  public type CompressionLevel = {
    /// Window = 1 024 bytes.  Fastest encoding, lowest compression ratio.
    #fast;
    /// Window = 8 192 bytes.  Balanced speed and compression ratio.
    #balance;
    /// Window = 32 768 bytes. Best compression ratio (default).
    #best;
  };

  /// Maximum look-back window size in bytes.
  public let MATCH_WINDOW_SIZE : Nat = 32_768;

  /// Maximum match length in bytes.
  public let MATCH_MAX_SIZE : Nat = 258;

};
