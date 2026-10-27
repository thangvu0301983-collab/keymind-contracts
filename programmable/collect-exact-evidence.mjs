#!/usr/bin/env node
// Collects the exact-version fork evidence into evidence/exact-version.json and the whole test run into
// evidence/forge-tests.json. Both files are packed into the request (programmable/build-protected.mjs), so they hold
// no target addresses: the bundle hash decides those addresses. Only constants that do not depend on the bundle
// (the launch wallet, Programmable's router and factory, creation bytecode hashes, prices, amounts) are recorded.
//
// Usage: FORK_BLOCK=<n> node programmable/collect-exact-evidence.mjs <forge-test --json output file>

import { readdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const fail = (m) => { console.error("collect-exact-evidence: " + m); process.exit(1); };
const forgeJsonPath = process.argv[2] ?? fail("pass the forge test --json output file");
const forkBlock = process.env.FORK_BLOCK ?? fail("set FORK_BLOCK to the block the exact tests ran at");

const raw = await readFile(forgeJsonPath, "utf8");
const forge = JSON.parse(raw.slice(raw.indexOf("{")));
const results = [];
for (const [suitePath, suite] of Object.entries(forge)) {
  const suiteName = suitePath.split(":").pop();
  for (const [test, r] of Object.entries(suite.test_results ?? {})) results.push({ suite: suiteName, test, status: r.status });
}
results.sort((a, b) => (a.suite + a.test).localeCompare(b.suite + b.test));
const failed = results.filter((r) => r.status !== "Success");
if (failed.length) fail("failing tests: " + failed.map((r) => r.suite + "." + r.test).join(", "));
const exactTests = results.filter((r) => r.suite === "KeymindExactVersionForkTest");
if (exactTests.length < 20) fail("the exact-version suite did not run completely");

const evidenceDir = path.join(repo, process.env.EVIDENCE_DIR ?? "evidence");
const dir = path.join(repo, process.env.EXACT_EVIDENCE_DIR ?? "evidence/exact");
const scenarios = {};
for (const file of (await readdir(dir)).filter((f) => f.endsWith(".json")).sort()) {
  const s = JSON.parse(await readFile(path.join(dir, file), "utf8"));
  if (s.passed !== true) fail(file + " did not pass");
  scenarios[s.scenario] = s;
}
if (Object.keys(scenarios).length !== exactTests.length) fail("evidence files and exact tests differ");
const text = JSON.stringify(scenarios);
if (/0x[0-9a-fA-F]{40}/.test(text)) fail("scenario evidence must not contain addresses");

const fx = JSON.parse(await readFile(path.join(repo, process.env.EXACT_FIXTURE ?? "test/fixtures/exact-launch.json"), "utf8"));
const map = (...ids) => ids.filter((id) => scenarios[id]);
const evidence = {
  schemaVersion: "keymind.exact-version-execution-evidence.v1",
  subject: {
    chainId: String(fx.chainId ?? 1),
    forkBlock: String(forkBlock),
    launchWallet: fx.launchWallet,
    developer: fx.developer,
    router: fx.router,
    graphFactory: fx.graphFactory,
    creationCodeHashes: fx.creationCodeHashes,
    initializerCall: { function: "initialize(hook,token,startTick,developer,minimumTokensOut)", startTick: fx.startTick,
      minimumTokensOut: fx.minimumTokensOut, valueWei: fx.initialBuyWei },
    permitWindow: { validAfter: fx.validAfter, deadline: fx.deadline,
      lifetimeSeconds: String(BigInt(fx.deadline) - BigInt(fx.validAfter)), routerMaximumLifetimeSeconds: "86400" },
  },
  harness: {
    method: "The exact Router graph targets of the packed request (resolved init code and initializer calldata, in "
      + "deployment order) are deployed through Programmable's GraphFactory on an Ethereum mainnet fork, called as the "
      + "24h Router with the launch wallet as tx.origin. Every target is asserted to sit at its predicted CREATE2 address "
      + "with the packed runtime code hash. Only the Router's permit signature check is not exercised.",
    test: "test/KeymindExactVersion.fork.t.sol",
    fixtureExporter: "programmable/export-exact-fixture.mjs",
    addressFree: "This file is inside the packed source bundle, so it records no target addresses. The request is "
      + "rebuilt with this file and re-tested; packing stops only when the regenerated file is byte-identical.",
  },
  requiredEvidence: {
    "launch.initial-buy-bound-call": map("initial-buy-bound-call", "P03-initial-buy-above-2pct-reverts", "P04-initial-buy-minimum-output"),
    "launch.protection-scenarios": map("P01-opening-fdv-floor", "P02-stale-oracle-rejected", "P03-initial-buy-above-2pct-reverts",
      "P04-initial-buy-minimum-output", "P05-single-atomic-initialization", "P06-opening-tax-at-launch-second",
      "P07-opening-tax-decay", "P08-developer-tax-exempt-but-capped", "P09-buyer-cap-cumulative",
      "P10-recipient-cap-on-transfers", "P11-canonical-router-only-buys", "P12-protection-expires-at-300s"),
    "oracle.fresh-feed-and-fdv": map("initial-buy-bound-call", "P01-opening-fdv-floor", "P02-stale-oracle-rejected"),
    "swap.four-quadrant-multi-size": map("S01-four-quadrants-multi-size"),
    "swap.second-user-and-time": map("S02-second-user-and-time"),
    "liquidity.lock-release-and-custody": map("L01-liquidity-custody-and-withdrawal"),
    "liquidity.declared-lifecycle-and-withdrawal": map("L01-liquidity-custody-and-withdrawal"),
    "callback.pool-manager-authentication": map("C01-callback-authentication", "P05-single-atomic-initialization"),
    "vault.keymind-agent-grants": map("G01-keymind-vault-agent-grants", "A01-custom-accounting"),
    "custom-accounting.delta-solvency-backing-refund-withdrawal": map("A01-custom-accounting"),
    "platform-fee.exact-no-bypass-no-overcharge-claim-isolation": map("F01-platform-fee-exact", "A01-custom-accounting"),
  },
  scenarios,
  tests: { exactVersionPassed: exactTests.length, allPassed: results.length, failed: 0 },
};
await writeFile(path.join(evidenceDir, "exact-version.json"), JSON.stringify(evidence, null, 2) + "\n");
await writeFile(path.join(evidenceDir, "forge-tests.json"), JSON.stringify({ schemaVersion: "keymind.forge-test-evidence.v1",
  status: "passed", forkTestsIncluded: true, passed: results.length, results }, null, 2) + "\n");
console.log(JSON.stringify({ ok: true, scenarios: Object.keys(scenarios).length, allPassed: results.length }));
