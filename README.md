# Insurance Claims Smart Contract

A minimal on-chain insurance pool in Solidity, with the full claim lifecycle and the guarantees a policyholder would want enforced by code rather than by trust.

`src/ClaimsPool.sol` · tests in `test/ClaimsPool.t.sol` (Foundry, including a fuzz test).

## Lifecycle

1. **Fund:** the insurer deploys the pool with a reserve; anyone can add to it.
2. **Verify:** the insurer marks customers as verified (KYC done off-chain).
3. **Buy cover:** a verified customer pays a premium of `premiumBps` × coverage and gets cover for `term` seconds. One active policy per customer.
4. **File a claim:** against an active policy, for at most the remaining cover.
5. **Decide:** the insurer approves or rejects. Approval re-checks the remaining cover, since several claims can be pending at once, and the free reserve.
6. **Withdraw:** the customer pulls the approved amount.

## Guarantees enforced by the contract

| Property | How |
|---|---|
| Payouts never exceed cover | remaining cover checked at filing and again at approval |
| The pool stays solvent | approval needs `balance − owed ≥ amount`; `owed` tracks approved, unwithdrawn payouts |
| The insurer cannot take money owed to customers | `withdrawSurplus` is limited to `balance − owed` |
| A failing or malicious receiver cannot block the pool | pull payments; state updated before the transfer (checks-effects-interactions) |
| Only the insurer verifies and decides | `onlyInsurer` modifier |
| Clear failure reasons | custom errors with the values that failed (`ExceedsCoverage(remaining, requested)`, …) |

## Tests

```bash
forge test -vv
```

Twelve unit tests cover the lifecycle, access control, pricing, cover limits, expiry, reserve checks and a receiver that rejects ether. A fuzz test (1,000 runs) draws random cover and claim sizes and asserts that total payouts stay within cover and the pool stays solvent. The tests use Foundry cheatcodes directly, with no external test library. GitHub Actions builds the contract and runs the suite with a gas report on every push.
