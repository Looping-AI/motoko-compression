/// Gzip header — RFC 1952 §2.3
///
/// Handles encoding and decoding of the 10-byte fixed Gzip header and its
/// optional extension fields (extra, filename, comment, CRC16).
///
/// Key differences from edjcase original:
///   - No `CompressionLevel` variant type: the XFL byte is derived from the
///     LZSS compression level supplied by the encoder (no separate type clash).
///   - `decode` returns `Result<Header, Text>` instead of trapping.
///   - `mo:base@0` + `mo:bitbuffer@1` → `mo:core` + our BitBuffer / BitReader.

import Blob "mo:core/Blob";
import Int "mo:core/Int";
import List "mo:core/List";
import Nat32 "mo:core/Nat32";
import Option "mo:core/Option";
import Result "mo:core/Result";
import Text "mo:core/Text";
import Time "mo:core/Time";

import BitBuffer "../internal/BitBuffer";
import BitReader "../internal/BitReader";
import CRC32 "../internal/CRC32";
import Common "../LZSS/Common";
import Utils "../internal/utils";

module {

  type BitBuffer = BitBuffer.BitBuffer;
  type BitReader = BitReader.BitReader;
  type CompressionLevel = Common.CompressionLevel;
  type Result<A, B> = Result.Result<A, B>;

  // ── Public types ────────────────────────────────────────────────────────

  /// An RFC 1952 "extra field" (FEXTRA section).
  public type ExtraField = {
    ids : (Nat8, Nat8);
    data : [Nat8];
  };

  /// Operating system identifier written into byte 9 of the header.
  public type Os = {
    #FatFs;
    #Amiga;
    #Vms;
    #Unix;
    #VmCms;
    #AtariTos;
    #Hpfs;
    #Macintosh;
    #ZSystem;
    #CpM;
    #Tops20;
    #Ntfs;
    #Qdos;
    #AcornRiscos;
    #Unknown;
  };

  /// Decoded Gzip header.
  public type Header = {
    is_text : Bool;
    /// Header CRC16 check was present and valid during decode.
    is_verified : Bool;
    extra_fields : [ExtraField];
    filename : ?Text;
    comment : ?Text;
    /// Unix epoch seconds (0 = not set).
    modification_time : Int;
    /// Raw XFL byte (0x02 = max compression, 0x04 = fast, 0x00 = unknown).
    xfl : Nat8;
    os : Os;
  };

  // ── Default header ───────────────────────────────────────────────────────

  public func defaultHeader() : Header = {
    is_text = false;
    is_verified = false;
    extra_fields = [];
    filename = null;
    comment = null;
    modification_time = Int.abs(Time.now()) / 1_000_000_000;
    xfl = 0x00;
    os = #Unix;
  };

  // ── Encode ───────────────────────────────────────────────────────────────

  /// Encode a Gzip header into `bitbuffer`.
  /// `lzss` is used to derive the XFL byte; pass `null` for no compression.
  public func encode(
    bitbuffer : BitBuffer,
    header : Header,
    lzss : ?CompressionLevel,
  ) {
    // Magic bytes
    bitbuffer.addByte(0x1f);
    bitbuffer.addByte(0x8b);

    // Compression method = deflate
    bitbuffer.addByte(8);

    // Flags byte (FLG)
    let has_extra = header.extra_fields.size() > 0;
    let has_filename = Option.isSome(header.filename);
    let has_comment = Option.isSome(header.comment);
    // FLG: bit0=FTEXT, bit1=FHCRC, bit2=FEXTRA, bit3=FNAME, bit4=FCOMMENT
    bitbuffer.addBit(header.is_text);
    bitbuffer.addBit(header.is_verified);
    bitbuffer.addBit(has_extra);
    bitbuffer.addBit(has_filename);
    bitbuffer.addBit(has_comment);
    // Reserved bits 5-7
    bitbuffer.addBit(false);
    bitbuffer.addBit(false);
    bitbuffer.addBit(false);

    // Modification time (4 bytes LE, 0 if not set)
    let mtime = if (header.modification_time > 0) header.modification_time else 0;
    let mtime_nat = Int.abs(mtime);
    bitbuffer.addBytes(Utils.natToLeBytes(mtime_nat, 4));

    // XFL — derived from LZSS level (overrides whatever header.xfl says)
    let xfl : Nat8 = switch lzss {
      case (?#best) 0x02;
      case (?#fast) 0x04;
      case _ 0x00;
    };
    bitbuffer.addByte(xfl);

    // OS
    bitbuffer.addByte(osToByte(header.os));

    // FEXTRA
    if (has_extra) {
      var total = 0;
      for ({ data } in header.extra_fields.vals()) {
        total += 4 + data.size();
      };
      bitbuffer.addBytes(Utils.natToLeBytes(total, 2));
      for ({ ids; data } in header.extra_fields.vals()) {
        bitbuffer.addByte(ids.0);
        bitbuffer.addByte(ids.1);
        bitbuffer.addBytes(Utils.natToLeBytes(data.size(), 2));
        bitbuffer.addBytes(data);
      };
    };

    // FNAME — null-terminated UTF-8
    switch (header.filename) {
      case (?name) {
        bitbuffer.addBytes(Blob.toArray(Text.encodeUtf8(name)));
        bitbuffer.addByte(0);
      };
      case null {};
    };

    // FCOMMENT — null-terminated UTF-8
    switch (header.comment) {
      case (?cmt) {
        bitbuffer.addBytes(Blob.toArray(Text.encodeUtf8(cmt)));
        bitbuffer.addByte(0);
      };
      case null {};
    };

    // FHCRC — CRC16 of the header bytes written so far
    if (header.is_verified) {
      let header_bytes = bitbuffer.getBytes(0, bitbuffer.byteSize());
      let crc32 = CRC32.checksum(header_bytes);
      let crc16 = Nat32.toNat(crc32 & 0xffff);
      bitbuffer.addBytes(Utils.natToLeBytes(crc16, 2));
    };
  };

  // ── Decode ───────────────────────────────────────────────────────────────

  /// Decode a Gzip header from `reader`, advancing the read position past it.
  /// Returns `#err` for invalid magic or compression method.
  public func decode(reader : BitReader) : Result<Header, Text> {

    // Magic
    if (reader.readByte() != 0x1f or reader.readByte() != 0x8b) {
      return #err("Gzip: invalid magic bytes (not a gzip stream)");
    };

    // Compression method
    if (reader.readByte() != 0x08) {
      return #err("Gzip: unsupported compression method (only deflate supported)");
    };

    // Flags
    let is_text = reader.readBit();
    let is_verified = reader.readBit();
    let has_extra = reader.readBit();
    let has_filename = reader.readBit();
    let has_comment = reader.readBit();
    ignore reader.readBits(3); // reserved

    // Modification time (4 bytes LE, Unix seconds)
    let mtime = Utils.leBytesToNat(reader.readBytes(4));

    // XFL
    let xfl = reader.readByte();

    // OS
    let os = byteToOs(reader.readByte());

    // FEXTRA
    let extra_fields : [ExtraField] = if (has_extra) {
      let extra_size = Utils.leBytesToNat(reader.readBytes(2));
      let fields = List.empty<ExtraField>();
      var remaining = extra_size;
      while (remaining > 0) {
        let id1 = reader.readByte();
        let id2 = reader.readByte();
        let size = Utils.leBytesToNat(reader.readBytes(2));
        let data = reader.readBytes(size);
        List.add(fields, { ids = (id1, id2); data });
        remaining -= 4 + size;
      };
      List.toArray(fields);
    } else { [] };

    // FNAME — read until null terminator
    let filename : ?Text = if (has_filename) {
      let bytes = List.empty<Nat8>();
      var b = reader.readByte();
      while (b != 0) {
        List.add(bytes, b);
        b := reader.readByte();
      };
      Text.decodeUtf8(Blob.fromArray(List.toArray(bytes)));
    } else {
      null;
    };

    // FCOMMENT — read until null terminator
    let comment : ?Text = if (has_comment) {
      let bytes = List.empty<Nat8>();
      var b = reader.readByte();
      while (b != 0) {
        List.add(bytes, b);
        b := reader.readByte();
      };
      Text.decodeUtf8(Blob.fromArray(List.toArray(bytes)));
    } else {
      null;
    };

    // FHCRC — verify CRC16 over the header bytes consumed so far
    if (is_verified) {
      let pos = reader.getPosition();
      let nbytes_so_far = pos / 8;
      // Re-read the header bytes from position 0 (reader is still open)
      reader.setPosition(0);
      let header_bytes = reader.readBytes(nbytes_so_far);
      reader.setPosition(pos);

      let calculated_crc16 = Nat32.toNat(CRC32.checksum(header_bytes) & 0xffff);
      let stored_crc16 = Utils.leBytesToNat(reader.readBytes(2));
      if (stored_crc16 != calculated_crc16) {
        return #err("Gzip: FHCRC header checksum mismatch");
      };
    };

    #ok({
      is_text;
      is_verified;
      extra_fields;
      filename;
      comment;
      modification_time = mtime;
      xfl;
      os;
    });
  };

  // ── OS helpers ─────────────────────────────────────────────────────────

  public func osToByte(os : Os) : Nat8 = switch os {
    case (#FatFs) 0x00;
    case (#Amiga) 0x01;
    case (#Vms) 0x02;
    case (#Unix) 0x03;
    case (#VmCms) 0x04;
    case (#AtariTos) 0x05;
    case (#Hpfs) 0x06;
    case (#Macintosh) 0x07;
    case (#ZSystem) 0x08;
    case (#CpM) 0x09;
    case (#Tops20) 0x0a;
    case (#Ntfs) 0x0b;
    case (#Qdos) 0x0c;
    case (#AcornRiscos) 0x0d;
    case (#Unknown) 0xff;
  };

  public func byteToOs(byte : Nat8) : Os = switch byte {
    case 0x00 #FatFs;
    case 0x01 #Amiga;
    case 0x02 #Vms;
    case 0x03 #Unix;
    case 0x04 #VmCms;
    case 0x05 #AtariTos;
    case 0x06 #Hpfs;
    case 0x07 #Macintosh;
    case 0x08 #ZSystem;
    case 0x09 #CpM;
    case 0x0a #Tops20;
    case 0x0b #Ntfs;
    case 0x0c #Qdos;
    case 0x0d #AcornRiscos;
    case _ #Unknown;
  };

};
