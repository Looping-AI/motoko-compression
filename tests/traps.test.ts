/**
 * Trap behaviour tests — replaces Traps.Test.mo (which required dfx).
 *
 * A single TrapCanister is installed once via PocketIC and reused across all
 * suites. When a Motoko function traps, PocketIC surfaces it as a rejected
 * promise, so each case just asserts that the call rejects.
 *
 * Run `bun run test:build` once to generate trap-canister.wasm before running.
 */
import { describe, it, beforeAll, afterAll, expect } from "bun:test";
import { PocketIc, PocketIcServer } from "@dfinity/pic";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import type { _SERVICE as TrapService } from "./integration/builds/trap-canister.did.d.ts";
import { idlFactory as trapIdlFactory } from "./integration/builds/trap-canister.did.js";

const BUILDS = resolve(import.meta.dir, "integration", "builds");

function getTrapCanisterWasm(): Uint8Array {
  return new Uint8Array(readFileSync(resolve(BUILDS, "trap-canister.wasm")));
}

describe("Trap Behaviour", () => {
  let server: PocketIcServer;
  let pic: PocketIc;
  let actor: TrapService;

  beforeAll(async () => {
    server = await PocketIcServer.start();
    pic = await PocketIc.create(server.getUrl());
    const fixture = await pic.setupCanister<TrapService>({
      idlFactory: trapIdlFactory,
      wasm: getTrapCanisterWasm(),
    });
    actor = fixture.actor;
  }, 30_000);

  afterAll(async () => {
    await pic.tearDown();
    await server.stop();
  });

  describe("BitReader traps — bounds checking", () => {
    it("peekBit traps on empty reader", async () => {
      await expect(actor.peekBitOnEmpty()).rejects.toThrow();
    });

    it("readBits(9) traps when only 8 bits available", async () => {
      await expect(actor.readBitsOverflow()).rejects.toThrow();
    });

    it("peekByte traps on empty reader", async () => {
      await expect(actor.peekByteOnEmpty()).rejects.toThrow();
    });
  });

  describe("LZSS decoder traps — invalid pointers", () => {
    it("decode #pointer with backward_offset > output size traps", async () => {
      await expect(actor.decodeBadOffset()).rejects.toThrow();
    });
  });
});
