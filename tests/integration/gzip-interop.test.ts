/**
 * Gzip interoperability test.
 *
 * Verifies that the motoko-gzip decoder can decompress data
 * produced by node:zlib — proving cross-implementation compatibility.
 *
 * Structured tests: 1 MiB and 10 MiB payloads mirroring compress.mo generateBytes():
 *   - first third:  constant 0xAA   (run-length compressible)
 *   - middle third: random bytes     (incompressible)
 *   - last third:   sequential 0-255 (pattern compressible)
 *
 * Edge cases: empty, single byte, all-identical, stored blocks (level 0),
 *   best compression (level 9), null bytes, all 256 byte values, repeating text.
 */
import { describe, it, beforeAll, afterAll, expect } from "bun:test";
import { PocketIc, PocketIcServer } from "@dfinity/pic";
import { randomBytes } from "node:crypto";
import { promisify } from "node:util";
import { gzip as zlibGzip } from "node:zlib";
import {
  createExternalDecompressCanister,
  type ExternalDecompressService,
} from "./setup.ts";

const gzip = promisify(zlibGzip);

/**
 * Mirrors compress.mo generateBytes(): structured in thirds so the buffer
 * exercises constant, incompressible, and sequential data in one payload.
 */
function generateTestData(sizeBytes: number): Buffer {
  const third = Math.floor(sizeBytes / 3);
  const buf = Buffer.alloc(sizeBytes);
  buf.fill(0xaa, 0, third);
  randomBytes(third).copy(buf, third);
  for (let i = 2 * third; i < sizeBytes; i++) buf[i] = i % 256;
  return buf;
}

/** Max bytes per canister call — kept at 1 MiB to stay well under the 2 MB message limit. */
const UPLOAD_CHUNK = 1024 * 1024;

/**
 * Upload compressed bytes to the canister, decompress, and read back all pages.
 * Calls clear() first so each invocation is fully self-contained.
 */
async function decompressViaCanister(
  actor: ExternalDecompressService,
  compressed: Buffer,
): Promise<Buffer> {
  await actor.clear();
  for (let offset = 0; offset < compressed.length; offset += UPLOAD_CHUNK) {
    const chunk = Array.from(
      compressed.subarray(offset, offset + UPLOAD_CHUNK),
    );
    await actor.appendExternalCompressed(chunk);
  }
  await actor.decompress();
  const pages: Buffer[] = [];
  for (let page = 0n; ; page++) {
    const chunk = await actor.getDecompressedData(page);
    if (chunk.length === 0) break;
    pages.push(Buffer.from(chunk as number[]));
  }
  return Buffer.concat(pages);
}

