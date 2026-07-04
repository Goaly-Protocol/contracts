# Goaly Protocol — Contracts

No-loss football prediction on Arbitrum. Players stake USDT0 on match outcomes; **the principal is
never at risk** — only the yield it earns funds the prizes. Built with Foundry.

## Contracts

| Contract | Role |
| --- | --- |
| **GoalyMarkets** | No-loss prediction layer — `predict` / `claim` / settle. Deposits every stake into the vault; winners split a yield-funded prize. |
| **GoalyVault** | ERC-4626 vault (UUPS) that pools principal and allocates it across whitelisted strategies, always keeping a liquidity buffer for on-demand claims. |
| **MorphoStrategy** | Same-asset yield adapter — supplies USDT0 straight into a Morpho USDT0 vault. No cross-asset swap, so no shortfall can ever strand principal. |
| **GoalySettlement** | Optimistic settlement oracle — results are proposed with a bond, finalise after a dispute window, and escalate to governance if challenged. No single trusted key. |
| **ReserveManager** | Bridges *surplus only* (prize funds, never principal) cross-chain as USDC via Circle CCTP (Wormhole-relayed). |
| **AllocationLib** | External library holding the vault's allocation logic (keeps the vault under 24 KB without the optimizer). |

## How it works

```
stake USDT0 → GoalyMarkets → GoalyVault → MorphoStrategy (Morpho, earns yield)
                                   └── 15% buffer kept idle for instant claims
```

The no-loss guarantee is an on-chain invariant, `GoalyMarkets.isSolvent()`:

```
vault.convertToAssets(vault.balanceOf(markets)) ≥ totalStaked + reserve
```

The vault only ever earns, so principal is always fully redeemable **1:1**. The protocol fee is taken
from the prize only — never the principal.

## Roles (least privilege)

- **AGENT** — may only `allocate` / `rebalance` between the buffer and whitelisted strategies (never
  transfer to an EOA). A compromised agent key cannot steal funds.
- **ORACLE / PROPOSER** — open + settle markets (via GoalySettlement).
- **GUARDIAN** — `pause` (circuit breaker).
- **DEFAULT_ADMIN** — governance (Timelock + Safe): whitelist, params, upgrades.

Upgradeable via UUPS with ERC-7201 namespaced storage. See [`ARCHITECTURE.md`](./ARCHITECTURE.md).

## Deployed (Arbitrum One)

Verified on Arbiscan — full list + a live end-to-end proof in [`DEPLOYMENTS.md`](./DEPLOYMENTS.md).

| Contract | Address |
| --- | --- |
| GoalyMarkets | `0xFAcaD2Cbc3b6320239389aD5c2F597DeE95f1fd3` |
| GoalyVault | `0xFe424b5b85C742C15CCB09d62873bE72577CD7Ef` |
| GoalySettlement | `0xC03BB9526D6F0308d8Ba0831e85f93db3E45e201` |

## Develop

```bash
forge build          # compiles plain — no optimizer, no via-IR
forge test           # 18 tests: no-loss invariant (unit + fuzz), allocation, settlement, reserve
```

## Deploy

```bash
USDT0=0x... MORPHO_USDT0_VAULT=0x... GOVERNANCE=0x... ORACLE=0x... AGENT=0x... GUARDIAN=0x... \
forge script script/DeployProtocol.s.sol --rpc-url arbitrum --broadcast
```

Deploys both proxies + a strategy behind UUPS, wires the roles, and hands `DEFAULT_ADMIN` to governance.
