# Deployments

## Arbitrum One (chainId 42161)

The layered v2 protocol, deployed behind UUPS proxies and verified on Arbiscan.

| Contract | Address |
| --- | --- |
| **GoalyVault** (proxy) | [`0xFe424b5b85C742C15CCB09d62873bE72577CD7Ef`](https://arbiscan.io/address/0xFe424b5b85C742C15CCB09d62873bE72577CD7Ef) |
| **GoalyMarkets** (proxy) | [`0xFAcaD2Cbc3b6320239389aD5c2F597DeE95f1fd3`](https://arbiscan.io/address/0xFAcaD2Cbc3b6320239389aD5c2F597DeE95f1fd3) |
| **GoalySettlement** | [`0xC03BB9526D6F0308d8Ba0831e85f93db3E45e201`](https://arbiscan.io/address/0xC03BB9526D6F0308d8Ba0831e85f93db3E45e201) |
| **MorphoStrategy** | [`0x6951adCCd2106Bf364D62A1CC328070FC49609eA`](https://arbiscan.io/address/0x6951adCCd2106Bf364D62A1CC328070FC49609eA) |
| **AllocationLib** (library) | [`0x00d25e8c7ab0e42e29e21ed40592d10b2389ded2`](https://arbiscan.io/address/0x00d25e8c7ab0e42e29e21ed40592d10b2389ded2) |
| GoalyVault impl | [`0x37612b385db08923db0207ddd9b9bf428caa3441`](https://arbiscan.io/address/0x37612b385db08923db0207ddd9b9bf428caa3441) |
| GoalyMarkets impl | [`0x997cfb3121e15552d6d7efa6755a0e198442a1b6`](https://arbiscan.io/address/0x997cfb3121e15552d6d7efa6755a0e198442a1b6) |

### Configuration

- Asset: USDT0 `0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9`
- Strategy source: Steakhouse High Yield USDT0 (Morpho) `0x4739E2c293bDCD835829aA7c5d7fBdee93565D1a`
- Liquidity buffer: 15% · Protocol fee: 2.5% (prize only) · Odds boost: 50%
- Settlement bond: 10 USDT0 · dispute window: 2h
- Roles (demo, single-key): governance / oracle / agent / guardian = `0x3b4f0135465d444a5bd06ab90fc59b73916c85f5`
- `ReserveManager` not deployed — needs the USDT0 OFT adapter (Phase 5, cross-chain surplus).

Compiled **without the optimizer / via-IR** (plain, auditable bytecode); the vault fits under 24 KB by
delegating allocation logic to the external `AllocationLib`.

### Live end-to-end proof (on the verified contracts)

Market `0xedb34fad361495b1898c80d31bc6ac90da466349ce2338285f81573ac8443fe9`:

1. `settlement.openMarket` → market opened on GoalyMarkets.
2. `markets.predict` → 0.004 USDT0 staked; it flowed agent → markets → vault (shares minted).
3. `vault.allocate` → agent moved 0.0034 into the Steakhouse USDT0 Morpho strategy; 0.0006 (15%)
   stayed as the liquidity buffer.

Resulting on-chain state: `markets.totalStaked = 4000`, **`markets.isSolvent() = true`**,
`vault.totalAssets = 4000`, strategy position `= 3400`, idle buffer `= 600`. The no-loss invariant
holds live: principal fully redeemable while the stake earns yield.
