/// Deflate block implementations: raw (non-compressed) and compressed.
///
/// Migrated from edjcase/motoko_compression.
/// Buffer<Nat8> queue → mo:core/Queue; Buffer<Symbol> → mo:core/List.

import Array        "mo:core/Array";
import List         "mo:core/List";
import Nat          "mo:core/Nat";
import Queue        "mo:core/Queue";
import BitBuffer    "../internal/BitBuffer";
import LzssCommon   "../LZSS/Common";
import LzssEncoder  "../LZSS/Encoder/lib";
import Symbol       "Symbol";
import HuffmanCodec "HuffmanCodec";
import Utils        "../utils";

module {

  type BitBuffer = BitBuffer.BitBuffer;

  /// Maximum payload for a single raw (non-compressed) deflate block.
  public let NO_COMPRESSION_MAX_BLOCK_SIZE : Nat = 65_535;

  // ── Block type ─────────────────────────────────────────────────────────

  public type BlockType = {
    #Raw;
    #Fixed   : { lzss : LzssEncoder.Encoder; block_limit : Nat };
    #Dynamic : { lzss : LzssEncoder.Encoder; block_limit : Nat };
  };

  /// BTYPE value for each block kind (RFC 1951 §3.2.3).
  public func blockToNat(bt : BlockType) : Nat {
    switch bt {
      case (#Raw)        0;
      case (#Fixed(_))   1;
      case (#Dynamic(_)) 2;
    };
  };

  // ── Block interface ────────────────────────────────────────────────────

  public type BlockInterface = {
    size   : () -> Nat;
    append : ([Nat8]) -> ();
    add    : (Nat8) -> ();
    flush  : (BitBuffer) -> ();
    clear  : () -> ();
  };

  /// Construct a block of the given type.
  public func Block(bt : BlockType) : BlockInterface {
    switch bt {
      case (#Raw) Raw();
      case (#Fixed({ lzss; block_limit })) {
        Compress(lzss, HuffmanCodec.FixedHuffmanCodec(), block_limit);
      };
      case (#Dynamic({ lzss; block_limit })) {
        Compress(lzss, HuffmanCodec.DynamicHuffmanCodec(), block_limit);
      };
    };
  };

  // ── Raw block ──────────────────────────────────────────────────────────

  public class Raw() {
    let queue = Queue.empty<Nat8>();
    var input_size : Nat = 0;

    public func size() : Nat { input_size };

    public func add(byte : Nat8) {
      input_size += 1;
      Queue.pushBack(queue, byte);
    };

    public func append(bytes : [Nat8]) {
      for (b in bytes.vals()) add(b);
    };

    public func flush(bitbuffer : BitBuffer) {
      // Pad to byte boundary (BFINAL + BTYPE may have left partial byte)
      bitbuffer.byteAlign();
      let sz       = Nat.min(NO_COMPRESSION_MAX_BLOCK_SIZE, input_size);
      let sz_bytes = Utils.nat_to_le_bytes(sz, 2);
      // LEN then NLEN (one's complement of LEN)
      bitbuffer.addBytes(sz_bytes);
      bitbuffer.addBytes(Array.map<Nat8, Nat8>(sz_bytes, func(x) { ^x }));
      var i = 0;
      while (i < sz) {
        let ?byte = Queue.popFront(queue) else return;
        input_size -= 1;
        bitbuffer.addByte(byte);
        i += 1;
      };
    };

    public func clear() {
      Queue.clear(queue);
      input_size := 0;
    };
  };

  // ── Compressed block ───────────────────────────────────────────────────

  public class Compress(
    lzss    : LzssEncoder.Encoder,
    huffman : HuffmanCodec.HuffmanCodec,
    _       : Nat,                       // block_limit (unused here; enforced by Encoder)
  ) {
    var input_size : Nat = 0;
    let compressed = List.empty<Symbol.Symbol>();

    let sink : LzssEncoder.Sink = {
      add = func(entry : LzssCommon.LzssEntry) {
        List.add(compressed, entry);
      };
    };

    public func size() : Nat { input_size };

    public func add(byte : Nat8) {
      input_size += 1;
      lzss.encode_byte(byte, sink);
    };

    public func append(bytes : [Nat8]) {
      input_size += bytes.size();
      lzss.encode(bytes, sink);
    };

    public func flush(bitbuffer : BitBuffer) {
      // Drain the LZSS lookahead buffer
      lzss.flush(sink);

      // Build the Huffman codec for the symbols collected so far
      let symbol_encoder = switch (huffman.build(List.values(compressed))) {
        case (#ok(e)) e;
        case (#err(_)) return;  // should never happen
      };

      // Write the codec header (no-op for fixed, code lengths for dynamic)
      ignore huffman.save(bitbuffer, symbol_encoder);

      // Encode each compressed symbol
      for (sym in List.values(compressed)) {
        symbol_encoder.encode(bitbuffer, sym);
      };
      // End-of-block marker
      symbol_encoder.encode(bitbuffer, #EndOfBlock);

      // Reset state for next block
      input_size := 0;
      List.clear(compressed);
    };

    public func clear() {
      lzss.clear();
      List.clear(compressed);
      input_size := 0;
    };
  };

}
