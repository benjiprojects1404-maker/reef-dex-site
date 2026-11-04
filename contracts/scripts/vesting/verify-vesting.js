// Checks that remix/ReefVesting.sol is the code deployed at Reef's vesting addresses,
// and prints each contract's schedule as read from chain.
//
// The vesting contracts were compiled in Remix with Solidity 0.8.20, separately from the
// rest of Reef (0.8.24), so the exact Remix settings aren't recorded anywhere. This script
// tries the combinations Remix could have used (OpenZeppelin version, optimizer on/off,
// EVM version), and reports which one reproduces the deployed bytecode exactly.
//
// Run from contracts/:   node scripts/vesting/verify-vesting.js
// Optional:              RPC=https://... node scripts/vesting/verify-vesting.js
//                        VESTING=0xabc...,0xdef... (check other addresses)
//
// First run installs solc 0.8.20 and the OpenZeppelin versions into scripts/vesting/.cache
// (a few MB, needs npm). Nothing is sent to the chain: it only reads.

const fs = require("fs");
const path = require("path");
const { execSync } = require("child_process");
const { ethers } = require("ethers");

const RPC = process.env.RPC || "https://rpc.blockdag.engineering";
const REEF = "0xb7a1e198767bf0fd4C1C3805b9757369e1c3F416";
const TARGETS = process.env.VESTING
  ? process.env.VESTING.split(",").map((a) => ({ label: a, address: a.trim() }))
  : [
      { label: "Dev vesting (12-month cliff, 36 months)", address: "0x5468821749B936ffa6C3aF840841058b026E288f" },
      { label: "Treasury vesting (6-month cliff, 36 months)", address: "0x8750aC546e0B6234B292F3830958F780E3e304BD" },
    ];

const OZ_VERSIONS = ["5.0.2", "5.1.0", "5.2.0", "5.3.0", "5.4.0", "4.9.6", "5.0.0", "5.0.1"];
const EVMS = ["shanghai", "paris", "london", "berlin"]; // shanghai is 0.8.20's default (Remix's default too)
const OPTIMIZER = [{ enabled: false, runs: 200 }, { enabled: true, runs: 200 }];

const CACHE = path.join(__dirname, ".cache");
const SOURCE_PATH = path.join(__dirname, "..", "..", "remix", "ReefVesting.sol");

function setupCache() {
  const want = ["solc@0.8.20", ...OZ_VERSIONS.map((v) => `oz-${v}@npm:@openzeppelin/contracts@${v}`)];
  const missing = OZ_VERSIONS.some((v) => !fs.existsSync(path.join(CACHE, "node_modules", `oz-${v}`)))
    || !fs.existsSync(path.join(CACHE, "node_modules", "solc"));
  if (!missing) return;
  fs.mkdirSync(CACHE, { recursive: true });
  if (!fs.existsSync(path.join(CACHE, "package.json"))) fs.writeFileSync(path.join(CACHE, "package.json"), '{"private":true}\n');
  console.log("First run: installing solc 0.8.20 and OpenZeppelin versions into scripts/vesting/.cache ...");
  execSync(`npm install --no-audit --no-fund --silent ${want.join(" ")}`, { cwd: CACHE, stdio: "inherit" });
}

/// Runtime bytecode without the trailing CBOR metadata, which changes with comments and whitespace.
function stripMetadata(hex) {
  hex = hex.toLowerCase().replace(/^0x/, "");
  if (hex.length < 4) return hex;
  const cborLen = parseInt(hex.slice(-4), 16);
  const cut = hex.length - 4 - cborLen * 2;
  return cut > 0 ? hex.slice(0, cut) : hex;
}

function compileAll() {
  const solc = require(path.join(CACHE, "node_modules", "solc"));
  if (!solc.version().startsWith("0.8.20")) throw new Error(`expected solc 0.8.20, got ${solc.version()}`);
  const source = fs.readFileSync(SOURCE_PATH, "utf8");
  const variants = [];
  for (const oz of OZ_VERSIONS) {
    const ozRoot = path.join(CACHE, "node_modules", `oz-${oz}`);
    const findImports = (p) => {
      const prefix = "@openzeppelin/contracts/";
      if (!p.startsWith(prefix)) return { error: `not found: ${p}` };
      const f = path.join(ozRoot, p.slice(prefix.length));
      return fs.existsSync(f) ? { contents: fs.readFileSync(f, "utf8") } : { error: `not found: ${p}` };
    };
    for (const evm of EVMS) {
      for (const opt of OPTIMIZER) {
        const input = {
          language: "Solidity",
          sources: { "ReefVesting.sol": { content: source } },
          settings: {
            optimizer: opt,
            evmVersion: evm,
            outputSelection: { "*": { "*": ["evm.deployedBytecode.object"] } },
          },
        };
        const out = JSON.parse(solc.compile(JSON.stringify(input), { import: findImports }));
        const errors = (out.errors || []).filter((e) => e.severity === "error");
        const label = `OpenZeppelin ${oz}, optimizer ${opt.enabled ? `on (${opt.runs} runs)` : "off"}, EVM ${evm}`;
        if (errors.length) {
          variants.push({ label, error: errors[0].message.split("\n")[0] });
          continue;
        }
        const code = out.contracts["ReefVesting.sol"].ReefVesting.evm.deployedBytecode.object;
        variants.push({ label, code: stripMetadata(code) });
      }
    }
  }
  return variants;
}

