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
    getJobStatus: IDL.Func([JobId], [IDL.Opt(JobStatus)], []),
    clearAll: IDL.Func([], [], []),
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
  clearAll: () => Promise<void>;
}

/**
 * Ticks PocketIC until the given job transitions to done or failed.
 * Logs a warning on failure rather than throwing — perf runs tolerate partial data.
 *
 * Prints status every 10 ticks so we can observe whether the loop is progressing
 * or the tick/query itself is the hang point.
 */
async function awaitJob(
  pic: PocketIc,
  actor: PerfService,
  jobId: bigint,
  callName: string,
  maxTicks = 200000,
): Promise<void> {
  for (let i = 0; i < maxTicks; i++) {
    const tickStart = Date.now();
    await pic.tick();
    const tickMs = Date.now() - tickStart;

    const result = await actor.getJobStatus(jobId);

    if (i % 10 === 0 || tickMs > 1000) {
      const statusStr =
        result.length === 0
          ? "not-found"
          : "done" in result[0]
            ? "done"
            : "failed" in result[0]
              ? `failed: ${(result[0] as { failed: string }).failed}`
              : "compressing" in result[0]
                ? `compressing ${(result[0] as { compressing: { index: bigint; total: bigint } }).compressing.index}/${(result[0] as { compressing: { index: bigint; total: bigint } }).compressing.total}`
                : `decompressing ${(result[0] as { decompressing: { index: bigint; total: bigint } }).decompressing.index}/${(result[0] as { decompressing: { index: bigint; total: bigint } }).decompressing.total}`;
      console.error(
        `[perf-debug] ${callName} tick=${i} tick_ms=${tickMs} status=${statusStr}`,
      );
    }

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

  await actor.clearAll();
} finally {
  await pic?.tearDown().catch(() => {});
  await server?.stop().catch(() => {});
}
