// Read-only check of a deployed KitchenFactory. Sends nothing.
//   node scripts/kitchen/check-kitchen.js <factory address>
const { ethers } = require("ethers");
const RPCS = ["https://rpc.community.bdag-us.org", "https://rpc.bdagexplorer.com", "https://rpc.dagcore.net"];
const EXPECT = {
  admin: "0x4E2401bFD24c66166fABF9Cc5cD5B6B2c5c860fc",       // Reef admin multisig (2-of-3)
  feeRecipient: "0xECc48Bca8c28Caa8e980E308DFb08B8dEfE86267", // Reef treasury
  fee: ethers.parseEther("5000"),
};
const RESERVED = ["BDAG", "WBDAG", "REEF", "NOCAP", "COOKED", "USDT", "USDC", "ETH", "WETH", "BTC", "WBTC"];
const ABI = ["function admin() view returns (address)", "function feeRecipient() view returns (address)", "function fee() view returns (uint256)",
  "function MAX_FEE() view returns (uint256)", "function tokenCount() view returns (uint256)", "function isReserved(string) view returns (bool)", "function pendingAdmin() view returns (address)"];

(async () => {
  const addr = process.argv[2];
  if (!addr || !ethers.isAddress(addr)) { console.error("Usage: node scripts/kitchen/check-kitchen.js <factory address>"); process.exit(2); }
  let p;
  for (const u of RPCS) { try { p = new ethers.JsonRpcProvider(u, 1404, { staticNetwork: true }); await p.getBlockNumber(); break; } catch (e) { p = null; } }
  if (!p) { console.error("Can't reach a BlockDAG RPC."); process.exit(1); }
  const f = new ethers.Contract(addr, ABI, p);
  const [admin, rec, fee, max, n, pend] = await Promise.all([f.admin(), f.feeRecipient(), f.fee(), f.MAX_FEE(), f.tokenCount(), f.pendingAdmin()]);
  let ok = true;
  const line = (label, good, val) => { if (!good) ok = false; console.log(`${good ? "OK  " : "FAIL"} ${label}: ${val}`); };
  line("admin is the Reef multisig", admin.toLowerCase() === EXPECT.admin.toLowerCase(), admin);
  line("fee goes to the Reef treasury", rec.toLowerCase() === EXPECT.feeRecipient.toLowerCase(), rec);
  line("fee is 5,000 BDAG", fee === EXPECT.fee, ethers.formatEther(fee) + " BDAG");
  line("fee cap is 50,000 BDAG", max === ethers.parseEther("50000"), ethers.formatEther(max) + " BDAG");
  line("no admin hand-over pending", pend === ethers.ZeroAddress, pend);
  for (const s of RESERVED) line(`ticker ${s} reserved`, await f.isReserved(s), "");
  console.log(`Tokens made so far: ${n}`);
  process.exit(ok ? 0 : 1);
})();