const fmt = (ts) => {
  const d = new Date(Number(ts) * 1000);
  const bkk = new Date(d.getTime() + 7 * 3600 * 1000).toISOString().replace("T", " ").slice(0, 16);
  return `${d.toISOString().replace("T", " ").slice(0, 16)} UTC  (${bkk} Bangkok)`;
};
const months = (secs) => (Number(secs) / (365.25 / 12 * 86400)).toFixed(1);

async function main() {
  setupCache();
  console.log("Compiling remix/ReefVesting.sol with solc 0.8.20 under each candidate setting ...");
  const variants = compileAll();
  const built = variants.filter((v) => v.code);
  console.log(`  ${built.length} of ${variants.length} combinations compiled (the rest need a newer compiler and can't be what was deployed).\n`);
  if (!built.length) throw new Error("nothing compiled; check the cache install");

  const provider = new ethers.JsonRpcProvider(RPC);
  const net = await provider.getNetwork();
  console.log(`Chain: ${RPC} (chain id ${net.chainId})\n`);

  const abi = [
    "function beneficiary() view returns (address)",
    "function start() view returns (uint256)",
    "function cliffEnd() view returns (uint256)",
    "function end() view returns (uint256)",
    "function released(address) view returns (uint256)",
    "function releasable(address) view returns (uint256)",
  ];
  const reef = new ethers.Contract(REEF, ["function balanceOf(address) view returns (uint256)"], provider);
  let allMatched = true;

  for (const t of TARGETS) {
    console.log(`== ${t.label}\n   ${t.address}`);
    const onchain = await provider.getCode(t.address);
    if (onchain === "0x") {
      console.log("   NO CODE at this address on this chain.\n");
      allMatched = false;
      continue;
    }
    const want = stripMetadata(onchain);
    const hits = built.filter((v) => v.code === want);
    if (hits.length) {
      console.log(`   SOURCE MATCHES the deployed code. Settings: ${hits[0].label}`);
      if (hits.length > 1) console.log(`   (${hits.length - 1} other setting(s) give byte-identical code, e.g. ${hits.slice(1, 3).map((h) => h.label).join("; ")})`);
    } else {
      allMatched = false;
      console.log("   NO MATCH: none of the tried settings reproduces the deployed code.");
      console.log(`   Deployed runtime size ${want.length / 2} bytes; sizes this source compiles to: ${[...new Set(built.map((b) => b.code.length / 2))].sort((a, b) => a - b).join(", ")} bytes`);
    }

    const v = new ethers.Contract(t.address, abi, provider);
    try {
      const [ben, start, cliff, end, rel, relNow, bal] = await Promise.all([
        v.beneficiary(), v.start(), v.cliffEnd(), v.end(), v.released(REEF), v.releasable(REEF), reef.balanceOf(t.address),
      ]);
      const benCode = await provider.getCode(ben);
      console.log(`   Beneficiary : ${ben} (${benCode === "0x" ? "a plain wallet" : "a contract, e.g. a multisig"})`);
      console.log(`   Start       : ${fmt(start)}`);
      console.log(`   Cliff ends  : ${fmt(cliff)}  -> ${months(cliff - start)} months after start`);
      console.log(`   Fully vested: ${fmt(end)}  -> ${months(end - start)} months after start`);
      console.log(`   REEF held   : ${ethers.formatUnits(bal, 18)}   released so far: ${ethers.formatUnits(rel, 18)}   releasable now: ${ethers.formatUnits(relNow, 18)}`);
    } catch (e) {
      console.log(`   Could not read the schedule (${e.shortMessage || e.message}).`);
    }
    console.log("");
  }
  console.log(allMatched ? "RESULT: every vesting address matches remix/ReefVesting.sol." : "RESULT: at least one address did NOT match. Paste this output to Claude.");
  process.exit(allMatched ? 0 : 1);
}

if (require.main === module) {
  main().catch((e) => {
    console.error(`ERROR: ${e.shortMessage || e.message}`);
    process.exit(2);
  });
}

module.exports = { setupCache, compileAll, stripMetadata };
