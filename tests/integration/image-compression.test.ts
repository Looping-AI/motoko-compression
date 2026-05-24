/**
 * ImageStore canister integration test.
 *
 * Deploys the compress-images example canister (ImageStore actor class) and
 * exercises its full public API:
 *
 *   - compressImage / storeImage / getImage — correct round-trip for small and large images
 *   - isExactImage           — true for the stored bytes, false for mutations
 *   - Named isolation        — images stored under different names don't interfere
 *   - Overwrite              — a second storeImage under the same name replaces
 *   - Unknown name           — getImage returns null for an unseen name
 *   - Near-limit image      — 1 MiB of pseudo-random bytes (largest practical
 *                              size within PocketIC's 2 MiB ingress limit)
 *
 * Self-call handling
 * ──────────────────
 * compressImage always makes at least one self-call (_compressChunk) even for
 * tiny images, because it splits input into 2 MiB chunks unconditionally.
 * storeImage is now a simple map insert with no self-calls.
 * getImage makes self-calls (_decodeChunk) only when compressed output is
 * #chunked (> 2 MiB); for smaller images it decodes in-place.
 * isExactImage calls getImage via an inter-canister self-call regardless of
 * image size.
 *
 * For any operation that involves self-calls, dispatch the promise first then
 * tick PocketIC until the chain completes before awaiting the result.
 */
import { describe, it, beforeAll, afterAll, expect } from "bun:test";
import { PocketIc, PocketIcServer } from "@dfinity/pic";
import {
  createImageCompressionCanister,
  type ImageCompressionService,
} from "./setup.ts";

// ── Helpers ──────────────────────────────────────────────────────────────────

/**
 * Deterministic pseudo-random byte sequence (LCG, seeded).
 * Different seeds produce completely different byte patterns, which lets tests
 * verify that two images stored under different names don't bleed into each other.
 */
function makeData(size: number, seed = 0): number[] {
  const data: number[] = [];
  let x = ((seed | 1) + 0x9e3779b9) >>> 0;
  for (let i = 0; i < size; i++) {
    x = (Math.imul(x, 1664525) + 1013904223) >>> 0;
    data.push((x >>> 24) & 0xff);
  }
  return data;
}

// ── Suite ─────────────────────────────────────────────────────────────────────

describe("ImageStore canister", () => {
  let server: PocketIcServer;
  let pic: PocketIc;
  let actor: ImageCompressionService;

  beforeAll(async () => {
    server = await PocketIcServer.start();
    pic = await PocketIc.create(server.getUrl());
    const fixture = await createImageCompressionCanister(pic);
    actor = fixture.actor;
  }, 30_000);

  afterAll(async () => {
    await pic.tearDown();
    await server.stop();
  });

  /**
   * Compress then store an image.  compressImage drives self-calls; storeImage
   * is a plain map insert.  Tick PocketIC enough rounds for the _compressChunk
   * chain to complete — one extra tick per MiB of input, minimum 3.
   */
  async function storeImage(name: string, data: number[]): Promise<void> {
    const compressPromise = actor.compressImage(data);
    const mib = Math.max(1, Math.ceil(data.length / (2 * 1024 * 1024)));
    for (let i = 0; i < mib + 2; i++) {
      await pic.advanceTime(10_000);
      await pic.tick();
    }
    const compressed = await compressPromise;
    await actor.storeImage(name, compressed);
  }

  /**
   * Dispatch getImage and advance PocketIC.
   * For small images, compressed output is #single so decodeImage runs in one
   * message.  getImage is still an async call, so we need at least 1 tick.
   * For large images (compressedMib > 0), decodeImage uses self-calls.
   */
  async function getImage(
    name: string,
    compressedMib = 0,
  ): Promise<number[] | null> {
    const promise = actor.getImage(name);
    for (let i = 0; i < compressedMib + 2; i++) {
      await pic.advanceTime(10_000);
      await pic.tick();
    }
    const result = await promise;
    // Candid Option<Vec nat8> arrives as [] (null) or [Uint8Array] (some).
    // Normalize to number[] so callers can compare against makeData() output.
    return result.length === 0 ? null : Array.from(result[0] as Uint8Array);
  }

  /**
   * Dispatch isExactImage and advance PocketIC.
   * isExactImage calls getImage via an inter-canister self-call, so we need
   * enough ticks for the full chain: caller → isExactImage → getImage → decode.
   */
  async function isExactImage(
    name: string,
    data: number[],
    compressedMib = 0,
  ): Promise<boolean> {
    const promise = actor.isExactImage(name, data);
    for (let i = 0; i < compressedMib + 3; i++) {
      await pic.advanceTime(10_000);
      await pic.tick();
    }
    return await promise;
  }

  // ── Tests ──────────────────────────────────────────────────────────────────

  it("getImage returns null for an unknown name", async () => {
    const result = await getImage("does-not-exist.png");
    expect(result).toBeNull();
  }, 30_000);

  it("round-trips a small image (10 KB)", async () => {
    const original = makeData(10 * 1024, 1);
    await storeImage("small.png", original);
    const retrieved = await getImage("small.png");
    expect(retrieved).toEqual(original);
  }, 60_000);

  it("isExactImage returns true for the stored bytes", async () => {
    const original = makeData(4 * 1024, 2);
    await storeImage("logo.png", original);
    const matches = await isExactImage("logo.png", original);
    expect(matches).toBe(true);
  }, 60_000);

  it("isExactImage returns false when one byte differs", async () => {
    const original = makeData(4 * 1024, 3);
    await storeImage("icon.png", original);

    const mutated = [...original];
    mutated[0] = mutated[0] ^ 0xff;
    const matches = await isExactImage("icon.png", mutated);
    expect(matches).toBe(false);
  }, 60_000);

  it("isExactImage returns false for an unknown name", async () => {
    const data = makeData(256, 4);
    const matches = await isExactImage("ghost.png", data);
    expect(matches).toBe(false);
  }, 30_000);

  it("images stored under different names do not interfere", async () => {
    const imageA = makeData(8 * 1024, 10);
    const imageB = makeData(8 * 1024, 20); // different seed → different bytes

    await storeImage("cat.png", imageA);
    await storeImage("dog.png", imageB);

    const retrievedA = await getImage("cat.png");
    const retrievedB = await getImage("dog.png");

    expect(retrievedA).toEqual(imageA);
    expect(retrievedB).toEqual(imageB);
  }, 120_000);

  it("overwriting a name replaces the stored image", async () => {
    const first = makeData(2 * 1024, 30);
    const second = makeData(3 * 1024, 31); // different size and content

    await storeImage("overwrite.png", first);
    await storeImage("overwrite.png", second);

    const retrieved = await getImage("overwrite.png");
    expect(retrieved).toEqual(second);
    expect(retrieved).not.toEqual(first);
  }, 120_000);

  it("round-trips a near-limit image (1 MiB of pseudo-random bytes)", async () => {
    // PocketIC's ingress limit is 2 MiB, so 1 MiB is the largest practical size
    // for a single-call upload.  Pseudo-random data compresses poorly, giving the
    // encoder a realistic workload.  Multi-chunk compression (input > 2 MiB) and
    // multi-chunk decoding (#chunked compressed output > 2 MiB) cannot be
    // triggered from TypeScript because storeImage accepts all bytes in one call;
    // those paths are covered by the Gzip round-trip unit tests and the
    // compress.mo integration tests (which generate data internally).
    const SIZE = 1024 * 1024;
    const original = makeData(SIZE, 99);

    await storeImage("banner.png", original);
    const retrieved = await getImage("banner.png");

    expect(retrieved).toEqual(original);
  }, 180_000);
});
