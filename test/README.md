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
- `PepeolithicPricingInvariant.t.sol` adds 128 sequences of 96 operations with
  eight buyers. A forward recurrence derives round openings from successful
  purchases; it does not reuse the application's backward lookup. Independent
  weighted knot interpolation predicts charges and burn totals. Calls mix current
  and older rounds, exact and fractional times, quiet caves, sold-out rounds,
  false/reverting payments, and allowances one wei short. Current, successor,
  sampled and final-round prices are checked after each call; every round is
  checked at the end. A deterministic sequence requires successful line and floor
  sales and rejected purchases, and 1,000 fuzz cases check curve interiors.
- `PepeolithicSettlement.t.sol` adds an adversarial payment dependency. A nested
  purchase succeeds before the outer payment returns false, reverts, or returns
  empty, short, or non-boolean ABI data. Both sales and leftovers must roll back
  ownership, inventory, ladder state, balances and allowances, then succeed when
  retried with a true return. Cross-function callbacks exercise claims, sweeps and
  authorized NFT transfers. Caught nested exhaustion must leave the paid outer
  purchase intact, including at the final free piece.

The added pricing properties follow these rules from the assignment: each round's
first successful buy fixes its opening; only the last successful sale strictly
above the floor affects its successor; quiet rounds halve; openings stay at least
twice the floor. Each price line interpolates between halving knots, rounds the
integer charge upward, and clamps to the floor. The first mainnet line reaches
the floor at second 3,456, so a purchase there is already a floor sale even though
the 3,600-second round has not finished. Older unsold rounds keep their own prices.

The payment properties require atomic transactions: a failed outer payment must
undo nested minting, claims, transfers and sweep cursor changes as well as its own
effects. A successful callback can act on the already-minted NFT with the owner's
approval; a completed buy must not overwrite those changes. These dependency
callbacks are tests of the external coin boundary, not ERC-721 receiver callbacks
or a claim that production ZTO implements callbacks. The adversarial coin still
checks balances and allowances and performs real local balance transfers.

The additions use the supplied Pashov fizz and Trail of Bits property-testing
guides for ghost accounting, independent oracles, bounded inputs and non-vacuous
failure checks. They add no dependencies and do not change production storage,
source or configuration. Run either added suite with `forge test --match-contract
PepeolithicPricingInvariantTest` or `forge test --match-contract PepeolithicSettlementTest`.

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
