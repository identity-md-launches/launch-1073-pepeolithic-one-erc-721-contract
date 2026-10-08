# Source and dependency provenance

The application and initial tests derive from the MIT-licensed Solidity sources in
[identity-md-launches/launch-928-ochre-one-erc-721-contract](https://github.com/identity-md-launches/launch-928-ochre-one-erc-721-contract/tree/b0923044ec165ae0a94a70ea58793153692a5a93),
commit `b0923044ec165ae0a94a70ea58793153692a5a93`.

`src/Pepeolithic.sol` matches that commit's `src/Ochre.sol` after replacing
`Ochre` with `Pepeolithic` (including its payment-interface identifier and NatSpec)
and the symbol `OCHRE` with `PEPEO`. Constructor configuration is supplied in
`launch.json`. The original source SHA-256 is
`c2976d1940899f54e3e7d54d5bdc64c15bf7d986a43eebdcf183ffb4ec61901c`.
Its whitespace-normalized SHA-256, checked offline by `script/check_launch.py`, is
`2d4e3ee8a4fa5b0ed1c5706369b8c27ef89970a6ef0a5bc5de9a8aa60c5d446e`.

The dependency files are copied unmodified from that same pinned tree:

- OpenZeppelin Contracts v5.0.2: `lib/openzeppelin-contracts/contracts/`, the
  ERC-721 and Math dependency closure; MIT license in `lib/openzeppelin-contracts/LICENSE`.
- forge-std v1.9.7: `lib/forge-std/src/`; licenses in
  `lib/forge-std/LICENSE-MIT` and `lib/forge-std/LICENSE-APACHE`.

Dependencies are ordinary files, with no submodules, package installation or network
required by the delivered build or tests. Solidity 0.8.26 is installed by the verifier.
The inherited Foundry optimizer sequence is retained to match the reference and its
literal forbidden-opcode scan.
