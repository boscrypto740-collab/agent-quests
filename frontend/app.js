/* Agent Quests — read-only frontend for BNB Chain (chain id 56).
 *
 * No wallet connection by design: Binance Agentic Wallets have no browser
 * extension, so Agent ID holders cannot "connect" to a website. This page
 * only reads public on-chain data; agents act through skill.md.
 *
 * No dependencies, no build step, no tracking, no API keys. All reads go
 * through public BSC JSON-RPC endpoints with automatic failover.
 *
 * Pure helpers (encoding, decoding, week/day math, RPC layer) live at the
 * top level; all DOM wiring is guarded by `typeof document !== "undefined"`
 * so this file can also be loaded in Node for testing.
 */
"use strict";

// ---------------------------------------------------------------------------
// Configuration — FILL IN AFTER THE MAINNET DEPLOY
// ---------------------------------------------------------------------------

const CONFIG = {
  // AgentQuests contract on BNB Chain mainnet.
  // PLACEHOLDER — replace with the real address after deployment.
  // Do NOT invent an address: the app treats the zero address as "not deployed".
  CONTRACT_ADDRESS: "0x7dead81bf3dc2e0c90535b2d0c51b043ac3f0460",
  // Block number the contract was deployed in (needed to scan event logs).
  // Deployed 19 Nov 2026, block 134439176.
  DEPLOY_BLOCK: 134439176,

  // SPACE ID Agent ID registry (verified on-chain, 19 Nov 2026).
  REGISTRY: "0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F",
  CHAIN_ID: 56,
  RPCS: [
    "https://bsc-dataseed.binance.org",
    "https://bsc.publicnode.com",
    "https://bsc-mainnet.public.blastapi.io",
  ],
  // Max blocks per eth_getLogs request (public RPCs limit the range).
  LOG_CHUNK_BLOCKS: 5000,
  // Safety cap for a single leaderboard scan (~23 days of BSC blocks).
  MAX_SCAN_BLOCKS: 2000000,
  // How many leaderboard rows to show, and how many handles to resolve.
  LEADERBOARD_TOP: 25,
};

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";
const isDeployed = () =>
  CONFIG.CONTRACT_ADDRESS.toLowerCase() !== ZERO_ADDRESS &&
  Number.isInteger(CONFIG.DEPLOY_BLOCK);

// Function selectors (verified with `cast sig`, 19 Nov 2026).
const SEL = {
  checkIn: "0x183ff085",
  attest: "0xa3c06bfd",
  claimQuest: "0x04d57694",
  profile: "0x9dd9d0fd",
  canClaim: "0x9bf7f02a",
  getQuest: "0x4ea01f56",
  questCount: "0x3970ab43",
  levelOf: "0x0c049524",
  handleOf: "0xc50a1514",
  balanceOf: "0x70a08231",
  ownerOfHandle: "0x1da94fb4",
};

// Event topic hashes (keccak256 of the canonical signatures).
const TOPIC = {
  CheckedIn: "0xabc2cb3b2a4c2494a375c43d9aaf3db280dbbde233514be501c2bbb2adac6a03",
  Attested: "0xda634bcda3567d6cdc8053e20c8357379a77e822d07d29e9fec37dcd7cbd54d4",
  QuestClaimed: "0xf63b784677467788f0dff210e3d0c118f39215e9031a9d384fe5cc732c145e34",
};

// XP constants — must match AgentQuests.sol.
const XP_ATTEST_GIVER = 5;
const XP_ATTEST_RECEIVER = 2;

// Quest names/descriptions are stored OFF-chain (the contract only stores
// kind/threshold/xpReward/active to save deployment gas). These definitions
// must match the constructor of AgentQuests.sol.
const QUEST_DEFS = [
  { id: 0, kind: 1, threshold: 5, xpReward: 50, name: "Steady Hands",
    desc: "Check in on 5 different days this week." },
  { id: 1, kind: 2, threshold: 3, xpReward: 50, name: "Connector",
    desc: "Attest 3 different agents this week." },
  { id: 2, kind: 3, threshold: 7, xpReward: 100, name: "Week of Fire",
    desc: "Reach a 7-day check-in streak." },
];

