/**
 * Gzip correctness test.
 *
 * Verifies that the motoko-compression gzip implementation round-trips data
 * correctly: generateBytes → requestCompressJob → requestDecompressJob must
 * reproduce the original bytes exactly.
 *
 * Additionally asserts that the compressed output size is within ±20% of
 * node:zlib's output, catching regressions in compression ratio.
 *
 * The round-trip is performed twice on the same canister instance to verify
 * that the encoder and decoder state is properly reset between runs.
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

/**
 * Ticks PocketIC until the given job transitions to #done.
 * Throws if the job is not found or fails.
 */
async function awaitJob(
  pic: PocketIc,
  actor: CompressionService,
  jobId: bigint,
  maxTicks = 2000,
): Promise<void> {
  for (let i = 0; i < maxTicks; i++) {
    await pic.tick();
    const result = await actor.getJobStatus(jobId);
    if (result.length === 0) throw new Error(`Job ${jobId} not found`);
    const status = result[0];
    if ("done" in status) return;
    if ("failed" in status)
      throw new Error(`Job ${jobId} failed: ${status.failed}`);
  }
  throw new Error(
    `Job ${jobId} did not complete after ${maxTicks} ticks — possible canister trap`,
  );
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

  /**
   * Runs the full generate → compress → decompress round-trip.
   * Returns the original, compressed, and decompressed byte buffers.
   */
  async function roundTrip(sizeMib: bigint) {
    // 1. Generate sizeMib MiB of pseudo-random data (seeded, deterministic).
    await actor.generateBytes(sizeMib * 1024n * 1024n);

    // 2. Submit compress job and tick until complete.
    const compressId = await actor.requestCompressJob();
    await awaitJob(pic, actor, compressId);

    // 3. Collect compressed bytes.
    const compressedBytes = await readAllPages((p) =>
      actor.getCompressedData(p),
    );

    // 4. Submit decompress job and tick until complete.
    const decompressId = await actor.requestDecompressJob();
    await awaitJob(pic, actor, decompressId);

    // 5. Collect decompressed and original bytes.
    const [decompressedBytes, originalBytes] = await Promise.all([
      readAllPages((p) => actor.getDecompressedData(p)),
      readAllPages((p) => actor.getGeneratedData(p)),
    ]);

    return { originalBytes, compressedBytes, decompressedBytes };
  }

  it("round-trips 1 MiB through gzip and compressed size is within ±10% of node:zlib", async () => {
    const SIZE_MIB = 1n;
    const { originalBytes, compressedBytes, decompressedBytes } =
      await roundTrip(SIZE_MIB);

    // Round-trip correctness: decompressed must exactly equal original.
    expect(decompressedBytes).toEqual(originalBytes);

    // Compression ratio must be within ±10% of node:zlib output.
    const zlibBytes = await gzip(originalBytes);
    const ratio = compressedBytes.length / zlibBytes.length;
    console.log(
      `sizes  |  original: ${(originalBytes.length / 1024).toFixed(1)} KiB  motoko: ${(compressedBytes.length / 1024).toFixed(1)} KiB  zlib: ${(zlibBytes.length / 1024).toFixed(1)} KiB  ratio: ${ratio.toFixed(2)}x`,
    );
    expect(ratio).toBeGreaterThan(0.9);
    expect(ratio).toBeLessThan(1.1);
  }, 10_000);

  it("round-trips correctly on a second run (encoder/decoder state reset)", async () => {
    const SIZE_MIB = 1n;
    const { originalBytes, compressedBytes, decompressedBytes } =
      await roundTrip(SIZE_MIB);

    // Round-trip correctness: decompressed must exactly equal original.
    expect(decompressedBytes).toEqual(originalBytes);

    // Compression ratio must still be within ±10% of node:zlib output.
    const zlibBytes = await gzip(originalBytes);
    const ratio = compressedBytes.length / zlibBytes.length;
    console.log(
      `sizes  |  original: ${(originalBytes.length / 1024).toFixed(1)} KiB  motoko: ${(compressedBytes.length / 1024).toFixed(1)} KiB  zlib: ${(zlibBytes.length / 1024).toFixed(1)} KiB  ratio: ${ratio.toFixed(2)}x`,
    );
    expect(ratio).toBeGreaterThan(0.9);
    expect(ratio).toBeLessThan(1.1);
  }, 10_000);

  it("round-trips 10 MiB through gzip and compressed size is within ±10% of node:zlib", async () => {
    const SIZE_MIB = 10n;
    const { originalBytes, compressedBytes, decompressedBytes } =
      await roundTrip(SIZE_MIB);

    // Round-trip correctness: decompressed must exactly equal original.
    expect(decompressedBytes).toEqual(originalBytes);

    // Compression ratio must be within ±10% of node:zlib output.
    const zlibBytes = await gzip(originalBytes);
    const ratio = compressedBytes.length / zlibBytes.length;
    console.log(
      `sizes  |  original: ${(originalBytes.length / 1024).toFixed(1)} KiB  motoko: ${(compressedBytes.length / 1024).toFixed(1)} KiB  zlib: ${(zlibBytes.length / 1024).toFixed(1)} KiB  ratio: ${ratio.toFixed(2)}x`,
    );
    expect(ratio).toBeGreaterThan(0.9);
    expect(ratio).toBeLessThan(1.1);
  }, 120_000);
});
