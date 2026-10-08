# Pepeolithic tests

Run `forge build`, `forge test`, `forge fmt --check`, and
`python3 script/check_launch.py` from the repository root.

The suites adapt the pinned launch-928 tests, preserving their behavioral checks:

- `Pepeolithic.t.sol` checks deployment in an empty EVM, every piece, every sale
  allocation, all 335 claims, 737-piece completion, payment errors and reentry,
  price knots, ladder changes, timing, sweeps, release, metadata, royalties, ERC-721
  transfers and events. Its arithmetic fixtures use short configurable durations
  and small prices; the fixed-deployment test uses all actual mainnet arguments.
- `PepeolithicProperties.t.sol` uses the mainnet day/hour and 1e24/1e22 defaults.
  It fuzzes configurable curves, boundaries, royalty rounding and payment amounts
  (1,000 runs per property). It also buys all 147 rounds at their opening price,
  exercising the maximum reachable mainnet ladder and exact geometric payment sum.
- `PepeolithicInvariant.t.sol` runs 256 sequences of 128 operations with eight
  actors and separate Adam/admin addresses. Independent inventory queues come
  from the quota table. Ghost accounting tracks ownership, supply, balances,
  sales, claims, payments, metadata freezing and seat release. Each sequence
  finishes by issuing all remaining inventory and verifying every owner.

Successful seat tests construct local single-address-hash, sorted-pair Merkle trees.
The production root is checked as a constructor value; its complete membership and
proofs were not supplied. Test-only identities, roots, prices and balances never
enter `launch.json`. The mock coin is installed at the supplied ZTO address only
in the local EVM. Tests neither fork nor read/set environment variables, and use no
FFI, filesystem permissions, wallet keys or broadcast.

The offline manifest check validates all sixteen arguments against the compiled
ABI and supplied values, all seven label encodings, runtime size, forbidden opcodes,
absence of unlinked libraries, and normalized source equivalence to the pinned
reference. It uses only Python's standard library.

No-custody assertions cover implemented payment flows, not unsolicited transfers.
The deployment service is responsible for checking live ZTO behavior, production
proof distribution, chain selection and deployment.
