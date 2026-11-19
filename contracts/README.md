# AgentQuests — Contracts

Daily on-chain quests for Agent ID (.ai) holders on BNB Chain. Independent
hackathon entry for the Agent ID Hackathon (Binance Wallet x BNB Chain).
Not affiliated with Binance or SPACE ID.

## Design

- **One contract, no dependencies** (only forge-std for tests). No token, no fees,
  no payable functions, no owner withdrawals. The owner can only manage the
  quest list and pause in an emergency.
- **forge-std is vendored** (`lib/forge-std/`, v1.17.0, src only, MIT): there
  is no git submodule, so a plain clone builds offline with no extra setup.
- **Agent ID gate:** every action requires `balanceOf(msg.sender) > 0` on the
  SPACE ID Agent ID registry (`0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F`).
  The registry is soulbound, so an Agent ID cannot be borrowed to farm quests.
- **Check-in:** once per UTC day; consecutive days build a streak, a missed day
  resets it. 10 XP + 2 XP per full 7-day streak (capped at +10).
- **Attest:** vouch for another Agent ID holder (max 3/day, 7-day cooldown per
  pair, max 140-byte reason). Giver +5 XP, receiver +2 XP.
- **Weekly quests** (Unix week, Thursday 00:00 UTC): Q1 check in 5 days (+50 XP),
  Q2 attest 3 different agents (+50 XP), Q3 reach a 7-day streak (+100 XP).
  One claim per quest per week.
- **Level:** `floor(sqrt(xp / 100)) + 1` — derived, never stored.
- **Name resolution** (`handleOf` / `ownerOfHandle`) exists on the registry and
  is verified (see `../research-name-resolution.md`), but the contract only
  uses `balanceOf` on-chain; the frontend resolves names with free `eth_call`s.
  A thin `handleOf` view passthrough is included for frontend convenience.
- **Optimizer runs = 1** (size-optimized): deployment is 1,712,235 gas
  (7,934 bytes creation bytecode) vs 2,862,329 gas at the default 200 runs. Runtime gas is
  essentially unchanged.

## Build & test

```bash
forge build
forge test            # 35 tests, all passing
forge test --gas-report
```

Tests use a mock registry etched at the real registry address with `vm.etch`,
so they run fully offline.

## Mainnet-fork end-to-end test (19 Nov 2026, verified)

```bash
anvil --fork-url https://bsc-mainnet.public.blastapi.io --port 8545
# deploy with a throwaway key, impersonate a real Agent ID holder, checkIn
```

Notes: `bsc-dataseed` 403s anvil's fork requests; `bsc.publicnode.com`
blocks archive requests without a token. BlastAPI's public endpoint works.
Do NOT use anvil's default account on a BSC fork — its mainnet nonce/state
breaks sends; use a throwaway key instead (fork-local only, never mainnet).

Fork results: deploy 1,712,235 gas; `checkIn` from the real bjorka01 wallet
(impersonated, fork-local) succeeded (79,433 gas); second same-day check-in
reverted `AlreadyCheckedIn`; check-in from an address without an Agent ID
reverted `NoAgentId`; `profile` and `handleOf` views returned correct data.

## Deploy

See `script/Deploy.s.sol`. Testnet deploys only validate mechanics (the
registry does not exist on testnet). Mainnet deploy only on the owner's
explicit go-ahead.
