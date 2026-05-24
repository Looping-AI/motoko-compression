/**
 * Gzip timing test.
 *
 * Compares wall-clock time of the motoko-compression canister gzip
 * implementation against node:zlib. A 1-second discount is applied to the
 * actor time to account for consensus / transport overhead that is absent
 * when running locally with PocketIC.
 *
 * Assertions:
 *   - canister compressData()   must be ≤ 50% slower than zlib (after discount)
 *   - canister decompressData() must be ≤ 50% slower than zlib (after discount)
 */
import { describe, it, beforeAll, afterAll, expect } from "bun:test";
import { PocketIc, PocketIcServer } from "@dfinity/pic";
import { promisify } from "util";
import { gzip as zlibGzip, gunzip as zlibGunzip } from "zlib";
import { createCompressionCanister, type CompressionService } from "./setup.ts";

const gzip = promisify(zlibGzip);
const gunzip = promisify(zlibGunzip);

/** 1-second discount applied to actor time to account for consensus/transport overhead. */
const ACTOR_DISCOUNT_MS = 1_000;

/** Actor must be at most 50% slower than zlib (after the discount). */
const MAX_RATIO = 1.5;

const SIZE_MIB = 1n;

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

describe("Gzip Timing", () => {
  let server: PocketIcServer;
  let pic: PocketIc;
  let actor: CompressionService;

  beforeAll(async () => {
    server = await PocketIcServer.start();
    pic = await PocketIc.create(server.getUrl());
    const fixture = await createCompressionCanister(pic);
    actor = fixture.actor;

    // Generate data once — shared across both timing tests.
    await actor.generateBytes(SIZE_MIB * 1024n * 1024n);
  }, 30_000);

  afterAll(async () => {
    await pic.tearDown();
    await server.stop();
  });

  it("canister compressData() is within 50% of node:zlib gzip (after 1s discount)", async () => {
    // Collect original bytes for the zlib comparison.
    const originalBytes = await readAllPages((p) => actor.getGeneratedData(p));

    // ── canister compress ─────────────────────────────────────────────────
    const actorStart = performance.now();
    await actor.compressData();
    const actorMs = performance.now() - actorStart;

    // ── node:zlib compress ────────────────────────────────────────────────
    const zlibStart = performance.now();
    await gzip(originalBytes);
    const zlibMs = performance.now() - zlibStart;

    const adjustedActorMs = Math.max(0, actorMs - ACTOR_DISCOUNT_MS);
    const ratio = adjustedActorMs / zlibMs;

    console.log(
      `compress  |  actor: ${actorMs.toFixed(0)} ms  adjusted: ${adjustedActorMs.toFixed(0)} ms  zlib: ${zlibMs.toFixed(0)} ms  ratio: ${ratio.toFixed(2)}x`,
    );

    const compressedBytes = await readAllPages((p) =>
      actor.getCompressedData(p),
    );
    expect(compressedBytes.length).toBeGreaterThan(0);

    expect(ratio).toBeLessThanOrEqual(MAX_RATIO);
  }, 120_000);

  it("canister decompressData() is within 50% of node:zlib gunzip (after 1s discount)", async () => {
    // Compressed bytes were produced by the previous test.
    const compressedBytes = await readAllPages((p) =>
      actor.getCompressedData(p),
    );

    // ── canister decompress ───────────────────────────────────────────────
    const actorStart = performance.now();
    await actor.decompressData();
    const actorMs = performance.now() - actorStart;

    // ── node:zlib decompress ──────────────────────────────────────────────
    const zlibStart = performance.now();
    await gunzip(compressedBytes);
    const zlibMs = performance.now() - zlibStart;

    const adjustedActorMs = Math.max(0, actorMs - ACTOR_DISCOUNT_MS);
    const ratio = adjustedActorMs / zlibMs;

    console.log(
      `decompress  |  actor: ${actorMs.toFixed(0)} ms  adjusted: ${adjustedActorMs.toFixed(0)} ms  zlib: ${zlibMs.toFixed(0)} ms  ratio: ${ratio.toFixed(2)}x`,
    );

    expect(ratio).toBeLessThanOrEqual(MAX_RATIO);
  }, 120_000);
});
