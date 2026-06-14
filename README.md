# ConfessFi — Anonymous Confessions, Natively on Arc

ConfessFi is a fully on-chain, anonymous confession board built **natively for Arc
Testnet** (Chain ID `5042002`). Your wallet is your identity — no usernames, no
sign-up, no backend, no database. Every confession, vote, comment and fact-check is a
transaction, and every fee flows through an on-chain revenue-split engine.

- **Live app:** _add your Vercel link here_
- **Contract (Arc Testnet):** [`0x1d891C7ce9428171016Ed8a203E82E7BECEA53e6`](https://testnet.arcscan.app/address/0x1d891C7ce9428171016Ed8a203E82E7BECEA53e6)
- **Chain ID:** `5042002` · **Explorer:** https://testnet.arcscan.app

## Why this is built *for* Arc

ConfessFi leans into Arc's defining property: **USDC is the native gas coin (18 decimals)**.

- **Native-fee model, no ERC-20 approvals.** Fees are paid as native USDC via
  `msg.value`, the same way you'd send ETH on Ethereum. There is no `approve` +
  `transferFrom` dance — one signature per action. This is the idiomatic Arc pattern
  and gives users a single, clean transaction every time.
- **Arc-safe payouts.** Because sending native value to contracts on Arc has special
  rules, the revenue split uses a **pull-payment** pattern (`earnings` ledger +
  `withdrawEarnings`) instead of pushing funds, avoiding forbidden-transfer reverts.
- **Deterministic weekly settlement.** Arc's instant finality means the weekly prize
  distribution can act on a single confirmation.

## Economy

| Action              | Fee (native USDC) |
| ------------------- | ----------------- |
| Create confession   | 0.20              |
| Upvote / Downvote   | 0.10              |
| Comment             | 0.05 (max 3 / wallet / confession) |
| Fact check (Real/Fake) | 0.10           |

Every action splits **70%** to the weekly prize pool, **20%** to the confession
creator (instant earnings), and **10%** to the platform treasury.

## Leaderboard & settlement

Ranking score = `unique upvotes − unique downvotes − unique fake votes`. Unique-voter
tracking per action type prevents a single wallet from pumping or dumping a score.
"Fake" fact-check votes drag a confession down the board. Each week
`distributeWeeklyRewards()` pays the top 3 positive-score confessions (50% / 30% /
20%); if none qualify, the pool rolls over.

## Moderation (on-chain admin)

No passwords. The contract `owner` (deploying wallet) is recognised automatically by
the frontend and can hide/unhide any confession through the `onlyOwner`
`toggleConfessionVisibility` function.

## Stack

- **Frontend:** single static `index.html` — Ethers v6 + Web3Modal via CDN, no build step.
- **Contract:** `contract/src/ConfessFi.sol` — Solidity `^0.8.24`, OpenZeppelin
  `Ownable` + `ReentrancyGuard`, native-USDC fees.
- **Tooling:** Foundry (`contract/foundry.toml`, `contract/script/Deploy.s.sol`).

## Run locally

Browser wallets don't inject into `file://` pages, so serve over http:

```bash
python3 -m http.server 8000
# open http://localhost:8000
```

## Deploy the contract (Foundry)

```bash
cd contract
forge install foundry-rs/forge-std
forge install OpenZeppelin/openzeppelin-contracts
cp .env.example .env   # fill PRIVATE_KEY (testnet) + TREASURY_ADDRESS
source .env
forge script script/Deploy.s.sol:DeployScript --rpc-url arc_testnet --broadcast
```

Then paste the deployed address into the `CONFESSFI` constant in `index.html`.

## Security

- Testnet only — Arc has no mainnet yet; do not use real funds.
- Secrets are never committed. The deploy key lives in `contract/.env`, which is
  gitignored. Only `contract/.env.example` (no secrets) is published.
