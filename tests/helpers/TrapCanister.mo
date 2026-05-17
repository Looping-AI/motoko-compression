/// Helper actor for testing that sync operations in BitReader trap as expected.
///
/// Each public method wraps a single operation that should trap. When the
/// inner sync call traps, the IC surfaces it as a #canister_error to the caller.
///
/// Intended for use from tests/BitReaderTraps.Test.mo (replica test).

import BitReader "../../src/BitReader";
import List "mo:core/List";
import LZSS "../../src/LZSS/lib";

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

  public func decodeBadOffset() : async () {
    let entries = List.empty<LZSS.LzssEntry>();
    List.add(entries, #pointer(5, 3)); // backward_offset=5 > output.size()=0
    ignore LZSS.decode(entries);
  };

};