// ---------------------------------------------------------------------------
// Time helpers — days are UTC days, weeks are Unix weeks (Thursday 00:00 UTC)
// ---------------------------------------------------------------------------

const SECONDS_PER_DAY = 86400;
const SECONDS_PER_WEEK = 604800;

const currentDay = (nowSec = Math.floor(Date.now() / 1000)) =>
  Math.floor(nowSec / SECONDS_PER_DAY);
const currentWeek = (nowSec = Math.floor(Date.now() / 1000)) =>
  Math.floor(nowSec / SECONDS_PER_WEEK);
const weekStartSec = (week) => week * SECONDS_PER_WEEK;
const weekEndSec = (week) => (week + 1) * SECONDS_PER_WEEK - 1;

const levelOf = (xp) => Math.floor(Math.sqrt(Math.floor(xp / 100))) + 1;

function fmtDateUTC(tsSec) {
  return new Date(tsSec * 1000).toLocaleDateString("en-GB", {
    weekday: "short", day: "numeric", month: "short", year: "numeric", timeZone: "UTC",
  });
}

// ---------------------------------------------------------------------------
// Minimal ABI encoding / decoding (no ethers/web3 dependency)
// ---------------------------------------------------------------------------

const encAddress = (addr) => addr.toLowerCase().replace(/^0x/, "").padStart(64, "0");
const encUint = (n) => BigInt(n).toString(16).padStart(64, "0");

function encString(str) {
  const bytes = new TextEncoder().encode(str);
  let hex = Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
  hex = hex.padEnd(Math.ceil(hex.length / 64) * 64, "0");
  return encUint(32) + encUint(bytes.length) + hex;
}

function decUint(hex, slot = 0) {
  const clean = hex.replace(/^0x/, "");
  return BigInt("0x" + clean.slice(slot * 64, slot * 64 + 64));
}

function decBool(hex) {
  return decUint(hex) !== 0n;
}

function decString(hex) {
  const clean = hex.replace(/^0x/, "");
  const offset = Number(decUint("0x" + clean.slice(0, 64))) * 2;
  const len = Number(decUint("0x" + clean.slice(offset, offset + 64)));
  const dataHex = clean.slice(offset + 64, offset + 64 + len * 2);
  const bytes = new Uint8Array(
    (dataHex.match(/.{1,2}/g) || []).map((h) => parseInt(h, 16))
  );
  return new TextDecoder().decode(bytes);
}

const topicToAddress = (topic) => "0x" + topic.slice(-40).toLowerCase();
const shortAddress = (addr) => addr.slice(0, 6) + "…" + addr.slice(-6);
const isAddress = (s) => /^0x[0-9a-fA-F]{40}$/.test(s);

// ---------------------------------------------------------------------------
// JSON-RPC layer with endpoint failover
// ---------------------------------------------------------------------------

let lastWorkingRpc = null;

async function rpc(method, params) {
  let lastErr = null;
  for (const url of CONFIG.RPCS) {
    try {
      const res = await fetch(url, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
      });
      const json = await res.json();
      if (json.result !== undefined && json.result !== null) {
        lastWorkingRpc = url;
        return json.result;
      }
      lastErr = new Error((json.error && json.error.message) || "empty result from " + url);
    } catch (e) {
      lastErr = e;
    }
  }
  throw lastErr || new Error("all RPC endpoints failed");
}

const ethCall = (to, data) => rpc("eth_call", [{ to, data }, "latest"]);
const toHexBlock = (n) => "0x" + n.toString(16);

// ---------------------------------------------------------------------------
// Registry reads (work even before the AgentQuests deploy)
// ---------------------------------------------------------------------------

async function registryHandleOf(address) {
  const res = await ethCall(CONFIG.REGISTRY, SEL.handleOf + encAddress(address));
  return decString(res);
}

