/**
 * Gzip timing test.
 *
 * Compares wall-clock time of the motoko-gzip canister gzip
 * implementation against node:zlib. A dynamic baseline discount is measured
 * at startup by calling the canister's no-op `ping()` method several times,
 * then averaged to capture the true per-message round-trip overhead for this
 * machine/environment — replacing the former hard-coded 1-second constant.
 *
 * Uses the direct compress() / decompress() single-message methods so that
 * timer scheduling and polling overhead do not inflate the measured ratio.
 *
 * Assertions:
 *   - canister compress() must be within MAX_RATIO of node:zlib (after discount)
 *   - canister decompress() must be within MAX_RATIO of node:zlib (after discount)
 */
import { describe, it, beforeAll, afterAll, expect } from "bun:test";
import { PocketIc, PocketIcServer } from "@dfinity/pic";
import { promisify } from "util";
import { gzip as zlibGzip, gunzip as zlibGunzip } from "zlib";
import { createCompressionCanister, type CompressionService } from "./setup.ts";

const gzip = promisify(zlibGzip);
const gunzip = promisify(zlibGunzip);

/** Number of ping() calls used to estimate the per-message round-trip baseline. */
const PING_SAMPLES = 3;

/** Actor must be at most 200x slower than zlib (after the ping discount). */
/** It depends on the SIZE_MIB, if 0.01 MiB -> 100x, if 1 MiB -> 400x */
const MAX_RATIO = 200;

const SIZE_MIB = 0.1;

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
  let pingBaselineMs: number;

  beforeAll(async () => {
    server = await PocketIcServer.start();
    pic = await PocketIc.create(server.getUrl());
    const fixture = await createCompressionCanister(pic);
    actor = fixture.actor;

    // Measure per-message round-trip overhead by timing PING_SAMPLES no-op
    // update calls. The average becomes the discount applied to actor timings,
    // giving a machine-independent baseline instead of a hard-coded constant.
    const samples: number[] = [];
    for (let i = 0; i < PING_SAMPLES; i++) {
      const t0 = performance.now();
      await actor.ping();
      samples.push(performance.now() - t0);
    }
    pingBaselineMs = samples.reduce((a, b) => a + b, 0) / samples.length;
    console.log(
      `ping baseline  |  samples: [${samples.map((s) => s.toFixed(0)).join(", ")}] ms  avg: ${pingBaselineMs.toFixed(0)} ms`,
    );

    // Generate data once — shared across both timing tests.
    await actor.generateBytes(BigInt(Math.floor(SIZE_MIB * 1024 * 1024)));
  }, 30_000);

  afterAll(async () => {
    await pic.tearDown();
    await server.stop();
  });

  it("canister compress() is within MAX_RATIO of node:zlib gzip (after ping discount)", async () => {
    // Collect original bytes for the zlib comparison.
    const originalBytes = await readAllPages((p) => actor.getGeneratedData(p));

    // ── canister compress ─────────────────────────────────────────────────
    const actorStart = performance.now();
    await actor.compress();
    const actorMs = performance.now() - actorStart;

    // ── node:zlib compress ────────────────────────────────────────────────
    const zlibStart = performance.now();
    await gzip(originalBytes);
    const zlibMs = performance.now() - zlibStart;

    const adjustedActorMs = Math.max(0, actorMs - pingBaselineMs);
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

  it("canister decompress() is within MAX_RATIO of node:zlib gunzip (after ping discount)", async () => {
    // Compressed bytes were produced by the previous test.
    const compressedBytes = await readAllPages((p) =>
      actor.getCompressedData(p),
    );

    // ── canister decompress ───────────────────────────────────────────────
    const actorStart = performance.now();
    await actor.decompress();
    const actorMs = performance.now() - actorStart;

    // ── node:zlib decompress ──────────────────────────────────────────────
    const zlibStart = performance.now();
    await gunzip(compressedBytes);
    const zlibMs = performance.now() - zlibStart;

    const adjustedActorMs = Math.max(0, actorMs - pingBaselineMs);
    const ratio = adjustedActorMs / zlibMs;

    console.log(
      `decompress  |  actor: ${actorMs.toFixed(0)} ms  adjusted: ${adjustedActorMs.toFixed(0)} ms  zlib: ${zlibMs.toFixed(0)} ms  ratio: ${ratio.toFixed(2)}x`,
    );

    expect(ratio).toBeLessThanOrEqual(MAX_RATIO);
  }, 120_000);
});
