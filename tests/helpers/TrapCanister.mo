/// Helper actor for testing that sync operations in BitReader trap as expected.
///
/// Each public method wraps a single operation that should trap. When the
/// inner sync call traps, the IC surfaces it as a #canister_error to the caller.
///
/// Intended for use from tests/BitReaderTraps.Test.mo (replica test).

import BitReader "../../src/BitReader";

persistent actor class TrapCanister() {

  public func peekBitOnEmpty() : async () {
    let r = BitReader.BitReader();
    ignore r.peekBit(); // traps: out of bounds on empty reader
  };

  public func readBitsOverflow() : async () {
    let r = BitReader.fromBytes([0xA5 : Nat8]); // 8 bits available
    ignore r.readBits(9);                        // traps: only 8 bits available
  };

  public func skipBitsOverflow() : async () {
    let r = BitReader.fromBytes([0xA5 : Nat8]);
    r.skipBits(9); // traps: only 8 bits available
  };

  public func peekByteOnEmpty() : async () {
    let r = BitReader.BitReader();
    ignore r.peekByte(); // traps: needs 8 bits, none available
  };

};