describe("Gzip Interop", () => {
  let server: PocketIcServer;
  let pic: PocketIc;
  let actor: ExternalDecompressService;

  beforeAll(async () => {
    server = await PocketIcServer.start();
    pic = await PocketIc.create(server.getUrl());
    const fixture = await createExternalDecompressCanister(pic);
    actor = fixture.actor;
  }, 30_000);

  afterAll(async () => {
    await pic.tearDown();
    await server.stop();
  }, 30_000);

  it("decompresses node:zlib gzip output correctly (random, 1 MiB)", async () => {
    const original = generateTestData(1 * 1024 * 1024);
    const compressed = await gzip(original);
    const decompressedBytes = await decompressViaCanister(actor, compressed);

    expect(decompressedBytes.equals(original)).toBe(true);
    console.log(
      `sizes  |  original: ${(original.length / 1024).toFixed(1)} KiB  compressed: ${(compressed.length / 1024).toFixed(1)} KiB  decompressed: ${(decompressedBytes.length / 1024).toFixed(1)} KiB`,
    );
  }, 300_000);

  it("decompresses node:zlib gzip output correctly (random, 10 MiB)", async () => {
    const original = generateTestData(10 * 1024 * 1024);
    const compressed = await gzip(original);
    const decompressedBytes = await decompressViaCanister(actor, compressed);

    expect(decompressedBytes.equals(original)).toBe(true);
    console.log(
      `sizes  |  original: ${(original.length / 1024).toFixed(1)} KiB  compressed: ${(compressed.length / 1024).toFixed(1)} KiB  decompressed: ${(decompressedBytes.length / 1024).toFixed(1)} KiB`,
    );
  }, 600_000);

  describe("edge cases", () => {
    it("handles empty payload (0 bytes)", async () => {
      // gzip of 0 bytes is a valid ~20-byte stream; decoder must return 0 bytes without error.
      const original = Buffer.alloc(0);
      const compressed = await gzip(original);
      const result = await decompressViaCanister(actor, compressed);

      expect(result.equals(original)).toBe(true);
      console.log(
        `empty  |  compressed: ${compressed.length} B  decompressed: ${result.length} B`,
      );
    }, 60_000);

    it("handles single byte payload", async () => {
      // One byte is below the LZSS minimum match length (3 bytes),
      // so deflate emits a pure literal block — no back-references at all.
      const original = Buffer.from([0xab]);
      const compressed = await gzip(original);
      const result = await decompressViaCanister(actor, compressed);

      expect(result.equals(original)).toBe(true);
      console.log(
        `1 byte  |  compressed: ${compressed.length} B  decompressed: ${result.length} B`,
      );
    }, 60_000);

    it("handles all-identical bytes (64 KiB of 0xAA)", async () => {
      // Maximum compressibility: the compressed stream is ~70 bytes.
      // The decoder must expand it back to 64 KiB via long back-reference chains.
      const original = Buffer.alloc(64 * 1024, 0xaa);
      const compressed = await gzip(original);
      const result = await decompressViaCanister(actor, compressed);

      expect(result.equals(original)).toBe(true);
      console.log(
        `all-0xAA 64KiB  |  compressed: ${compressed.length} B  decompressed: ${result.length} B`,
      );
    }, 60_000);

    it("handles stored blocks (zlib level 0, 64 KiB)", async () => {
      // zlib level 0 produces raw stored (uncompressed) deflate blocks —
      // a completely different decoder code path from Huffman-coded blocks.
      const original = generateTestData(64 * 1024);
      const compressed = await gzip(original, { level: 0 });
      const result = await decompressViaCanister(actor, compressed);

      expect(result.equals(original)).toBe(true);
      console.log(
        `stored-blocks 64KiB  |  compressed: ${compressed.length} B  decompressed: ${result.length} B`,
      );
    }, 60_000);

    it("handles best compression (zlib level 9, 64 KiB)", async () => {
      // Level 9 uses deeper back-reference search and may emit different
      // dynamic Huffman tables than the default level 6.
      const original = generateTestData(64 * 1024);
      const compressed = await gzip(original, { level: 9 });
      const result = await decompressViaCanister(actor, compressed);

      expect(result.equals(original)).toBe(true);
      console.log(
        `level-9 64KiB  |  compressed: ${compressed.length} B  decompressed: ${result.length} B`,
      );
    }, 60_000);

    it("handles null bytes (64 KiB of 0x00)", async () => {
      // All-null payload verifies 0x00 is not treated as a string terminator
      // anywhere in the Motoko decoder — Nat8 = 0 must be preserved exactly.
      const original = Buffer.alloc(64 * 1024, 0x00);
      const compressed = await gzip(original);
      const result = await decompressViaCanister(actor, compressed);

      expect(result.equals(original)).toBe(true);
      console.log(
        `null-bytes 64KiB  |  compressed: ${compressed.length} B  decompressed: ${result.length} B`,
      );
    }, 60_000);

    it("handles all 256 byte values in sequence", async () => {
      // Every possible Nat8 value (0x00–0xFF) must survive the round-trip.
      // Repeated 4 times (1024 bytes total) to give LZSS a chance to find matches.
      const cycle = Array.from({ length: 256 }, (_, i) => i);
      const original = Buffer.from([...cycle, ...cycle, ...cycle, ...cycle]);
      const compressed = await gzip(original);
      const result = await decompressViaCanister(actor, compressed);

      expect(result.equals(original)).toBe(true);
      console.log(
        `all-256-values  |  compressed: ${compressed.length} B  decompressed: ${result.length} B`,
      );
    }, 60_000);

    it("handles repeating ASCII text (~60 KiB)", async () => {
      // Simulates a realistic web payload (JSON/HTML): high repetition,
      // variable byte values — exercises typical real-world interop scenario.
      const original = Buffer.from("Hello, ICP! ".repeat(5_000));
      const compressed = await gzip(original);
      const result = await decompressViaCanister(actor, compressed);

      expect(result.equals(original)).toBe(true);
      console.log(
        `ascii-text 60KiB  |  compressed: ${compressed.length} B  decompressed: ${result.length} B`,
      );
    }, 60_000);
  });
});
