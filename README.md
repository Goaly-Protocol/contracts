# @goalyield/contracts

Foundry contracts for GoalYield. The centerpiece is **`GoalYieldVault`** — the on-chain yield +
self-repay engine.

## GoalYieldVault

- `deposit(assets)` — supplies USDT0 into a Morpho MetaMorpho (ERC-4626) vault to earn yield.
- `chargeDebt(user, amount)` — a settler (the prediction pool) records borrowed prediction credit.
- `remainingDebt` / `principalLocked` — debt is repaid **only** by the yield the user's own
  principal earns; principal is never touched.
- `withdraw()` — returns the user's principal once yield has cleared the debt. Accrued yield stays
  with the protocol (`skim`), which is what funds the game. **A player can never withdraw less than
  their principal.**

## Setup

```bash
forge install                 # fetches forge-std (git submodule under lib/)
bun run --filter @goalyield/contracts build
bun run --filter @goalyield/contracts test              # unit tests (mocks)
ARBITRUM_RPC_URL=... bun run --filter @goalyield/contracts test:integration   # fork test
```

## Testing

- **Unit** (`test/GoalYieldVault.t.sol`) — full deposit → charge debt → yield → self-repay →
  withdraw flow against `MockERC20` + `MockERC4626` (yield simulated via `accrue`).
- **Fork** (`test/fork/MorphoFork.t.sol`) — deposits real USDT0 into the real Morpho Gauntlet USDT0
  Core vault on Arbitrum. No-ops unless `ARBITRUM_RPC_URL` is set.

## Roadmap

- `PredictionPool` (markets, pot escrow) currently lives off-chain in `apps/api`; moving it on-chain
  is the next step. Cross-chain deposits will use LayerZero **OVault** (OFT + ERC-4626).
