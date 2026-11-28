// Reef public data API (read-only). Cloudflare Pages Function.
//   GET /api/v1/pairs               every BDAG pool on Reef: reserves, pool price, FDV, LP locked or burned
//   GET /api/v1/pairs/<address>     one pool (by token or pool address, or "reef" / "nocap" / "cooked"), plus 24h volume and swaps
//   GET /api/v1/tickers             every BDAG pool's price now and 24 hours ago (from its own Sync/Swap events), the % change,
//                                   24h volume and swaps, and whether the pool is new (created in the last 7 days)
// Every number is read from BlockDAG chain 1404 through public RPCs. Answers are cached at the edge and refreshed in the
// background (tickers every 5 minutes, pairs every 2), so visitors never wait on the chain and the free plan's 10 ms CPU
// limit is only touched by an occasional background refresh.
// No keys, no writes, no tracking. CORS is open so any site can use it.

const RPCS = ["https://rpc.community.bdag-us.org", "https://rpc.capedag.com", "https://rpc.bdagexplorer.com", "https://rpc.dvdmining.com", "https://rpc.escrowhubs.io"];
const FACTORY = "0x9603042044b6B1A1637c508F731ba01219142239";
const WBDAG = "0x62ba5c4f067989a7f6644488c875bea69bfa1fba";
const HIDDEN_PAIR_INDEXES = new Set([1]); // test pair, hidden on the site too
const ALIASES = { reef: "0xb7a1e198767bf0fd4c1c3805b9757369e1c3f416", nocap: "0x17aee3eeda0d12e3a6a9a6078d028b88f9c91752", cooked: "0xd95c548b144682f4ef49728944505d8506861b1b" };
const LP_HOLDERS = { "0x030d2466f634022fb93fbdf475ea81faff2525a0": "REEF presale lock", "0x5520cc4e80e86e99c5a6a748c506d80f0d274bb1": "NOCAP LP lock", "0x7beae450c08b092317c3d882fb1ba1714c41420f": "Mauro LP lock", "0x000000000000000000000000000000000000dead": "dead address", "0x0000000000000000000000000000000000000000": "zero address" };
// Reef Lock (ReefLocker): only locks whose unlock date is still ahead count as locked. Expired-but-not-withdrawn
// locks could be withdrawn any moment, so they don't count.
const REEF_LOCK = "0xd999d2e6efc1d30143e23c3cc736adedff95c2a1";
const LOCK_SEL = { lockedSummary: "0xa07aa30d", locksForToken: "0x75b99371", getLock: "0xd68f4dd1" };
const SWAP_TOPIC = "0xd78ad95fa46c994b6551d0da85fc275fe613ce37657fb8d5e3d130840159d822";
const SYNC_TOPIC = "0x1c411e9a96e071241c2f21f7726b17ae89e3cab4c78be50e062b03a9fffbbad1";
const PAIR_CREATED_TOPIC = "0x0d3648bd0f6ba80134a33ba9275ac585d9d315f0ad8355cddefde31afa28d0e9";
const FRESH_SECONDS = { tickers: 300, pairs: 120 }; // how long an answer is served before a background refresh
const KEEP_SECONDS = 1800; // how long a stale answer may still be served while the chain is slow or a refresh fails

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

