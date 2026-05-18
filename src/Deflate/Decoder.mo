/// Deflate decoder.
///
/// Reads a deflate-compressed bitstream block by block, appending decoded
/// bytes to an internal (or caller-supplied) List<Nat8>.
///
/// Key differences from edjcase original:
///   - Buffer<Nat8> output → List.List<Nat8> (mo:core)
///   - Recursive decode() → iterative label/loop (no recursion in Motoko async)
///   - No `debug {}` wrapper (would swallow all logic in production)

import Array        "mo:core/Array";
import List         "mo:core/List";
import Option       "mo:core/Option";
import Result       "mo:core/Result";
import BitReader    "../BitReader";
import HuffmanCodec "HuffmanCodec";
import LzssDecoder  "../LZSS/Decoder";
import Utils        "../utils";

module {

  type BitReader = BitReader.BitReader;
  type Result<A, B> = Result.Result<A, B>;

  // ── Decoder class ──────────────────────────────────────────────────────

  public class Decoder(bitreader : BitReader, output_buffer : ?List.List<Nat8>) {

    var end_of_blocks : Bool = false;
    let buffer       = Option.get(output_buffer, List.empty<Nat8>());
    let lzss         = LzssDecoder.Decoder();

    /// Process deflate blocks until the final block or the stream is empty.
    public func decode() : Result<(), Text> {
      label _loop loop {
        // Stop if the final block has been processed
        if (end_of_blocks) break _loop;
        // Stream ran out of bits before we saw BFINAL=1
        if (bitreader.bitSize() == 0) {
          return #err("Deflate: stream ended before final block");
        };

        end_of_blocks := bitreader.readBit();         // BFINAL
        let block_type = bitreader.readBits(2);       // BTYPE

        let res : Result<(), Text> = if (block_type == 0) {
          decode_non_compressed();
        } else if (block_type == 1) {
          decode_compressed(HuffmanCodec.FixedHuffmanCodec());
        } else if (block_type == 2) {
          decode_compressed(HuffmanCodec.DynamicHuffmanCodec());
        } else {
          #err("Deflate: invalid block type " # debug_show block_type);
        };

        switch res {
          case (#err(msg)) return #err(msg);
          case (#ok(_)) {};
        };
      };
      #ok();
    };

    /// Decode a non-compressed (raw) block.
    func decode_non_compressed() : Result<(), Text> {
      bitreader.byteAlign();
      let size_bytes   = bitreader.readBytes(2);
      let size         = Utils.le_bytes_to_nat(size_bytes);
      let nlen         = Utils.le_bytes_to_nat(bitreader.readBytes(2));
      // Verify NLEN == one's complement of LEN
      let expected_nlen = Utils.le_bytes_to_nat(
        Array.map<Nat8, Nat8>(size_bytes, func(b) { ^b }),
      );
      if (nlen != expected_nlen) {
        return #err("Deflate: LEN/NLEN mismatch in non-compressed block");
      };
      for (byte in bitreader.readBytes(size).vals()) {
        List.add(buffer, byte);
      };
      #ok();
    };

    /// Decode a Huffman-compressed block (fixed or dynamic).
    func decode_compressed(huffman : HuffmanCodec.HuffmanCodec) : Result<(), Text> {
      let sym_dec = switch (huffman.load(bitreader)) {
        case (#ok(d)) d;
        case (#err(msg)) return #err(msg);
      };
      label _loop loop {
        let sym = switch (sym_dec.decode(bitreader)) {
          case (#ok(s)) s;
          case (#err(msg)) return #err(msg);
        };
        switch sym {
          case (#EndOfBlock)      break _loop;
          case (#literal(lit))    lzss.decodeEntry(buffer, #literal(lit));
          case (#pointer(back))   lzss.decodeEntry(buffer, #pointer(back));
        };
      };
      #ok();
    };

    /// Process any remaining data in the bitreader and return.
    public func finish() : Result<(), Text> { decode() };

    /// Return all decoded bytes as an immutable array.
    public func toArray() : [Nat8] { List.toArray(buffer) };

    /// Feed more compressed bytes into the underlying bit-reader.
    public func addBytes(bytes : [Nat8]) { bitreader.addBytes(bytes) };
  };

}
