# @goaly/contracts

Foundry contracts for Goaly.

| Contract             | Role                                                                         |
| -------------------- | ---------------------------------------------------------------------------- |
| `GoalyVault`         | Self-custodial deposit vault; supplies USDT0 to Morpho for yield, self-repay |
| `PredictionPool`     | No-loss, yield-funded prediction markets (borrows credit via the vault)      |
| `GoalyVaultComposer` | LayerZero composer — turns a cross-chain USDT0 transfer into a vault deposit |
| `YieldMath`          | Pure self-repay math library (mirrors `@goaly/core`)                         |

## GoalyVault

- `deposit(assets)` / `depositFor(user, assets)` — supplies USDT0 into a Morpho MetaMorpho
  (ERC-4626) vault to earn yield. `depositFor` credits another address (used by the LayerZero
  composer for cross-chain deposits).
- `chargeDebt(user, amount)` — a `SETTLER_ROLE` holder (the prediction pool) records borrowed credit.
- `remainingDebt` / `principalLocked` — debt is repaid **only** by the yield the user's own principal
  earns; principal is never touched. **A player can never withdraw less than their principal.**
- OpenZeppelin `AccessControl` + `ReentrancyGuard` + `Pausable` + `SafeERC20`.

## Cross-chain deposits (LayerZero V2)

`GoalyVaultComposer` implements LayerZero's `ILayerZeroComposer`. A user on any chain sends USDT0 via
its **OFT** to Arbitrum, targeting the composer with a compose message carrying their hub address:

```
USDT0 (any chain) --OFT.send--> Arbitrum: USDT0 OFT delivers tokens to composer
                                         + Endpoint calls composer.lzCompose(...)
composer decodes amountLD + recipient (OFTComposeMsgCodec) --> vault.depositFor(recipient, amount)
```

Uses the official packages `@layerzerolabs/lz-evm-protocol-v2` (interface) and `@layerzerolabs/oft-evm`
(compose codec). `lzCompose` is guarded to the LayerZero Endpoint and the expected USDT0 OFT. Endpoint
and OFT addresses per chain come from LayerZero's Endpoint Metadata; wire peers with a `layerzero.config`.

## Setup

```bash
bun install                   # LayerZero packages (node_modules) used via foundry remappings
forge install                 # forge-std + openzeppelin-contracts (git submodules)
bun run --filter @goaly/contracts build
bun run --filter @goaly/contracts test              # unit tests (mocks) — 21 tests
ARBITRUM_RPC_URL=... bun run --filter @goaly/contracts test:integration   # Morpho fork test
```

## Testing

- **Unit** — `GoalyVault.t.sol`, `PredictionPool.t.sol`, `GoalyVaultComposer.t.sol`, `YieldMath.t.sol`
  against `MockERC20` + `MockERC4626` (yield simulated via `accrue`, cross-chain compose simulated
  with an encoded OFT message + mocked endpoint).
- **Fork** — `test/fork/MorphoFork.t.sol` deposits real USDT0 into the real Morpho Gauntlet USDT0 Core
  vault on Arbitrum. No-ops unless `ARBITRUM_RPC_URL` is set.

## Deploy

`Deploy.s.sol` deploys and wires the whole system (GoalyVault + PredictionPool + GoalyVaultComposer,
granting the pool `SETTLER_ROLE`):

```bash
WALLET_PK=0x... forge script script/Deploy.s.sol:Deploy --rpc-url arbitrum --broadcast
```

Uses the Morpho Gauntlet USDT0 Core vault and the canonical LayerZero V2 Endpoint by default;
override `LZ_ENDPOINT` / `USDT0_OFT` via env if needed.

## Roadmap

- Add a `layerzero.config` to enforce OFT peers/DVNs for the cross-chain path.
- Optional: full LayerZero **OVault** (omnichain vault shares) so positions themselves are cross-chain.
