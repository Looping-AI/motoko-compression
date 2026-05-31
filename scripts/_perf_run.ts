#!/usr/bin/env bun
/**
 * Inner workload helper — called by scripts/perf.ts.
 *
 * Usage (internal):
 *   bun scripts/_perf_run.ts <component> <wasm-file-path>
 *
 * Starts a PocketIC instance, installs the perf-instrumented canister,
 * runs generateBytes(1) → requestCompressJob() → requestDecompressJob(),
 * ticking PocketIC after each job submission until the job completes.
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
const idlFactory = ({ IDL }: { IDL: any }) => {
  const JobId = IDL.Nat;
  const JobStatus = IDL.Variant({
    done: IDL.Null,
    compressing: IDL.Record({ total: IDL.Nat, index: IDL.Nat }),
    decompressing: IDL.Record({ total: IDL.Nat, index: IDL.Nat }),
    failed: IDL.Text,
  });
  return IDL.Service({
    generateBytes: IDL.Func([IDL.Nat], [], []),
    requestCompressJob: IDL.Func([], [JobId], []),
    requestDecompressJob: IDL.Func([], [JobId], []),
    getJobStatus: IDL.Func([JobId], [IDL.Opt(JobStatus)], ["query"]),
  });
};

type JobStatusVariant =
  | { done: null }
  | { compressing: { total: bigint; index: bigint } }
  | { decompressing: { total: bigint; index: bigint } }
  | { failed: string };

interface PerfService {
  generateBytes: (n_bytes: bigint) => Promise<void>;
  requestCompressJob: () => Promise<bigint>;
  requestDecompressJob: () => Promise<bigint>;
  getJobStatus: (id: bigint) => Promise<Array<JobStatusVariant>>;
}

/**
 * Ticks PocketIC until the given job transitions to done or failed.
 * Logs a warning on failure rather than throwing — perf runs tolerate partial data.
 */
async function awaitJob(
  pic: PocketIc,
  actor: PerfService,
  jobId: bigint,
  callName: string,
  maxTicks = 200000,
): Promise<void> {
  for (let i = 0; i < maxTicks; i++) {
    await pic.tick();
    const result = await actor.getJobStatus(jobId);
    if (result.length === 0) {
      console.error(`[perf-warn] ${callName}: job ${jobId} not found`);
      return;
    }
    const status = result[0];
    if ("done" in status) return;
    if ("failed" in status) {
      console.error(
        `[perf-warn] ${callName}: job ${jobId} failed: ${status.failed}`,
      );
      return;
    }
  }
  console.error(
    `[perf-warn] ${callName}: job ${jobId} did not complete after ${maxTicks} ticks — possible canister trap`,
  );
}

let server: PocketIcServer | undefined;
let pic: PocketIc | undefined;

try {
  server = await PocketIcServer.start({ showCanisterLogs: true });
  pic = await PocketIc.create(server.getUrl(), {
    processingTimeoutMs: 600_000,
  });

  const wasm = new Uint8Array(readFileSync(wasmFile));
  const fixture = await pic.setupCanister<PerfService>({ idlFactory, wasm });
  const actor = fixture.actor;

  await actor.generateBytes(payloadBytes);

  const compressId = await actor.requestCompressJob();
  await awaitJob(pic, actor, compressId, "requestCompressJob");

  const decompressId = await actor.requestDecompressJob();
  await awaitJob(pic, actor, decompressId, "requestDecompressJob");
} finally {
  await pic?.tearDown().catch(() => {});
  await server?.stop().catch(() => {});
}
