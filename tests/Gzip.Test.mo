import { test; suite; expect } "mo:test";
import Array "mo:core/Array";
import List "mo:core/List";
import Nat8 "mo:core/Nat8";
import Runtime "mo:core/Runtime";

import Gzip "../src/Gzip/lib";

// ── Helpers ───────────────────────────────────────────────────────────────

/// Encode `data` with `enc`, decode via the streaming API, collecting chunks
/// into a single array. Used by all round-trip tests.
func roundTripStreaming(data : [Nat8], enc : Gzip.EncoderBuilder) : [Nat8] {
  let encoder = enc.build();
  encoder.encode(data);
  encoder.finish();
  let compressed = encoder.compressed();

  let decoder = Gzip.Decoder();
  switch (decoder.decode(compressed)) {
    case (#err(msg)) Runtime.trap("decode error: " # msg);
    case (#ok(_)) {};
  };

  let collected = List.empty<Nat8>();
  let consume = func(out : [Nat8]) {
    for (b in out.vals()) List.add(collected, b);
  };
  switch (decoder.finishStreaming(consume)) {
    case (#err(msg)) Runtime.trap("finishStreaming error: " # msg);
    case (#ok(summary)) {
      if (summary.size != List.size(collected)) {
        Runtime.trap("finishStreaming size mismatch");
      };
    };
  };
  List.toArray(collected);
};

func defaultBuilder() : Gzip.EncoderBuilder {
  Gzip.EncoderBuilder();
};

/// Encode `data` with `enc`, returning compressed bytes.
func encodeStreamingBytes(data : [Nat8], enc : Gzip.EncoderBuilder) : [Nat8] {
  let encoder = enc.build();
  encoder.encode(data);
  encoder.finish();
  encoder.compressed();
};

/// Encode `data` streaming, decode and return the decompressed bytes.
func roundTripEncodeStreaming(data : [Nat8], enc : Gzip.EncoderBuilder) : [Nat8] {
  let compressed = encodeStreamingBytes(data, enc);
  let decoder = Gzip.Decoder();
  switch (decoder.decode(compressed)) {
    case (#err msg) Runtime.trap("roundTripEncodeStreaming decode error: " # msg);
    case (#ok _) {};
  };
  let collected = List.empty<Nat8>();
  switch (decoder.finishStreaming(func(c) { List.addAll(collected, c.vals()) })) {
    case (#err msg) Runtime.trap("roundTripEncodeStreaming finishStreaming error: " # msg);
    case (#ok _) {};
  };
  List.toArray(collected);
};

/// Streaming encode + decode only — no additional comparison.
/// Use for large inputs where double-encoding is prohibitive.
func fastRoundTripEncodeStreaming(data : [Nat8], enc : Gzip.EncoderBuilder) : [Nat8] {
  let compressed = encodeStreamingBytes(data, enc);
  let decoder = Gzip.Decoder();
  switch (decoder.decode(compressed)) {
    case (#err msg) Runtime.trap("fastRoundTripEncodeStreaming decode error: " # msg);
    case (#ok _) {};
  };
  let collected = List.empty<Nat8>();
  switch (decoder.finishStreaming(func(c) { List.addAll(collected, c.vals()) })) {
    case (#err msg) Runtime.trap("fastRoundTripEncodeStreaming finishStreaming error: " # msg);
    case (#ok _) {};
  };
  List.toArray(collected);
};

// ── Suite: LZSS level options ─────────────────────────────────────────────

suite(
  "LZSS compression levels",
  func() {

    test(
      "#fast level",
      func() {
        let data = Array.tabulate<Nat8>(512, func(i) { Nat8.fromNat(i % 64) });
        let enc = Gzip.EncoderBuilder().lzss(#fast);
        expect.array(roundTripStreaming(data, enc), Nat8.toText, Nat8.equal).equal(data);
      },
    );

    test(
      "#balance level",
      func() {
        let data = Array.tabulate<Nat8>(512, func(i) { Nat8.fromNat(i % 64) });
        let enc = Gzip.EncoderBuilder().lzss(#balance);
        expect.array(roundTripStreaming(data, enc), Nat8.toText, Nat8.equal).equal(data);
      },
    );

    test(
      "#best level",
      func() {
        let data = Array.tabulate<Nat8>(512, func(i) { Nat8.fromNat(i % 64) });
        let enc = Gzip.EncoderBuilder().lzss(#best);
        expect.array(roundTripStreaming(data, enc), Nat8.toText, Nat8.equal).equal(data);
      },
    );

  },
);

// ── Suite: Header fields preserved ───────────────────────────────────────

suite(
  "Header fields",
  func() {

    test(
      "OS byte preserved",
      func() {
        let h = { Gzip.defaultHeader() with os = #Macintosh };
        let encoder = Gzip.EncoderBuilder().header(h).build();
        encoder.encode([1, 2, 3]);
        encoder.finish();
        let compressed = encoder.compressed();

        let dec = Gzip.Decoder();
        ignore dec.decode(compressed);
        let nop = func(_ : [Nat8]) {};
        switch (dec.finishStreaming(nop)) {
          case (#ok(r)) {
            switch (r.header.os) {
              case (#Macintosh) {};
              case (other) Runtime.trap("Expected #Macintosh, got " # debug_show other);
            };
          };
          case (#err(msg)) Runtime.trap(msg);
        };
      },
    );

    test(
      "filename preserved",
      func() {
        let h = { Gzip.defaultHeader() with filename = ?"hello.txt" };
        let encoder = Gzip.EncoderBuilder().header(h).build();
        encoder.encode([1, 2, 3]);
        encoder.finish();
        let compressed = encoder.compressed();

        let dec = Gzip.Decoder();
        ignore dec.decode(compressed);
        let nop = func(_ : [Nat8]) {};
        switch (dec.finishStreaming(nop)) {
          case (#ok(r)) {
            switch (r.header.filename) {
              case (?"hello.txt") {};
              case (other) Runtime.trap("Filename mismatch: " # debug_show other);
            };
          };
          case (#err(msg)) Runtime.trap(msg);
        };
      },
    );

  },
);

// ── Suite: Streaming encode correctness ──────────────────────────────────

suite(
  "Streaming encode correctness",
  func() {

    test(
      "tiny deflate block size round-trips correctly",
      func() {
        // 1-byte deflate block size forces a new Deflate block per byte,
        // exercising the block-flush callback path heavily.
        let data = Array.tabulate<Nat8>(64, func(i) { Nat8.fromNat(i) });
        expect.array(roundTripStreaming(data, Gzip.EncoderBuilder().deflateBlockSize(1)), Nat8.toText, Nat8.equal).equal(data);
      },
    );

    test(
      "finish() output is a valid gzip stream",
      func() {
        let data = Array.tabulate<Nat8>(256, func(i) { Nat8.fromNat(i % 128) });
        let encoder = Gzip.EncoderBuilder().deflateBlockSize(64).build();
        encoder.encode(data);
        encoder.finish();
        let compressed = encoder.compressed();
        // Valid gzip: non-empty, starts with magic bytes 0x1f 0x8b, decompresses correctly.
        expect.bool(compressed.size() > 0).isTrue();
        expect.nat8(compressed[0]).equal(0x1f);
        expect.nat8(compressed[1]).equal(0x8b);
        let dec = Gzip.Decoder();
        ignore dec.decode(compressed);
        let out = List.empty<Nat8>();
        switch (dec.finishStreaming(func cs { List.addAll(out, cs.vals()) })) {
          case (#err msg) Runtime.trap(msg);
          case (#ok _) {};
        };
        expect.array(List.toArray(out), Nat8.toText, Nat8.equal).equal(data);
      },
    );

    test(
      "encoder reuses cleanly — two consecutive compressions are independent",
      func() {
        let enc = Gzip.EncoderBuilder().build();
        let dataA = Array.tabulate<Nat8>(512, func(i) { Nat8.fromNat(i % 64) });
        let dataB = Array.tabulate<Nat8>(256, func(i) { Nat8.fromNat(255 - i % 128) });

        enc.encode(dataA);
        enc.finish();
        let compA = enc.compressed(); // explicit read then clear
        enc.clear();

        enc.encode(dataB);
        enc.finish();
        let compB = enc.compressed();
        enc.clear();

        // Both compressed outputs decompress back to their original input.
        let dec = Gzip.Decoder();
        ignore dec.decode(compA);
        let outA = List.empty<Nat8>();
        switch (dec.finishStreaming(func cs { List.addAll(outA, cs.vals()) })) {
          case (#err msg) Runtime.trap("reuse test decode A: " # msg);
          case (#ok _) {};
        };
        expect.array(List.toArray(outA), Nat8.toText, Nat8.equal).equal(dataA);

        ignore dec.decode(compB);
        let outB = List.empty<Nat8>();
        switch (dec.finishStreaming(func cs { List.addAll(outB, cs.vals()) })) {
          case (#err msg) Runtime.trap("reuse test decode B: " # msg);
          case (#ok _) {};
        };
        expect.array(List.toArray(outB), Nat8.toText, Nat8.equal).equal(dataB);
      },
    );

  },
);

// ── Suite: Error handling ─────────────────────────────────────────────────

suite(
  "Error handling",
  func() {

    test(
      "invalid magic bytes → #err",
      func() {
        let decoder = Gzip.Decoder();
        ignore decoder.decode([0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03]);
        let nop = func(_ : [Nat8]) {};
        switch (decoder.finishStreaming(nop)) {
          case (#err(_)) {}; // expected
          case (#ok(_)) Runtime.trap("Expected error for invalid magic bytes");
        };
      },
    );

    test(
      "CRC32 mismatch → #err",
      func() {
        let encoder = Gzip.EncoderBuilder().build();
        encoder.encode([1, 2, 3, 4, 5]);
        encoder.finish();
        let all = encoder.compressed();

        // Corrupt a byte in the middle of the payload
        let corrupted = Array.tabulate<Nat8>(
          all.size(),
          func(i) {
            if (i == 12) { ^all[i] } else { all[i] } // flip bits at offset 12
          },
        );

        let decoder = Gzip.Decoder();
        ignore decoder.decode(corrupted);
        let nop = func(_ : [Nat8]) {};
        switch (decoder.finishStreaming(nop)) {
          case (#err(_)) {}; // expected
          case (#ok(_)) Runtime.trap("Expected error for corrupted data");
        };
      },
    );

  },
);

// ── Suite: Streaming decode (finishStreaming) ────────────────────────────

suite(
  "Streaming decode",
  func() {

    test(
      "large multi-block input exercises window flush",
      func() {
        // 200 KiB spans many 32 KiB deflate blocks, forcing the sliding-window
        // flush + compaction path and long-distance back-references.
        let data = Array.tabulate<Nat8>(
          200 * 1024,
          func(i) { Nat8.fromNat((i * 31 + i / 251) % 256) },
        );
        expect.array(roundTripStreaming(data, defaultBuilder()), Nat8.toText, Nat8.equal).equal(data);
      },
    );

    test(
      "incompressible large input round-trips",
      func() {
        let rand = Array.tabulate<Nat8>(
          100 * 1024,
          func(i) { Nat8.fromNat((i * 2_654_435_761) % 256) },
        );
        expect.array(roundTripStreaming(rand, defaultBuilder()), Nat8.toText, Nat8.equal).equal(rand);
      },
    );

  },
);

// ── Suite: Streaming encode (finish) ─────────────────────────────────────

suite(
  "Streaming encode",
  func() {

    test(
      "large multi-block input exercises the 1 MiB flush threshold",
      func() {
        // 1.1 MiB spans multiple 32 KiB deflate blocks and forces the
        // STREAM_FLUSH_THRESHOLD drain path.
        let data = Array.tabulate<Nat8>(
          1126 * 1024,
          func(i) { Nat8.fromNat((i * 31 + i / 251) % 256) },
        );
        let result = fastRoundTripEncodeStreaming(data, defaultBuilder());
        expect.nat(result.size()).equal(data.size());
      },
    );

    test(
      "incompressible large input round-trips",
      func() {
        let rand = Array.tabulate<Nat8>(
          100 * 1024,
          func(i) { Nat8.fromNat((i * 2_654_435_761) % 256) },
        );
        expect.array(roundTripEncodeStreaming(rand, defaultBuilder()), Nat8.toText, Nat8.equal).equal(rand);
      },
    );

    test(
      "round-trips correctly across Huffman modes",
      func() {
        let data = Array.tabulate<Nat8>(64 * 1024, func(i) { Nat8.fromNat(i % 251) });
        expect.array(roundTripEncodeStreaming(data, Gzip.EncoderBuilder().dynamicHuffman()), Nat8.toText, Nat8.equal).equal(data);
        expect.array(roundTripEncodeStreaming(data, Gzip.EncoderBuilder().fixedHuffman()), Nat8.toText, Nat8.equal).equal(data);
        expect.array(roundTripEncodeStreaming(data, Gzip.EncoderBuilder().autoHuffman()), Nat8.toText, Nat8.equal).equal(data);
      },
    );

  },
);

// ── Suite: Multi-step (resumable) streaming decode ──────────────────────────

/// Encode `data` then decode it across multiple `step(maxOutBytes, consume)`
/// calls — exactly as the example canister drives the decoder across timer
/// messages. Returns the reassembled output.
func multiStepDecode(data : [Nat8], maxOutBytes : Nat) : [Nat8] {
  let encoder = Gzip.EncoderBuilder().build();
  encoder.encode(data);
  encoder.finish();
  let compressed = encoder.compressed();

  // One decoder fed the compressed bytes, then driven step-by-step.
  let decoder = Gzip.Decoder();
  switch (decoder.decode(compressed)) {
    case (#err msg) Runtime.trap("multiStepDecode decode error: " # msg);
    case (#ok _) {};
  };
  switch (decoder.start()) {
    case (#err msg) Runtime.trap("multiStepDecode start error: " # msg);
    case (#ok _) {};
  };

  let collected = List.empty<Nat8>();
  let consume = func(out : [Nat8]) { List.addAll(collected, out.vals()) };
  var steps = 0;
  label drive loop {
    switch (decoder.step(maxOutBytes, consume)) {
      case (#err msg) Runtime.trap("multiStepDecode step error: " # msg);
      case (#ok(#more)) { steps += 1 };
      case (#ok(#done summary)) {
        steps += 1;
        if (summary.size != List.size(collected)) {
          Runtime.trap("multiStepDecode: summary.size mismatch");
        };
        break drive;
      };
    };
  };
  // Suspension only fires after the internal 1 MiB output-buffer flush
  // (WINDOW + FLUSH_CHUNK ≈ 1.06 MiB). Inputs below that threshold always
  // complete in one step regardless of maxOutBytes.
  if (data.size() > 1_000_000 and steps < 2) {
    Runtime.trap("multiStepDecode: expected multiple steps, got " # debug_show steps);
  };
  List.toArray(collected);
};

suite(
  "Multi-step streaming decode",
  func() {

    test(
      "1.2 MiB repetitive input decodes byte-correct across multiple steps",
      func() {
        // Highly compressible (all 0xAA) so LZSS encoding is near-free, but
        // decompressed output (~1.2 MiB) crosses the internal 1 MiB flush
        // threshold, forcing the suspension path and at least two steps.
        let n = 1_258_291; // floor(1.2 * 1024 * 1024)
        let data = Array.tabulate<Nat8>(n, func(_) { 0xAA });
        let result = multiStepDecode(data, 512 * 1024);
        expect.nat(result.size()).equal(n);
        expect.nat8(result[0]).equal(0xAA);
        expect.nat8(result[n / 3]).equal(0xAA);
        expect.nat8(result[n / 2]).equal(0xAA);
        expect.nat8(result[n - 1]).equal(0xAA);
      },
    );

  },
);
