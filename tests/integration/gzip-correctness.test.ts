/**
 * Gzip correctness test.
 *
 * Verifies that the motoko-compression gzip implementation round-trips data
 * correctly: generate_data → compress_data → decompress_data must reproduce
 * the original bytes exactly.
 *
 * Additionally asserts that the compressed output size is within ±20% of
 * node:zlib's output, catching regressions in compression ratio.
 */
import { describe, it, beforeAll, afterAll, expect } from "bun:test";
import { PocketIc, PocketIcServer } from "@dfinity/pic";
import { promisify } from "util";
import { gzip as zlibGzip } from "zlib";
import { createCompressionCanister, type CompressionService } from "./setup.ts";

const gzip = promisify(zlibGzip);

/** Concatenate all pages returned by a paginated query until an empty page. */
async function readAllPages(
  fetch: (page: bigint) => Promise<Uint8Array | number[]>,
): Promise<Buffer> {
  const chunks: Buffer[] = [];
  for (let page = 0n; ; page++) {
    const chunk = await fetch(page);
    if (chunk.length === 0) break;
    chunks.push(Buffer.from(chunk as number[]));
  }
  return Buffer.concat(chunks);
}

describe("Gzip Correctness", () => {
  let server: PocketIcServer;
  let pic: PocketIc;
  let actor: CompressionService;

  beforeAll(async () => {
    server = await PocketIcServer.start();
    pic = await PocketIc.create(server.getUrl());
    const fixture = await createCompressionCanister(pic);
    actor = fixture.actor;
  }, 30_000);

  afterAll(async () => {
    await pic.tearDown();
    await server.stop();
  });

  it("round-trips 1 MiB through gzip and compressed size is within ±20% of node:zlib", async () => {
    // 1. Generate 1 MiB of pseudo-random data (seeded, deterministic).
    await actor.generateData(1n);

    // 2. Compress.
    await actor.compressData();

    // 3. Collect compressed bytes.
    const compressedBytes = await readAllPages((p) =>
      actor.getCompressedData(p),
    );

    // 4. Decompress.
    await actor.decompressData();

    // 5. Collect decompressed and original bytes.
    const [decompressedBytes, originalBytes] = await Promise.all([
      readAllPages((p) => actor.getDecompressedData(p)),
      readAllPages((p) => actor.getGeneratedData(p)),
    ]);

    // Round-trip correctness: decompressed must exactly equal original.
    expect(decompressedBytes).toEqual(originalBytes);

    // Compression ratio must be within ±20% of node:zlib output.
    const zlibBytes = await gzip(originalBytes);
    const ratio = compressedBytes.length / zlibBytes.length;
    expect(ratio).toBeGreaterThan(0.8);
    expect(ratio).toBeLessThan(1.2);
  }, 120_000);
});
