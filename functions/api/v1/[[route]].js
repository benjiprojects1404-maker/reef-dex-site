// Reef public data API (read-only). Cloudflare Pages Function.
//   GET /api/v1/pairs               every BDAG pool on Reef: reserves, pool price, FDV, LP locked or burned
//   GET /api/v1/pairs/<address>     one pool (by token or pool address, or "reef" / "nocap" / "cooked"), plus 24h volume and swaps
// Every number is read from BlockDAG chain 1404 through public RPCs and cached for 60 seconds.
// No keys, no writes, no tracking. CORS is open so any site can use it.

const RPCS = ["https://rpc.community.bdag-us.org", "https://rpc.capedag.com", "https://rpc.bdagexplorer.com", "https://rpc.dvdmining.com", "https://rpc.escrowhubs.io"];
const FACTORY = "0x9603042044b6B1A1637c508F731ba01219142239";
const WBDAG = "0x62ba5c4f067989a7f6644488c875bea69bfa1fba";
const HIDDEN_PAIR_INDEXES = new Set([1]); // test pair, hidden on the site too
const ALIASES = { reef: "0xb7a1e198767bf0fd4c1c3805b9757369e1c3f416", nocap: "0x17aee3eeda0d12e3a6a9a6078d028b88f9c91752", cooked: "0xd95c548b144682f4ef49728944505d8506861b1b" };
const LP_HOLDERS = { "0x030d2466f634022fb93fbdf475ea81faff2525a0": "REEF presale lock", "0x5520cc4e80e86e99c5a6a748c506d80f0d274bb1": "NOCAP LP lock", "0x7beae450c08b092317c3d882fb1ba1714c41420f": "Mauro LP lock", "0x000000000000000000000000000000000000dead": "dead address", "0x0000000000000000000000000000000000000000": "zero address" };
const SWAP_TOPIC = "0xd78ad95fa46c994b6551d0da85fc275fe613ce37657fb8d5e3d130840159d822";
const CACHE_SECONDS = 60;

const SEL = { allPairsLength: "0x574f2ba3", allPairs: "0x1e3dd18b", token0: "0x0dfe1681", token1: "0xd21220a7", getReserves: "0x0902f1ac", totalSupply: "0x18160ddd", balanceOf: "0x70a08231", symbol: "0x95d89b41", name: "0x06fdde03", decimals: "0x313ce567" };
const word = (n) => BigInt(n).toString(16).padStart(64, "0");
const addrWord = (a) => a.toLowerCase().replace(/^0x/, "").padStart(64, "0");
const toAddr = (hex) => "0x" + hex.slice(-40);
const big = (hex, i = 0) => BigInt("0x" + (hex.slice(2 + i * 64, 2 + (i + 1) * 64) || "0"));
function str(hex) { // ABI string, or bytes32 fallback
  if (!hex || hex.length < 66) return "";
  try {
    if (hex.length >= 130) { const len = Number(big(hex, 1)); return new TextDecoder().decode(Uint8Array.from(hex.slice(130, 130 + len * 2).match(/../g) || [], (b) => parseInt(b, 16))); }
    return new TextDecoder().decode(Uint8Array.from(hex.slice(2, 66).match(/../g), (b) => parseInt(b, 16))).replace(/\0+$/, "");
  } catch (e) { return ""; }
}
const units = (v, d = 18) => { const s = v.toString().padStart(d + 1, "0"); const i = s.slice(0, -d) || "0", f = s.slice(-d).replace(/0+$/, ""); return f ? `${i}.${f}` : i; };

async function rpc(batch) {
  let last;
  for (const url of RPCS) {
    try {
      const r = await fetch(url, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(batch.map((c, id) => ({ jsonrpc: "2.0", id, ...c }))), signal: AbortSignal.timeout(8000) });
      const j = await r.json();
      if (!Array.isArray(j)) throw new Error("bad batch reply");
      const out = []; for (const x of j) out[x.id] = x.error ? null : x.result;
      return out;
    } catch (e) { last = e; }
  }
  throw last || new Error("no RPC reachable");
}
const call = (to, data) => ({ method: "eth_call", params: [{ to, data }, "latest"] });

