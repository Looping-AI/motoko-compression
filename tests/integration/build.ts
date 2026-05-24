#!/usr/bin/env bun
/**
 * Build script: compile Motoko canisters to WASM and generate Candid JS/TS
 * bindings. Output goes to tests/integration/builds/ (gitignored).
 *
 * Usage:  bun run test:build
 * Requires: mops, didc on PATH
 */
import { $ } from "bun";
import { join, relative } from "node:path";

const BUILD_TARGETS = {
  compression: {
    name: "compression canister",
    sourceFile: join(process.cwd(), "example", "compress.mo"),
    outputPrefix: "compression",
  },
  "external-decompress": {
    name: "external-decompress canister",
    sourceFile: join(process.cwd(), "example", "external-decompress.mo"),
    outputPrefix: "external-decompress",
  },
  "image-compression": {
    name: "image-compression canister",
    sourceFile: join(process.cwd(), "example", "compress-images.mo"),
    outputPrefix: "image-compression",
  },
} as const;

async function getBuildEnvironment() {
  const mocPath = await $`mops toolchain bin moc`.text();
  const sources = await $`mops sources`.text();
  const outputDir = join(process.cwd(), "tests", "integration", "builds");

  await $`mkdir -p ${outputDir}`;

  return {
    mocPath: mocPath.trim(),
    sourcesArgs: sources
      .trim()
      .split(/\s+/)
      .filter((arg) => arg.length > 0),
    outputDir,
  };
}

async function compileToWasm(target: keyof typeof BUILD_TARGETS) {
  const config = BUILD_TARGETS[target];
  const { mocPath, sourcesArgs, outputDir } = await getBuildEnvironment();
  const outputFile = join(outputDir, `${config.outputPrefix}.wasm`);

  const args = [mocPath, ...sourcesArgs, "-o", outputFile, config.sourceFile];

  console.log(`Building ${config.name}...`);
  await $`${args}`.env({ ...process.env });

  // Gzip-compress in place — ICP accepts compressed WASMs and this keeps
  // files well under PocketIC's 2 MB ingress limit.
  const tmpFile = `${outputFile}.tmp`;
  await $`gzip -c ${outputFile} > ${tmpFile}`.env({ ...process.env });
  await $`mv ${tmpFile} ${outputFile}`.env({ ...process.env });

  console.log(`  ✅ ${config.outputPrefix}.wasm (gzip-compressed)`);
}

async function generateCandidInterface(target: keyof typeof BUILD_TARGETS) {
  const config = BUILD_TARGETS[target];
  const { mocPath, sourcesArgs, outputDir } = await getBuildEnvironment();
  const candidFile = join(outputDir, `${config.outputPrefix}.did`);
  const tsBindingsFile = join(outputDir, `${config.outputPrefix}.did.d.ts`);
  const jsBindingsFile = join(outputDir, `${config.outputPrefix}.did.js`);

  console.log(`Generating Candid bindings for ${config.name}...`);

  const candidArgs = [
    mocPath,
    ...sourcesArgs,
    "--idl",
    config.sourceFile,
    "-o",
    candidFile,
  ];
  await $`${candidArgs}`.env({ ...process.env });

  await $`didc bind ${candidFile} -t ts > ${tsBindingsFile}`.env({
    ...process.env,
  });
  await $`didc bind ${candidFile} -t js > ${jsBindingsFile}`.env({
    ...process.env,
  });

  console.log(
    `  ✅ ${relative(process.cwd(), tsBindingsFile)}\n` +
      `  ✅ ${relative(process.cwd(), jsBindingsFile)}`,
  );
}

async function buildTarget(target: keyof typeof BUILD_TARGETS) {
  await compileToWasm(target);
  await generateCandidInterface(target);
}

async function buildAll() {
  console.log("🚀 Starting build...\n");
  await buildTarget("compression");
  console.log();
  await buildTarget("external-decompress");
  console.log();
  await buildTarget("image-compression");
  console.log();
  console.log("🎉 Build complete — artifacts in tests/integration/builds/");
}

if (import.meta.main) {
  await buildAll();
}
