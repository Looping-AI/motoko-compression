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

const [component, wasmFile] = process.argv.slice(2);

if (!component || !wasmFile) {
  console.error("Usage: _perf_run.ts <component> <wasm-file-path>");
  process.exit(1);
}

// Minimal IDL — only the two methods needed for the workload.
const idlFactory = ({ IDL }: { IDL: any }) =>
  IDL.Service({
    generate_data: IDL.Func([IDL.Nat], [], []),
    compress_data: IDL.Func([], [], []),
  });

interface PerfService {
  generate_data: (size_mb: bigint) => Promise<void>;
  compress_data: () => Promise<void>;
}

let server: PocketIcServer | undefined;
let pic: PocketIc | undefined;

try {
  server = await PocketIcServer.start({ showCanisterLogs: true });
  pic = await PocketIc.create(server.getUrl());

  const wasm = new Uint8Array(readFileSync(wasmFile));
  const fixture = await pic.setupCanister<PerfService>({ idlFactory, wasm });
  const actor = fixture.actor;

  await actor.generate_data(1n);

  // compress_data() uses inter-canister self-calls.  PocketIC sometimes
  // exhausts its reply-polling window before the outer call officially
  // settles, even though all Perf.mark() calls have already fired.
  try {
    await actor.compress_data();
  } catch (err) {
    const isPollingTimeout =
      err instanceof Error && err.constructor.name === "RetryableError";
    if (!isPollingTimeout) throw err;
  }
} finally {
  await pic?.tearDown().catch(() => {});
  await server?.stop().catch(() => {});
}