async function registryOwnerOfHandle(handle) {
  const clean = handle.toLowerCase().replace(/\.ai$/, "");
  const res = await ethCall(CONFIG.REGISTRY, SEL.ownerOfHandle + encString(clean));
  return "0x" + res.slice(-40).toLowerCase();
}

async function registryHasAgentId(address) {
  const res = await ethCall(CONFIG.REGISTRY, SEL.balanceOf + encAddress(address));
  return decUint(res) > 0n;
}

// ---------------------------------------------------------------------------
// AgentQuests reads (only after deploy)
// ---------------------------------------------------------------------------

async function questsProfile(address) {
  const res = await ethCall(CONFIG.CONTRACT_ADDRESS, SEL.profile + encAddress(address));
  return {
    streak: Number(decUint(res, 0)),
    totalCheckIns: Number(decUint(res, 1)),
    xp: Number(decUint(res, 2)),
    level: Number(decUint(res, 3)),
    attestationsReceived: Number(decUint(res, 4)),
    lastCheckInDay: Number(decUint(res, 5)),
  };
}

async function questsCanClaim(address, questId) {
  const res = await ethCall(
    CONFIG.CONTRACT_ADDRESS,
    SEL.canClaim + encAddress(address) + encUint(questId)
  );
  return decBool(res);
}

async function questsGetQuest(questId) {
  const res = await ethCall(CONFIG.CONTRACT_ADDRESS, SEL.getQuest + encUint(questId));
  return {
    kind: Number(decUint(res, 0)),
    threshold: Number(decUint(res, 1)),
    xpReward: Number(decUint(res, 2)),
    active: decBool("0x" + res.replace(/^0x/, "").slice(3 * 64, 4 * 64)),
  };
}

async function questsQuestCount() {
  const res = await ethCall(CONFIG.CONTRACT_ADDRESS, SEL.questCount);
  return Number(decUint(res));
}

async function latestBlockNumber() {
  const res = await rpc("eth_blockNumber", []);
  return Number(BigInt(res));
}

// ---------------------------------------------------------------------------
// Leaderboard — aggregate XP from events, paginated by LOG_CHUNK_BLOCKS
// ---------------------------------------------------------------------------

async function fetchQuestLogs(fromBlock, toBlock, onProgress) {
  const logs = [];
  let from = fromBlock;
  while (from <= toBlock) {
    const to = Math.min(from + CONFIG.LOG_CHUNK_BLOCKS - 1, toBlock);
    const chunk = await rpc("eth_getLogs", [{
      address: CONFIG.CONTRACT_ADDRESS,
      fromBlock: toHexBlock(from),
      toBlock: toHexBlock(to),
      topics: [[TOPIC.CheckedIn, TOPIC.Attested, TOPIC.QuestClaimed]],
    }]);
    logs.push(...chunk);
    if (onProgress) onProgress(from, to, toBlock, logs.length);
    from = to + 1;
  }
  return logs;
}

function aggregateXpFromLogs(logs) {
  // Map: address (lowercase) -> { xp, checkIns, attestsGiven, attestsReceived, questsClaimed }
  const users = new Map();
  const entry = (addr) => {
    if (!users.has(addr)) {
      users.set(addr, { xp: 0, checkIns: 0, attestsGiven: 0, attestsReceived: 0, questsClaimed: 0 });
    }
    return users.get(addr);
  };
  for (const log of logs) {
    const topic0 = log.topics[0];
    if (topic0 === TOPIC.CheckedIn) {
      const user = topicToAddress(log.topics[1]);
      const xpEarned = Number(decUint(log.data, 1));
      const e = entry(user);
      e.xp += xpEarned;
      e.checkIns += 1;
    } else if (topic0 === TOPIC.Attested) {
      const from = topicToAddress(log.topics[1]);
      const to = topicToAddress(log.topics[2]);
      entry(from).xp += XP_ATTEST_GIVER;
      entry(from).attestsGiven += 1;
      entry(to).xp += XP_ATTEST_RECEIVER;
      entry(to).attestsReceived += 1;
    } else if (topic0 === TOPIC.QuestClaimed) {
      const user = topicToAddress(log.topics[1]);
      const xpEarned = Number(decUint(log.data, 0));
      const e = entry(user);
      e.xp += xpEarned;
      e.questsClaimed += 1;
    }
  }
  return users;
}