async function readPairs() {
  const [n] = await rpc([call(FACTORY, SEL.allPairsLength)]);
  const count = Number(big(n));
  const idx = [...Array(count).keys()].filter((i) => !HIDDEN_PAIR_INDEXES.has(i));
  const addrs = (await rpc(idx.map((i) => call(FACTORY, SEL.allPairs + word(i))))).map(toAddr);
  const base = await rpc(addrs.flatMap((a) => [call(a, SEL.token0), call(a, SEL.token1), call(a, SEL.getReserves), call(a, SEL.totalSupply),
    ...Object.keys(LP_HOLDERS).map((h) => call(a, SEL.balanceOf + addrWord(h)))]));
  const per = 4 + Object.keys(LP_HOLDERS).length;
  const pools = addrs.map((pair, i) => {
    const b = base.slice(i * per, (i + 1) * per);
    const t0 = toAddr(b[0]).toLowerCase(), t1 = toAddr(b[1]).toLowerCase();
    const r0 = big(b[2], 0), r1 = big(b[2], 1), supply = big(b[3]);
    const held = Object.keys(LP_HOLDERS).map((h, k) => [h, big(b[4 + k])]);
    const locked = held.reduce((s, [, v]) => s + v, 0n);
    return { pair, t0, t1, r0, r1, supply, locked, heldBy: held.filter(([, v]) => v > 0n).map(([h]) => LP_HOLDERS[h]),
      lpHolders: held.filter(([, v]) => v > 0n).map(([h, v]) => ({ address: h, label: LP_HOLDERS[h], pct: supply > 0n ? Number((v * 10000n) / supply) / 100 : 0 })) };
  }).filter((p) => p.t0 === WBDAG || p.t1 === WBDAG);
  const tokens = pools.map((p) => (p.t0 === WBDAG ? p.t1 : p.t0));
  const meta = await rpc(tokens.flatMap((t) => [call(t, SEL.symbol), call(t, SEL.name), call(t, SEL.decimals), call(t, SEL.totalSupply)]));
  return pools.map((p, i) => {
    const token = tokens[i], dec = meta[i * 4 + 2] ? Number(big(meta[i * 4 + 2])) : 18;
    const bdagIs0 = p.t0 === WBDAG;
    const rB = bdagIs0 ? p.r0 : p.r1, rT = bdagIs0 ? p.r1 : p.r0;
    const price = rT > 0n ? Number(rB) / 1e18 / (Number(rT) / 10 ** dec) : null;
    const supply = meta[i * 4 + 3] ? big(meta[i * 4 + 3]) : null;
    const fdv = supply !== null && rT > 0n ? supply * rB / rT : null; // total supply x pool price, in BDAG wei
    return {
      pair: p.pair, token, symbol: str(meta[i * 4]), name: str(meta[i * 4 + 1]), decimals: dec,
      reserveBDAG: units(rB, 18), reserveToken: units(rT, dec),
      priceBDAG: price, // BDAG per 1 token, from this pool's reserves (not a price feed)
      totalSupply: supply !== null ? units(supply, dec) : null,
      fdvBDAG: fdv !== null ? units(fdv, 18) : null, // fully diluted value = total supply x priceBDAG
      liquidityBDAG: units(rB * 2n, 18), // both sides of the pool, valued in BDAG
      lpLockedOrBurnedPct: p.supply > 0n ? Number((p.locked * 10000n) / p.supply) / 100 : 0, lpHeldBy: p.heldBy,
      lpHolders: p.lpHolders, // each known lock or burn address holding this pool's LP, with its share
      page: ALIASES.reef === token ? "https://reefdex.fyi/pairs/reef/" : ALIASES.nocap === token ? "https://reefdex.fyi/pairs/nocap/" : ALIASES.cooked === token ? "https://reefdex.fyi/pairs/cooked/" : null,
      swap: `https://reefdex.fyi/?from=bdag&to=${token}`,
      _bdagIs0: bdagIs0,
    };
  });
}

async function volume24h(p) {
  const [head] = await rpc([{ method: "eth_blockNumber", params: [] }]);
  const h = Number(big(head));
  const [nowB, backB] = await rpc([{ method: "eth_getBlockByNumber", params: ["0x" + h.toString(16), false] }, { method: "eth_getBlockByNumber", params: ["0x" + Math.max(0, h - 20000).toString(16), false] }]);
  const bt = (Number(nowB.timestamp) - Number(backB.timestamp)) / Math.min(20000, h || 1);
  const from = Math.max(0, h - Math.ceil(86400 / (bt || 1)));
  async function logs(a, b) {
    const [r] = await rpc([{ method: "eth_getLogs", params: [{ address: p.pair, topics: [SWAP_TOPIC], fromBlock: "0x" + a.toString(16), toBlock: "0x" + b.toString(16) }] }]);
    if (r === null) { if (b - a < 2) throw new Error("logs refused"); const m = Math.floor((a + b) / 2); return [...await logs(a, m), ...await logs(m + 1, b)]; }
    return r;
  }
  const ev = await logs(from, h);
  let vol = 0n;
  for (const l of ev) { const d = l.data; vol += p._bdagIs0 ? big(d, 0) + big(d, 2) : big(d, 1) + big(d, 3); }
  return { volume24hBDAG: units(vol, 18), swaps24h: ev.length, block: h };
}

const json = (body, status = 200) => new Response(JSON.stringify(body, null, 2), { status, headers: {
  "content-type": "application/json; charset=utf-8", "access-control-allow-origin": "*", "cache-control": `public, max-age=${CACHE_SECONDS}` } });
const clean = ({ _bdagIs0, ...rest }) => rest;

export async function onRequestGet(ctx) {
  const cache = caches.default;
  const hit = await cache.match(ctx.request);
  if (hit) return hit;
  const parts = (ctx.params.route || []).map((s) => s.toLowerCase());
  let res;
  try {
    if (parts[0] !== "pairs" || parts.length > 2) {
      res = json({ error: "not found", endpoints: ["/api/v1/pairs", "/api/v1/pairs/{token|pool address, or reef|nocap|cooked}"], docs: "https://reefdex.fyi/developers/" }, 404);
    } else {
      const pools = await readPairs();
      if (parts.length === 1) {
        res = json({ chainId: 1404, quote: "BDAG", updated: new Date().toISOString(), pairs: pools.map(clean) });
      } else {
        const want = ALIASES[parts[1]] || parts[1];
        const p = pools.find((x) => x.token === want || x.pair.toLowerCase() === want);
        res = p ? json({ chainId: 1404, quote: "BDAG", updated: new Date().toISOString(), ...clean(p), ...(await volume24h(p)) })
                : json({ error: "no BDAG pool on Reef for that token or pool address" }, 404);
      }
    }
  } catch (e) {
    return json({ error: "couldn't read the chain just now; try again shortly" }, 503); // not cached
  }
  ctx.waitUntil(cache.put(ctx.request, res.clone()));
  return res;
}

export function onRequestOptions() {
  return new Response(null, { headers: { "access-control-allow-origin": "*", "access-control-allow-methods": "GET, OPTIONS", "access-control-max-age": "86400" } });
}
