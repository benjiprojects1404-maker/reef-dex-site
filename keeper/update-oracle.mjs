// Calls ReefTWAPOracle.update() when the 24h window has passed. update() is permissionless,
// so the wallet used here needs no privileges: fund it with a little BDAG for gas only.
import { ethers } from "ethers";

const CHAIN_ID = 1404;
const ORACLES = [
  { name: "NOCAP/BDAG", address: "0xa461aAe6Ba4bDb68192D2a53e60640053a35FF7b" },
];
const RPCS = [
  process.env.RPC_URL,
  "https://rpc.capedag.com",
  "https://rms-bdag-rpc.de/api/rpc-live",
  "https://rpc.dvdmining.com",
  "https://rpc.cms-mining-pool.net",
  "https://rpc.england.bdag-us.org",
].filter(Boolean);
const ABI = [
  "function secondsUntilNextUpdate() view returns (uint256)",
  "function blockTimestampLast() view returns (uint32)",
  "function update()",
];

async function pickProvider() {
  for (const url of RPCS) {
    try {
      const p = new ethers.JsonRpcProvider(url, CHAIN_ID, { staticNetwork: true });
      const net = await Promise.race([p.getNetwork(), new Promise((_, r) => setTimeout(() => r(new Error("timeout")), 8000))]);
      if (Number(net.chainId) === CHAIN_ID) return p;
    } catch (e) { console.log(`RPC ${url} unavailable: ${e.message}`); }
  }
  throw new Error("No working chain 1404 RPC");
}

const key = process.env.KEEPER_PRIVATE_KEY;
if (!key) { console.log("KEEPER_PRIVATE_KEY secret is not set; nothing to do."); process.exit(0); }

const provider = await pickProvider();
const wallet = new ethers.Wallet(key, provider);
let failed = false;
for (const o of ORACLES) {
  try {
    const oracle = new ethers.Contract(o.address, ABI, wallet);
    const wait = Number(await oracle.secondsUntilNextUpdate());
    if (wait > 0) { console.log(`${o.name}: not due for ${wait}s, skipping.`); continue; }
    const tx = await oracle.update();
    console.log(`${o.name}: update() sent ${tx.hash}`);
    await tx.wait();
    console.log(`${o.name}: updated.`);
  } catch (e) { failed = true; console.log(`${o.name}: failed: ${e.shortMessage || e.message}`); }
}
process.exit(failed ? 1 : 0);