// Public nodes can fall hundreds of blocks behind (rpc.capedag.com was ~480 behind on 15 Nov 2026, so a new pool
// was missing from the list). Once per isolate every 30s, ask every node for its block height and only use nodes
// within MAX_LAG blocks of the highest, highest first; fall back to the full list if that check fails.
const MAX_LAG = 20;
let ranked = null, rankedAt = 0;
async function freshRpcs() {
  if (ranked && Date.now() - rankedAt < 30000) return ranked;
  const heights = await Promise.all(RPCS.map(async (url) => {
    try {
      const r = await fetch(url, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_blockNumber", params: [] }), signal: AbortSignal.timeout(4000) });
      const j = await r.json();
      return { url, h: j && j.result ? Number(BigInt(j.result)) : -1 };
    } catch (e) { return { url, h: -1 }; }
  }));
  const top = Math.max(...heights.map((x) => x.h));
  if (top < 0) return RPCS;
  ranked = heights.filter((x) => x.h >= top - MAX_LAG).sort((a, b) => b.h - a.h).map((x) => x.url);
  rankedAt = Date.now();
  return ranked;
}

async function rpc(batch) {
  let last;
  for (const url of await freshRpcs()) {
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

async function addReefLocks(pools) {
  try {
    const sums = await rpc(pools.map((p) => call(REEF_LOCK, LOCK_SEL.lockedSummary + addrWord(p.pair))));
    const withLocks = pools.filter((p, i) => sums[i] && big(sums[i], 2) > 0n); // openLocks > 0
    if (!withLocks.length) return;
    const idLists = await rpc(withLocks.map((p) => call(REEF_LOCK, LOCK_SEL.locksForToken + addrWord(p.pair))));
    const ids = idLists.map((h) => { if (!h) return []; const n = Number(big(h, 1)); return [...Array(n).keys()].map((k) => big(h, 2 + k)); });
    const locks = await rpc(ids.flat().map((id) => call(REEF_LOCK, LOCK_SEL.getLock + word(id))));
    const now = BigInt(Math.floor(Date.now() / 1000));
    let k = 0;
    withLocks.forEach((p, i) => {
      let amount = 0n, until = 0n, n = 0;
      for (const _ of ids[i]) {
        const h = locks[k++]; if (!h) continue;
        const amt = big(h, 2), unlock = big(h, 4), withdrawn = big(h, 5) === 1n;
        if (withdrawn || unlock <= now) continue;
        amount += amt; n++; if (!until || unlock < until) until = unlock;
      }
      if (amount === 0n) return;
      p.locked += amount; p.heldBy.push("Reef Lock");
      p.lpHolders.push({ address: REEF_LOCK, label: "Reef Lock", pct: p.supply > 0n ? Number((amount * 10000n) / p.supply) / 100 : 0, until: Number(until), locks: n });
    });
  } catch (e) { /* Reef Lock unreadable: report the other locks and burns only */ }
}

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
  await addReefLocks(pools);
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

// Head block and average block time, from the last 20,000 blocks.
async function chainClock() {
  const [head] = await rpc([{ method: "eth_blockNumber", params: [] }]);
  const h = Number(big(head));
  const [nowB, backB] = await rpc([{ method: "eth_getBlockByNumber", params: ["0x" + h.toString(16), false] }, { method: "eth_getBlockByNumber", params: ["0x" + Math.max(0, h - 20000).toString(16), false] }]);
  const bt = (Number(nowB.timestamp) - Number(backB.timestamp)) / Math.min(20000, h || 1);
  return { h, bt: bt || 1 };
}
// eth_getLogs, halving the block range whenever a node refuses it as too large.
async function getLogs(filter, a, b) {
  const [r] = await rpc([{ method: "eth_getLogs", params: [{ ...filter, fromBlock: "0x" + a.toString(16), toBlock: "0x" + b.toString(16) }] }]);
  if (r === null || r === undefined) { if (b - a < 2) throw new Error("logs refused"); const m = Math.floor((a + b) / 2); return [...await getLogs(filter, a, m), ...await getLogs(filter, m + 1, b)]; }
  return r;
}
const priceOf = (rB, rT, dec) => (rT > 0n ? Number(rB) / 1e18 / (Number(rT) / 10 ** dec) : null);

// Price 24h ago without archive nodes: the pool's state just before its first event in the window. Every swap,
// add and remove ends with Sync(reserves after); a swap's Swap event follows its Sync in the same transaction, so
// reserves before = reserves after - amounts in + amounts out. Adds and removes don't move the price. No event in
// the window means the price hasn't moved.
async function tickers(pools) {
  const { h, bt } = await chainClock();
  const from = Math.max(0, h - Math.ceil(86400 / bt)), from7 = Math.max(0, h - Math.ceil(7 * 86400 / bt));
  const [ev, created] = await Promise.all([
    getLogs({ address: pools.map((p) => p.pair), topics: [[SYNC_TOPIC, SWAP_TOPIC]] }, from, h).catch(() => null),
    getLogs({ address: FACTORY, topics: [PAIR_CREATED_TOPIC] }, from7, h).catch(() => []),
  ]);
  if (ev === null) throw new Error("event scan failed"); // the caller serves the last good answer instead
  const fresh = new Set(created.map((l) => toAddr(l.data.slice(0, 66)).toLowerCase()));
  const byPair = {};
  for (const l of ev) (byPair[l.address.toLowerCase()] ||= []).push(l);
  return pools.map((p) => {
    const logs = byPair[p.pair.toLowerCase()] || []; // eth_getLogs returns logs in block and log order already
    const now = p.priceBDAG;
    let before = now, vol = 0n, swaps = 0;
    const first = logs.find((l) => l.topics[0] === SYNC_TOPIC);
    if (first) {
      let r0 = big(first.data, 0), r1 = big(first.data, 1);
      const fi = logs.indexOf(first), nx = logs[fi + 1];
      const sw = nx && nx.topics[0] === SWAP_TOPIC && nx.transactionHash === first.transactionHash ? nx : null;
      if (sw) { r0 = r0 - big(sw.data, 0) + big(sw.data, 2); r1 = r1 - big(sw.data, 1) + big(sw.data, 3); }
      before = p._bdagIs0 ? priceOf(r0, r1, p.decimals) : priceOf(r1, r0, p.decimals);
    }
    for (const l of logs) if (l.topics[0] === SWAP_TOPIC) { swaps++; vol += p._bdagIs0 ? big(l.data, 0) + big(l.data, 2) : big(l.data, 1) + big(l.data, 3); }
    const change = now && before ? (now / before - 1) * 100 : null;
    return { pair: p.pair, token: p.token, symbol: p.symbol, name: p.name, priceBDAG: now, price24hAgoBDAG: before,
      change24hPct: change === null ? null : Math.round(change * 100) / 100, volume24hBDAG: units(vol, 18), swaps24h: swaps,
      liquidityBDAG: p.liquidityBDAG, newPool: fresh.has(p.pair.toLowerCase()), swap: p.swap };
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

const json = (body, status = 200, maxAge = 60) => new Response(JSON.stringify(body), { status, headers: {
  "content-type": "application/json; charset=utf-8", "access-control-allow-origin": "*", "cache-control": `public, max-age=${maxAge}` } });
const clean = ({ _bdagIs0, ...rest }) => rest;

// Builds one answer from the chain. Throws when the chain can't be read.
async function build(parts) {
  if (parts[0] === "tickers" && parts.length === 1) {
    const pools = await readPairs();
    return { kind: "tickers", body: { chainId: 1404, quote: "BDAG", updated: new Date().toISOString(), tickers: await tickers(pools) } };
  }
  if (parts[0] !== "pairs" || parts.length > 2) return null;
  const pools = await readPairs();
  if (parts.length === 1) return { kind: "pairs", body: { chainId: 1404, quote: "BDAG", updated: new Date().toISOString(), pairs: pools.map(clean) } };
  const want = ALIASES[parts[1]] || parts[1];
  const p = pools.find((x) => x.token === want || x.pair.toLowerCase() === want);
  if (!p) return { kind: "pairs", status: 404, body: { error: "no BDAG pool on Reef for that token or pool address" } };
  return { kind: "pairs", body: { chainId: 1404, quote: "BDAG", updated: new Date().toISOString(), ...clean(p), ...(await volume24h(p)) } };
}

// Stored copies carry the time they were made, and are kept for KEEP_SECONDS so a stale copy can be served.
async function store(cache, key, made, built) {
  const text = JSON.stringify(built.body);
  await cache.put(key, new Response(text, { status: built.status || 200, headers: {
    "content-type": "application/json; charset=utf-8", "cache-control": `public, max-age=${KEEP_SECONDS}`, "x-made": String(made), "x-kind": built.kind } }));
  return text;
}
const refreshing = new Set(); // one background refresh per answer per isolate

export async function onRequestGet(ctx) {
  const cache = caches.default;
  const url = new URL(ctx.request.url);
  const parts = (ctx.params.route || []).map((s) => s.toLowerCase());
  // One cache key per answer: query strings (cache-busters) don't force a fresh read of the chain.
  const key = new Request(url.origin + "/api/v1/" + parts.join("/"));
  const now = Math.floor(Date.now() / 1000);
  const hit = await cache.match(key);
  if (hit) {
    const made = Number(hit.headers.get("x-made")) || 0, kind = hit.headers.get("x-kind") || "pairs";
    const fresh = FRESH_SECONDS[kind] || 120, age = now - made;
    if (age >= fresh && !refreshing.has(key.url)) {
      // Serve the stored copy now; refresh it after the response is sent. If the refresh fails or runs out of CPU,
      // the stored copy simply stays in place.
      refreshing.add(key.url);
      ctx.waitUntil(build(parts).then((b) => b && store(cache, key, Math.floor(Date.now() / 1000), b)).catch(() => {}).finally(() => refreshing.delete(key.url)));
    }
    const body = await hit.text();
    return new Response(body, { status: hit.status, headers: { "content-type": "application/json; charset=utf-8", "access-control-allow-origin": "*",
      "cache-control": `public, max-age=${Math.max(30, Math.min(fresh, fresh - age))}` } });
  }
  let built;
  try {
    built = await build(parts);
  } catch (e) {
    return json({ error: "couldn't read the chain just now; try again shortly" }, 503, 0); // not stored
  }
  if (!built) return json({ error: "not found", endpoints: ["/api/v1/pairs", "/api/v1/pairs/{token|pool address, or reef|nocap|cooked}", "/api/v1/tickers"], docs: "https://reefdex.fyi/developers/" }, 404, 3600);
  const text = await store(cache, key, now, built).catch(() => JSON.stringify(built.body));
  return new Response(text, { status: built.status || 200, headers: { "content-type": "application/json; charset=utf-8", "access-control-allow-origin": "*",
    "cache-control": `public, max-age=${FRESH_SECONDS[built.kind] || 120}` } });
}

export function onRequestOptions() {
  return new Response(null, { headers: { "access-control-allow-origin": "*", "access-control-allow-methods": "GET, OPTIONS", "access-control-max-age": "86400" } });
}
