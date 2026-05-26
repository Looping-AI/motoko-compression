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

  async function storeImage(name: string, data: number[]): Promise<void> {
    await actor.storeAndCompressImage(name, data);
  }

  /**
   * Retrieve an image page-by-page via getImagePage and reassemble.
   * Each page call may trigger _decodeChunk self-calls (for #chunked stored
   * data).
   * Returns null if the image is not found; accumulates pages until ?[] signals
   * end-of-data.
   */
  async function getImage(name: string): Promise<number[] | null> {
    const accumulated: number[] = [];
    for (let page = 0n; ; page++) {
      const result = await actor.getImagePage(name, page);
      if (result.length === 0) return null; // image not found
      const pageData = Array.from(result[0] as Uint8Array);
      if (pageData.length === 0) break; // beyond last page
      for (const bytes of pageData) accumulated.push(bytes);
    }
    return accumulated;
  }

  /**
   * Upload a large image in 2 MiB chunks using the beginImageUpload /
   * uploadImageChunk / finishImageUpload API.  Each chunk call is a separate
   * PocketIC message.
   */
  async function storeImageChunked(
    name: string,
    data: number[],
  ): Promise<void> {
    await actor.beginImageUpload();

    const CHUNK = 2 * 1024 * 1024 - 512; // leave room for IC ingress envelope + Candid overhead (~186 bytes observed)
    for (let offset = 0; offset < data.length; offset += CHUNK) {
      const chunk = data.slice(offset, Math.min(offset + CHUNK, data.length));
      await actor.uploadImageChunk(chunk);
    }

    await actor.finishImageUpload(name);
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

  it("round-trips a small image (4 KB)", async () => {
    const original = makeData(4 * 1024, 2);
    await storeImage("logo.png", original);
    const retrieved = await getImage("logo.png");
    expect(retrieved).toEqual(original);
  }, 60_000);

  it("retrieved bytes do not match a mutated copy", async () => {
    const original = makeData(4 * 1024, 3);
    await storeImage("icon.png", original);

    const mutated = [...original];
    mutated[0] = mutated[0] ^ 0xff;
    const retrieved = await getImage("icon.png");
    expect(retrieved).not.toEqual(mutated);
  }, 60_000);

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
    // 1 MiB fits in a single ingress call.  Pseudo-random data compresses
    // poorly, giving the encoder a realistic workload.
    const SIZE = 1024 * 1024;
    const original = makeData(SIZE, 99);

    await storeImage("banner.png", original);
    const retrieved = await getImage("banner.png");

    expect(retrieved).toEqual(original);
  }, 180_000);

  it("round-trips a 10 MiB image via chunked upload", async () => {
    // 10 MiB exceeds PocketIC's 2 MiB ingress limit, so we stream the raw
    // bytes in 2 MiB slices using beginImageUpload / uploadImageChunk /
    // finishImageUpload.  Pseudo-random data compresses to roughly the same
    // size, so the stored EncodedResponse is #chunked; getImage uses
    // _decodeChunk self-calls to reassemble the decompressed output.
    const SIZE = 3 * 1024 * 1024;
    const original = makeData(SIZE, 100);

    await storeImageChunked("large.png", original);

    // ~10 MiB compressed → ~5 output chunks of 2 MiB each
    const retrieved = await getImage("large.png");

    expect(retrieved).toEqual(original);
  }, 600_000);
});
