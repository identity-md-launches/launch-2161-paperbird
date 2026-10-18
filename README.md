# paperbird (PAPERBIR)

A fixed-supply ERC-20 token for the paperbird project, built for an IMD custom-token launch on
Ethereum (chain id 1).

- Website: paperbird.lol
- X: x.com/paperbird_lol
- Frontend: a flappy-bird inspired site (off-chain; not part of this repository)

## What the token is

| Property        | Value                                                      |
| --------------- | ---------------------------------------------------------- |
| Solidity name   | `PaperbirdToken` (`src/PaperbirdToken.sol`)                |
| `name()`        | `paperbird`                                                |
| `symbol()`      | `PAPERBIR`                                                 |
| `decimals()`    | 18                                                         |
| Total supply    | 1,000,000,000 PAPERBIR = `1000000000000000000000000000` minor units |
| Minting         | Once, in the constructor, all of it to the deployer (`msg.sender`) |
| Constructor     | No arguments; calls no other contract                      |
| Admin powers    | None. No owner, no pause, no blocklist, no fee, no upgrade |
| Extras          | ERC-2612 `permit`, `burn`, `burnFrom` (OpenZeppelin v5.4.0) |

The supply can never grow: there is no mint function and no owner. It can shrink, because holders may
burn their own tokens, and anyone with an ERC-20 allowance may burn from the account that granted it.
Every transfer moves exactly the amount sent, from and to any address, with no exemptions needed,
which is what the launch flows (factory to distributor, distributor to claimants, pool seed, swaps
through the Uniswap v4 PoolManager) require.

## How it was built

- `src/PaperbirdToken.sol` inherits OpenZeppelin `ERC20`, `ERC20Burnable` and `ERC20Permit`.
- Dependencies are vendored as ordinary files under `lib/` (no git submodules):
  - `lib/openzeppelin-contracts` = OpenZeppelin Contracts v5.4.0 (`contracts/` only)
  - `lib/forge-std` = forge-std v1.9.7 (`src/` only)
- `foundry.toml` pins `solc = "0.8.26"`, `evm_version = "cancun"`, optimizer on with 200 runs, and
  `bytecode_hash = "none"` so the built bytecode is reproducible for the launch. `ffi` is off and
  no filesystem permissions are granted.

Named constants (there are no open numbers in the brief; these restate it):

| Constant         | Value                                 | Where                    |
| ---------------- | ------------------------------------- | ------------------------ |
| `DECIMALS`       | 18                                    | `PaperbirdToken`         |
| `INITIAL_SUPPLY` | `1_000_000_000 * 10**18`              | `PaperbirdToken`         |

## Deployment parameters

The production deployment is IMD's launch, not a script in this repository. The factory deploys the
token from the attested creation code and, as the constructor's `msg.sender`, receives the whole
supply. It then pays it out as the launch economics say. The values below are the launch's and are
copied into `launch.json` by the manifest step, not by this repository:

- Chain: Ethereum, chain id 1
- Token contract: `PaperbirdToken`, decimals 18, `totalSupply` `1000000000000000000000000000`,
  no constructor arguments
- Application contracts: none
- Pair: IMD (`0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`), pool fee 12500 (1.25%),
  tick spacing 60, initial price `79228162514264337593543950336` (provenance only; the deployer
  derives the opening price)
- Economics: `poolBps` 6000, `initialMarketCapWei` `800000000000000000000` (800 IMD for the whole
  supply), `remainderTo` `0xee2aaa315cf7ed169f93148d30d24af9318dbb66`

Resulting distribution at launch, performed entirely by the factory:

| Share | Recipient                                        |
| ----- | ------------------------------------------------ |
| 10%   | The launch's MerkleDistributor (contributor swarm) |
| 60%   | Single-sided Uniswap v4 pool against IMD         |
| 30%   | `0xee2aaa315cf7ed169f93148d30d24af9318dbb66`      |

`script/DeployPaperbird.s.sol` exists only for local chains, forks and review. Its `deploy()`
function takes no configuration and is covered by `test/DeployPaperbird.t.sol`; `run()` wraps it in a
broadcast whose signer comes from forge's CLI flags. It reads no environment variables. Do not use it
for the real launch.

## After launch

Nothing to configure. The token has no owner, no setter and no external dependency, so there is no
post-launch step for the requester to perform on the contract.

## Operational responsibilities

- **Requester**: keep control of the `remainderTo` wallet, which receives 30% of the supply, and of
  the website and X account. Verify the source on Etherscan after launch (`forge verify-contract`
  with the pinned compiler settings) so holders can audit it; that step belongs to the deployer and
  launch policy, not to this repository.
- **IMD deployer**: deploys through the factory, seeds the pool and funds the distributor. No key or
  transaction authority is used by anything in this repository.
- **Holders**: `burn` is irreversible, and `permit` signatures must be guarded like approvals. The
  frontend should set a short `deadline` on permits and request only the allowance it needs.
- **Nobody**: there is no pause, blocklist or recovery function. Tokens sent to a wrong address, or to
  the token contract itself, cannot be recovered. The contract does not accept ether.

## Assumptions

- "Deployer" in the brief means whoever runs the constructor. At launch that is the ProjectFactory,
  which is what the custom-token floor requires; locally it is whichever address runs `deploy()`.
- The flappy-bird frontend and the website are off-chain deliverables and need nothing on-chain
  beyond a standard ERC-20 with `permit`.
- Burning was included as a holder-only convenience. It only ever reduces supply and cannot touch
  another holder's balance without that holder's allowance. If the requester would rather the supply
  be strictly constant, removing `ERC20Burnable` is a one-line change.

## Checks

```sh
forge build
forge test
forge fmt --check
```

All three pass locally with forge 1.8.3 and solc 0.8.26. The fuzz tests were run with
`FOUNDRY_FUZZ_SEED=0xfb388ba4029f230b5772f2ee1f19ab4dcd16b70ddf70c07a609ef786685c370e` as the
verifier does. Tests read no environment variables and are independent of ordering and of the calling
address. Tests passing is not a security audit; the contract is a thin composition of audited
OpenZeppelin v5.4.0 code with no custom logic beyond the one-time mint. Slither and Mythril were not
run (not provided on this machine).
