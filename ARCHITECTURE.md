# Goaly Protocol — Architecture

A no-loss football prediction protocol. Players stake USDT0 on match outcomes; **principal is never at
risk** — only the yield it earns funds the prizes. The system is layered so each contract has one job,
is independently auditable, and upgrades safely.

```
                 WDK — embedded wallet · multi-chain · gasless (ERC-4337)
                                   │
             stake USDT0 (any chain settles to Arbitrum)
                                   │
   ┌────────────────────────────────▼────────────────────────────────┐
   │ GoalyMarkets (UUPS)      ◄── ORACLE settles results               │  no-loss layer
   │   predict · settle · prize · claim   ·   isSolvent() invariant    │
   └────────────────────────────────┬────────────────────────────────┘
                                   │ deposit stakes / redeem 1:1
   ┌────────────────────────────────▼────────────────────────────────┐
   │ GoalyVault (ERC-4626, UUPS)   allocate · liquidity buffer         │  yield engine
   └───────────────┬───────────────────────────────┬──────────────────┘
                   ▼                                ▼
             MorphoStrategy A                 MorphoStrategy B …      same-asset USDT0 adapters
             (Morpho USDT0 vault)             (Morpho USDT0 vault)
                   ▲
                   │ allocate() / deallocate()  (bounded)
             AI Agent (WDK wallet, AGENT_ROLE)
```

## Contracts

| Contract | Responsibility |
| --- | --- |
| **GoalyMarkets** | The prediction/no-loss layer. Stakes are deposited into the vault; winners split a prize funded purely by yield. Holds the `isSolvent()` invariant. |
| **GoalyVault** | An ERC-4626 tokenized vault that pools principal and allocates it across whitelisted, same-asset strategies while keeping a **liquidity buffer** idle for on-demand claims. |
| **IStrategy / MorphoStrategy** | Pluggable yield adapters. `MorphoStrategy` is *same-asset* (USDT0 in, USDT0 out) — there is never a cross-asset swap on the way out, so no swap-slippage shortfall can strand principal. |

## Why same-asset strategies

The predecessor supplied USDT0 into a **USDC** Morpho vault (cross-asset). A withdrawal then had to buy
USDT0 back, and the swap loss meant the backing (0.999 USDC) could fall short of the 1.005 USDC needed to
redeem 1 USDT0 — **stranding principal**. Same-asset strategies remove that failure mode entirely.

## No-loss invariant

`GoalyMarkets.isSolvent()` must always hold:

```
vault.convertToAssets(vault.balanceOf(markets))  ≥  totalStaked + reserve
```

The vault only ever earns (whitelisted, audited strategies), so the position covering principal grows,
never shrinks. Claims redeem stake **1:1**; the protocol fee is taken from the *prize* only, never the
principal. Proven in `test/GoalyProtocol.t.sol` (unit + fuzz).

## Trust model (least privilege)

| Role | May do | Held by |
| --- | --- | --- |
| **AGENT_ROLE** | only `allocate` / `deallocate` between the buffer and whitelisted strategies | AI agent's WDK wallet |
| **ORACLE_ROLE** | create / settle markets, harvest yield | oracle (→ decentralised oracle in a later phase) |
| **GUARDIAN_ROLE** | `pause` (circuit breaker) | multisig |
| **DEFAULT_ADMIN** | whitelist, params, unpause, UUPS upgrades | governance: **Timelock + Safe** |

A compromised agent key **cannot** move funds to an EOA, add a strategy, or change params — the worst it
can do is shuffle principal between already-audited vaults.

## Upgradeability

Both stateful contracts are **UUPS** proxies with **ERC-7201 namespaced storage** (collision-safe across
upgrades). `_authorizeUpgrade` is gated to `DEFAULT_ADMIN` (governance). Reentrancy protection uses OZ's
transient-storage guard (EIP-1153, `evm_version = cancun` — supported on Arbitrum).

## Deploy

```bash
USDT0=0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9 \
MORPHO_USDT0_VAULT=0x... GOVERNANCE=0x... ORACLE=0x... AGENT=0x... GUARDIAN=0x... \
forge script script/DeployProtocol.s.sol --rpc-url arbitrum --broadcast
```

The script deploys both proxies + a strategy, wires the roles, then hands `DEFAULT_ADMIN` to governance
and renounces the deployer's.

## Roadmap

- **Phase 1 (this)** — layered vault + markets + one same-asset strategy, invariant-tested, UUPS + roles.
- **Phase 2** — multi-strategy allocation weights + the agent optimising them.
- **Phase 3** — decentralised settlement oracle (UMA / Chainlink).
- **Phase 4** — WDK chain-abstracted, gasless deposits.
- **Phase 5** — `ReserveManager`: deploy *surplus only* cross-chain for higher yield (principal stays home).
