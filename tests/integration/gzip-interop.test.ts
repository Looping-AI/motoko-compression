/**
 * Gzip interoperability test.
 *
 * Verifies that the motoko-compression gzip decoder can decompress data
 * produced by node:zlib — proving cross-implementation compatibility.
 *
 * Test data: 1 MiB of cryptographically random bytes.
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

/** Max bytes per canister call — kept at 1 MiB to stay well under the 2 MB message limit. */
const UPLOAD_CHUNK = 1024 * 1024;

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
    const SIZE_MIB = 1;

    // 1. Build SIZE_MIB MiB of cryptographically random bytes.
    const original = randomBytes(SIZE_MIB * 1024 * 1024);

    // 2. Compress with node:zlib.
    const compressed = await gzip(original);

    // 3. Upload compressed bytes to the canister in ≤1 MiB chunks.
    for (let offset = 0; offset < compressed.length; offset += UPLOAD_CHUNK) {
      const chunk = Array.from(
        compressed.subarray(offset, offset + UPLOAD_CHUNK),
      );
      await actor.appendExternalCompressed(chunk);
    }

    // 4. Decompress on the canister.
    await actor.decompress();

    // 5. Read back decompressed bytes (paginated).
    const pages: Buffer[] = [];
    for (let page = 0n; ; page++) {
      const chunk = await actor.getDecompressedData(page);
      if (chunk.length === 0) break;
      pages.push(Buffer.from(chunk as number[]));
    }
    const decompressedBytes = Buffer.concat(pages);

    // Must exactly match the original TypeScript bytes.
    expect(decompressedBytes).toEqual(original);
  }, 300_000);
});
