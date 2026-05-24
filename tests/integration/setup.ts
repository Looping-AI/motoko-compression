/**
 * Shared PocketIC helpers for integration tests.
 *
 * IDL types and factories are imported from the generated builds/ directory.
 * Run `bun run test:build` before running tests.
 */
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import type { PocketIc } from "@dfinity/pic";
import type { _SERVICE as CompressionService } from "./builds/compression.did.d.ts";
import { idlFactory as compressionIdlFactory } from "./builds/compression.did.js";
import type { _SERVICE as ExternalDecompressService } from "./builds/external-decompress.did.d.ts";
import { idlFactory as externalDecompressIdlFactory } from "./builds/external-decompress.did.js";
import type { _SERVICE as ImageCompressionService } from "./builds/image-compression.did.d.ts";
import { idlFactory as imageCompressionIdlFactory } from "./builds/image-compression.did.js";

export type {
  CompressionService,
  ExternalDecompressService,
  ImageCompressionService,
};

const BUILDS = resolve(import.meta.dir, "builds");

// ── WASM cache — loaded once, reused across all tests ────────────────────────

let _compressionWasm: Uint8Array | undefined;
let _externalDecompressWasm: Uint8Array | undefined;
let _imageCompressionWasm: Uint8Array | undefined;

function getCompressionWasm(): Uint8Array {
  if (!_compressionWasm)
    _compressionWasm = new Uint8Array(
      readFileSync(resolve(BUILDS, "compression.wasm")),
    );
  return _compressionWasm;
}

function getExternalDecompressWasm(): Uint8Array {
  if (!_externalDecompressWasm)
    _externalDecompressWasm = new Uint8Array(
      readFileSync(resolve(BUILDS, "external-decompress.wasm")),
    );
  return _externalDecompressWasm;
}

function getImageCompressionWasm(): Uint8Array {
  if (!_imageCompressionWasm)
    _imageCompressionWasm = new Uint8Array(
      readFileSync(resolve(BUILDS, "image-compression.wasm")),
    );
  return _imageCompressionWasm;
}

// ── Canister factory helpers ──────────────────────────────────────────────────

export async function createCompressionCanister(pic: PocketIc) {
  const fixture = await pic.setupCanister<CompressionService>({
    idlFactory: compressionIdlFactory,
    wasm: getCompressionWasm(),
  });
  return { actor: fixture.actor, canisterId: fixture.canisterId };
}

export async function createExternalDecompressCanister(pic: PocketIc) {
  const fixture = await pic.setupCanister<ExternalDecompressService>({
    idlFactory: externalDecompressIdlFactory,
    wasm: getExternalDecompressWasm(),
  });
  return { actor: fixture.actor, canisterId: fixture.canisterId };
}

export async function createImageCompressionCanister(pic: PocketIc) {
  const fixture = await pic.setupCanister<ImageCompressionService>({
    idlFactory: imageCompressionIdlFactory,
    wasm: getImageCompressionWasm(),
  });
  return { actor: fixture.actor, canisterId: fixture.canisterId };
}
