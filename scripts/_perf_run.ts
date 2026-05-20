#!/usr/bin/env bun
/**
 * Inner workload helper — called by scripts/perf.ts.
 *
 * Usage (internal):
 *   bun scripts/_perf_run.ts <component> <wasm-file-path>
 *
 * Starts a PocketIC instance, installs the perf-instrumented canister,
 * runs generate_data(1) → compress_data(), then shuts down.
 *
 * Canister Debug.print output (including [perf] marks emitted by Perf.mark())
 * is forwarded by PocketIC through the process streams. The parent captures
 * both stdout and stderr to extract the marks.
 */

import { PocketIc, PocketIcServer } from "@dfinity/pic";
import { readFileSync } from "node:fs";

const [component, wasmFile, payloadBytesArg] = process.argv.slice(2);

if (!component || !wasmFile) {
  console.error(
    "Usage: _perf_run.ts <component> <wasm-file-path> [payload-bytes]",
  );
  process.exit(1);
}

// Workload size in bytes. Defaults to 1 MiB; perf.ts overrides this per
// component (e.g. low-level primitives need a much smaller payload to keep
// the per-call mark volume tractable).
const payloadBytes = payloadBytesArg
  ? BigInt(payloadBytesArg)
  : BigInt(1024 * 1024);

// Minimal IDL — only the methods needed for the workload.
const idlFactory = ({ IDL }: { IDL: any }) =>
  IDL.Service({
    generateData: IDL.Func([IDL.Nat], [], []),
    generateBytes: IDL.Func([IDL.Nat], [], []),
    compressData: IDL.Func([], [], []),
    decompressData: IDL.Func([], [], []),
  });

interface PerfService {
  generateData: (size_mb: bigint) => Promise<void>;
  generateBytes: (n_bytes: bigint) => Promise<void>;
  compressData: () => Promise<void>;
  decompressData: () => Promise<void>;
}

let server: PocketIcServer | undefined;
let pic: PocketIc | undefined;

try {
  server = await PocketIcServer.start({ showCanisterLogs: true });
  pic = await PocketIc.create(server.getUrl());

  const wasm = new Uint8Array(readFileSync(wasmFile));
  const fixture = await pic.setupCanister<PerfService>({ idlFactory, wasm });
  const actor = fixture.actor;

  await actor.generateBytes(payloadBytes);

  // compress_data() / decompress_data() use inter-canister self-calls.
  // PocketIC sometimes exhausts its reply-polling window before the outer
  // call officially settles, even though all Perf.mark() calls have fired.
  const toleratePollingTimeout = async (fn: () => Promise<void>) => {
    try {
      await fn();
    } catch (err) {
      const isPollingTimeout =
        err instanceof Error && err.constructor.name === "RetryableError";
      if (!isPollingTimeout) throw err;
    }
  };

  await toleratePollingTimeout(() => actor.compressData());
  await toleratePollingTimeout(() => actor.decompressData());
} finally {
  await pic?.tearDown().catch(() => {});
  await server?.stop().catch(() => {});
}