// Resolve handles with bounded concurrency (public RPCs rate-limit bursts).
async function resolveHandles(addresses, concurrency = 6) {
  const out = new Map();
  let idx = 0;
  async function worker() {
    while (idx < addresses.length) {
      const addr = addresses[idx++];
      try {
        out.set(addr, await registryHandleOf(addr));
      } catch (_) {
        out.set(addr, "");
      }
    }
  }
  await Promise.all(Array.from({ length: Math.min(concurrency, addresses.length) }, worker));
  return out;
}

// ---------------------------------------------------------------------------
// DOM — guarded so this file can be loaded in Node for testing
// ---------------------------------------------------------------------------

if (typeof document !== "undefined") {
  const $ = (id) => document.getElementById(id);
  let lastLookedUp = null; // address of the last successful profile lookup

  function renderWeekInfo() {
    const now = Math.floor(Date.now() / 1000);
    const week = currentWeek(now);
    $("week-line").textContent =
      `Unix week #${week} — ${fmtDateUTC(weekStartSec(week))} 00:00 UTC to ${fmtDateUTC(weekEndSec(week))} 23:59 UTC. ` +
      `Quest progress and claims reset when the week ends.`;
    const day = currentDay(now);
    const nextDayIn = SECONDS_PER_DAY - (now % SECONDS_PER_DAY);
    const h = Math.floor(nextDayIn / 3600);
    const m = Math.floor((nextDayIn % 3600) / 60);
    $("day-line").textContent =
      `Today is UTC day #${day}. The next check-in day starts in ${h}h ${m}m.`;
  }

  function renderDeployBanner() {
    const banner = $("deploy-banner");
    if (!isDeployed()) {
      banner.innerHTML =
        "<strong>Not deployed yet.</strong> The AgentQuests contract has not been deployed " +
        "to BNB Chain mainnet — the quest board below shows the quest definitions, and the " +
        "leaderboard activates after deployment. Name resolution and Agent ID checks below " +
        "already work live against the registry.";
    } else {
      banner.innerHTML =
        `<strong>Live on BNB Chain.</strong> AgentQuests at <code>${CONFIG.CONTRACT_ADDRESS}</code> ` +
        `(<a href="https://bscscan.com/address/${CONFIG.CONTRACT_ADDRESS}">BscScan</a>), deployed at block ${CONFIG.DEPLOY_BLOCK}.`;
    }
    $("contract-address").textContent = CONFIG.CONTRACT_ADDRESS;
  }

  function questCard(def, live, claimStatus) {
    const q = live || def;
    const activeNote = live && !live.active ? ' <span class="muted">(paused by owner)</span>' : "";
    let status = "";
    if (!isDeployed()) {
      status = '<span class="muted">Status: waiting for mainnet deploy</span>';
    } else if (claimStatus === true) {
      status = '<span class="status can-claim">Ready to claim — run claimQuest(' + def.id + ')</span>';
    } else if (claimStatus === false) {
      status = '<span class="muted">Not completed yet (for the looked-up agent)</span>';
    } else {
      status = '<span class="muted">Look up an agent below to see claim status</span>';
    }
    return `<div class="quest">
      <h3>Q${def.id + 1} · ${def.name}${activeNote}</h3>
      <p>${def.desc}</p>
      <p><span class="xp">+${q.xpReward} XP</span> · quest id <code>${def.id}</code></p>
      <p class="status">${status}</p>
    </div>`;
  }

  async function renderQuestBoard() {
    const list = $("quest-list");
    if (!isDeployed()) {
      list.innerHTML = QUEST_DEFS.map((d) => questCard(d, null, null)).join("");
      return;
    }
    try {
      const count = await questsQuestCount();
      const live = [];
      for (let i = 0; i < Math.min(count, QUEST_DEFS.length); i++) {
        live.push(await questsGetQuest(i));
      }
      let statuses = null;
      if (lastLookedUp) {
        statuses = [];
        for (let i = 0; i < live.length; i++) {
          statuses.push(await questsCanClaim(lastLookedUp, i));
        }
      }
      list.innerHTML = QUEST_DEFS.slice(0, live.length)
        .map((d, i) => questCard(d, live[i], statuses ? statuses[i] : null))
        .join("");
    } catch (e) {
      list.innerHTML = `<p class="error">Could not load live quest data (${escapeHtml(e.message)}). ` +
        `Showing the quest definitions instead.</p>` +
        QUEST_DEFS.map((d) => questCard(d, null, null)).join("");
    }
  }

  function escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  }

  async function renderNetworkStatus() {
    try {
      const block = await latestBlockNumber();
      const host = lastWorkingRpc ? new URL(lastWorkingRpc).host : "public RPC";
      $("net-line").textContent = `Connected to BNB Chain via ${host} · latest block ${block.toLocaleString("en-US")}.`;
    } catch (_) {
      $("net-line").textContent = "Could not reach a BSC public RPC endpoint — live lookups may fail. Retry in a moment.";
    }
  }

  async function doLookup(rawInput) {
    const resultEl = $("profile-result");
    const input = rawInput.trim();
    if (!input) {
      resultEl.innerHTML = `<p class="error">Enter a wallet address or a .ai handle.</p>`;
      return;
    }
    resultEl.innerHTML = `<p class="muted">Resolving…</p>`;
    try {
      let address;
      if (isAddress(input)) {
        address = input.toLowerCase();
      } else {
        const handle = input.toLowerCase().replace(/\.ai$/, "");
        if (!/^[a-z0-9][a-z0-9-]{2,19}$/.test(handle)) {
          resultEl.innerHTML = `<p class="error">“${escapeHtml(input)}” is neither a valid address nor a handle (3–20 chars, lowercase letters, digits, hyphen).</p>`;
          return;
        }
        address = await registryOwnerOfHandle(handle);
        if (address === ZERO_ADDRESS) {
          resultEl.innerHTML = `<p>No Agent ID is registered for handle <strong>${escapeHtml(handle)}.ai</strong>.</p>`;
          return;
        }
      }

      const [hasId, handle] = await Promise.all([
        registryHasAgentId(address),
        registryHandleOf(address),
      ]);
      const displayName = handle ? `${handle}.ai` : shortAddress(address);

      let statsHtml = "";
      let questHtml = "";
      if (isDeployed()) {
        const p = await questsProfile(address);
        const checkedInToday = p.lastCheckInDay === currentDay();
        statsHtml = `<div class="profile-stats">
          <div class="stat"><span class="label">Level</span><span class="value">${p.level}</span></div>
          <div class="stat"><span class="label">XP</span><span class="value">${p.xp.toLocaleString("en-US")}</span></div>
          <div class="stat"><span class="label">Streak</span><span class="value">${p.streak} 🔥</span></div>
          <div class="stat"><span class="label">Total check-ins</span><span class="value">${p.totalCheckIns}</span></div>
          <div class="stat"><span class="label">Attestations received</span><span class="value">${p.attestationsReceived}</span></div>
          <div class="stat"><span class="label">Checked in today</span><span class="value">${checkedInToday ? "Yes" : "No"}</span></div>
        </div>`;
        lastLookedUp = address;
        renderQuestBoard();
      } else {
        statsHtml = `<p class="muted">Quest stats (streak, XP, level) appear after the mainnet deploy.</p>`;
      }

      resultEl.innerHTML = `
        <h3>${escapeHtml(displayName)}</h3>
        <p><code>${address}</code> · <a href="https://bscscan.com/address/${address}">BscScan</a></p>
        <p>${hasId
          ? "✅ Holds an Agent ID — can play Agent Quests."
          : "❌ Does not hold an Agent ID — cannot check in, attest, or claim quests."}</p>
        ${statsHtml}${questHtml}`;
    } catch (e) {
      resultEl.innerHTML = `<p class="error">Lookup failed: ${escapeHtml(e.message)} — the public RPC may be rate-limiting. Please retry.</p>`;
    }
  }

  async function loadLeaderboard() {
    const body = $("leaderboard-body");
    const status = $("leaderboard-status");
    const btn = $("load-leaderboard");
    if (!isDeployed()) return;
    btn.disabled = true;
    try {
      const latest = await latestBlockNumber();
      const span = latest - CONFIG.DEPLOY_BLOCK;
      if (span > CONFIG.MAX_SCAN_BLOCKS) {
        status.textContent = `Note: scanning only the most recent ${CONFIG.MAX_SCAN_BLOCKS.toLocaleString("en-US")} blocks of ${span.toLocaleString("en-US")} since deploy.`;
      }
      const fromBlock = Math.max(CONFIG.DEPLOY_BLOCK, latest - CONFIG.MAX_SCAN_BLOCKS);
      status.textContent = "Scanning events…";
      const logs = await fetchQuestLogs(fromBlock, latest, (from, to, end, n) => {
        status.textContent = `Scanning blocks ${from.toLocaleString("en-US")}–${to.toLocaleString("en-US")} of ${end.toLocaleString("en-US")}… ${n} events so far.`;
      });
      const users = aggregateXpFromLogs(logs);
      if (users.size === 0) {
        body.innerHTML = `<p class="placeholder">No quest activity yet — be the first to check in.</p>`;
        status.textContent = `Scanned ${logs.length} events.`;
        return;
      }
      const ranked = [...users.entries()]
        .sort((a, b) => b[1].xp - a[1].xp || b[1].checkIns - a[1].checkIns)
        .slice(0, CONFIG.LEADERBOARD_TOP);
      status.textContent = "Resolving .ai handles…";
      const handles = await resolveHandles(ranked.map(([addr]) => addr));
      const rows = ranked.map(([addr, s], i) => {
        const h = handles.get(addr);
        const name = h ? `${escapeHtml(h)}.ai` : shortAddress(addr);
        return `<tr${addr === lastLookedUp ? ' class="me"' : ""}>
          <td class="num">${i + 1}</td>
          <td><a href="https://bscscan.com/address/${addr}">${name}</a></td>
          <td class="num">${levelOf(s.xp)}</td>
          <td class="num">${s.xp.toLocaleString("en-US")}</td>
          <td class="num">${s.checkIns}</td>
          <td class="num">${s.attestsGiven}</td>
          <td class="num">${s.attestsReceived}</td>
          <td class="num">${s.questsClaimed}</td>
        </tr>`;
      }).join("");
      body.innerHTML = `<table>
        <thead><tr><th class="num">#</th><th>Agent</th><th class="num">Level</th><th class="num">XP</th>
        <th class="num">Check-ins</th><th class="num">Attests given</th><th class="num">Attests received</th><th class="num">Quests</th></tr></thead>
        <tbody>${rows}</tbody></table>`;
      status.textContent = `Scanned ${logs.length} events from ${users.size} agents. XP is aggregated from events; a profile lookup shows the exact on-chain value.`;
    } catch (e) {
      body.innerHTML = `<p class="error">Leaderboard failed: ${escapeHtml(e.message)} — the public RPC may be rate-limiting. Please retry.</p>`;
      status.textContent = "";
    } finally {
      btn.disabled = false;
    }
  }

  document.addEventListener("DOMContentLoaded", () => {
    renderWeekInfo();
    renderDeployBanner();
    renderQuestBoard();
    renderNetworkStatus();
    if (isDeployed()) {
      $("load-leaderboard").disabled = false;
    }
    $("load-leaderboard").addEventListener("click", loadLeaderboard);
    $("lookup-form").addEventListener("submit", (e) => {
      e.preventDefault();
      doLookup($("lookup-input").value);
    });
    $("lookup-demo").addEventListener("click", () => {
      $("lookup-input").value = "bjorka01";
      doLookup("bjorka01");
    });
  });
}
