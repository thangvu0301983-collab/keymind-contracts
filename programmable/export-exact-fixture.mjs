#!/usr/bin/env node
// Turns the exact packed request (protected/launch.json) into the fork-test fixture used by
// test/KeymindExactVersion.fork.t.sol: the Router's graph targets with their resolved init code and initializer
// calldata, in deployment order, plus the route namespace and nonce that fix every CREATE2 address.
// The fixture lives outside the packed source bundle on purpose: it contains predicted addresses, and the
// bundle hash decides those addresses.
//
// Usage: PL_DIR=<installed @programmable/launch 4.1.7 dir> node programmable/export-exact-fixture.mjs

import { createHash } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const fail = (m) => { console.error("export-exact-fixture: " + m); process.exit(1); };
if (!process.env.PL_DIR) fail("set PL_DIR to the installed @programmable/launch 4.1.7 package directory");
const pl = (p) => pathToFileURL(path.join(process.env.PL_DIR, p)).href;
const viem = await import(pathToFileURL(createRequire(path.join(process.env.PL_DIR, "package.json")).resolve("viem")).href);
const { concatHex, encodeAbiParameters, getAddress, keccak256, parseAbiParameters } = viem;
const { normalizeAndPredictSubmittedGraph, deriveRouteNamespace } = await import(pl("src/graph.mjs"));
const { PROTECTED_LAUNCH_CHAIN_PINS_V1 } = await import(pl("src/launch-protection-v1.mjs"));
const protectedDir = path.join(repo, process.env.PROTECTED_DIR ?? "protected");
const fixturePath = path.join(repo, process.env.EXACT_FIXTURE ?? "test/fixtures/exact-launch.json");

const launchBytes = await readFile(path.join(protectedDir, "launch.json"));
const launch = JSON.parse(launchBytes);
const config = JSON.parse(await readFile(path.join(protectedDir, "protected-launch.config.json"), "utf8"));
const profile = launch.launchProfile;
const chainId = String(launch.chainId ?? config.chainId ?? "1");
const pins = PROTECTED_LAUNCH_CHAIN_PINS_V1[chainId];
const chainContext = { chainId, router: profile.router, graphFactory: profile.graphFactory };
const { graphBundle, predictions } = normalizeAndPredictSubmittedGraph(launch.graphBundle, config.launchWallet, config.nonce,
  { chainContext, projectMetadataHash: launch.projectMetadataHash });
const routeNamespace = deriveRouteNamespace(graphBundle.sourceBundleSha256, config.launchWallet, chainContext);

const byId = Object.fromEntries(graphBundle.targets.map((t) => [t.targetId, t]));
const ordered = predictions.map((p) => {
  const t = byId[p.targetId];
  return { ...p, initCode: concatHex([t.creationBytecode, p.resolvedConstructorArguments]),
    initializerCalldata: p.resolvedInitializerCalldata ?? "0x", deploymentValue: BigInt(t.deploymentValueWei),
    initializerValue: BigInt(t.initializerValueWei), expectedRuntimeCodeHash: t.expectedRuntimeCodeHash,
    creationCodeHash: keccak256(t.creationBytecode) };
});
for (const t of ordered) if (keccak256(t.initCode) !== t.initCodeHash) fail("init code differs for " + t.targetId);

const targetsAbi = encodeAbiParameters(
  parseAbiParameters("(bytes32 targetIdHash,bytes32 applicantSalt,uint256 deploymentValue,uint256 initializerValue,bytes initCode,bytes initializerCalldata)[]"),
  [ordered.map((t) => ({ targetIdHash: t.targetIdHash, applicantSalt: t.applicantSalt, deploymentValue: t.deploymentValue,
    initializerValue: t.initializerValue, initCode: t.initCode, initializerCalldata: t.initializerCalldata }))]);
const init = config.targets.find((t) => t.targetId === "initializer");
const [, , startTick, developer, minimumTokensOut] = init.initializer.arguments;
const role = (id) => ordered.find((t) => t.targetId === id);
const fixture = {
  schemaVersion: "keymind.exact-launch-fixture.v1",
  chainId: Number(chainId), poolManager: getAddress(profile.poolManager), universalRouter: getAddress(pins.router), feed: getAddress(pins.feed),
  launchJsonSha256: "sha256:" + createHash("sha256").update(launchBytes).digest("hex"),
  router: getAddress(profile.router), graphFactory: getAddress(profile.graphFactory), launchWallet: getAddress(config.launchWallet),
  routeNamespace, routeNonce: config.nonce,
  totalValue: String(ordered.reduce((s, t) => s + t.deploymentValue + t.initializerValue, 0n)),
  startTick, developer: getAddress(developer), minimumTokensOut: String(minimumTokensOut),
  initialBuyWei: String(BigInt(init.initializerValueWei)),
  initializer: getAddress(role("initializer").predictedAddress), token: getAddress(role("token").predictedAddress),
  hook: getAddress(role("hook").predictedAddress), vault: getAddress(role("vault").predictedAddress),
  initializerRuntimeCodeHash: role("initializer").expectedRuntimeCodeHash, tokenRuntimeCodeHash: role("token").expectedRuntimeCodeHash,
  hookRuntimeCodeHash: role("hook").expectedRuntimeCodeHash, vaultRuntimeCodeHash: role("vault").expectedRuntimeCodeHash,
  validAfter: launch.permitWindow.validAfter, deadline: launch.permitWindow.deadline,
  targetsAbi,
  creationCodeHashes: Object.fromEntries(ordered.map((t) => [t.targetId, t.creationCodeHash])),
};
await mkdir(path.dirname(fixturePath), { recursive: true });
await writeFile(fixturePath, JSON.stringify(fixture, null, 2) + "\n");
console.log(JSON.stringify({ ok: true, launchJsonSha256: fixture.launchJsonSha256, order: ordered.map((t) => t.targetId),
  token: fixture.token, hook: fixture.hook }, null, 2));
