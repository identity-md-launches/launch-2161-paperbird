// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title paperbird (PAPERBIR)
/// @notice A fixed-supply ERC-20. The whole supply of 1,000,000,000 PAPERBIR (18 decimals) is minted
///         once, in the constructor, to the deployer. Nothing can mint afterwards.
/// @dev Design, in order of what matters for the launch:
///      - No owner, no admin, no pause, no blocklist, no fee on transfer, no upgrade path. The contract has
///        no privileged function at all, so no hand can move or freeze a holder's balance, and there is
///        no key to lose or to trust.
///      - The supply can only shrink: holders may burn their own tokens (`burn`) or tokens they have been
///        approved to spend (`burnFrom`, standard ERC-20 allowance). It can never grow.
///      - ERC-2612 `permit` is included so a frontend (the flappy-bird site) can collect gasless approvals
///        with a signature instead of a separate approve transaction.
///      - The constructor takes no arguments and calls no other contract, so it deploys on an empty chain
///        and the launch manifest needs no constructor values.
///      The deployer is whoever runs the constructor. In the IMD launch that is the ProjectFactory, which
///      receives the whole supply and pays it out as the launch economics say (swarm share, pool seed,
///      remainder to the requester). See README.md.
contract PaperbirdToken is ERC20, ERC20Burnable, ERC20Permit {
    /// @notice The token's name, as `name()` returns it.
    string internal constant TOKEN_NAME = "paperbird";

    /// @notice The token's symbol, as `symbol()` returns it.
    string internal constant TOKEN_SYMBOL = "PAPERBIR";

    /// @notice Number of decimals; `decimals()` returns this.
    uint8 public constant DECIMALS = 18;

    /// @notice The total supply ever to exist: 1,000,000,000 whole tokens in minor units (10^18 each).
    ///         This is `totalSupply()` immediately after deployment and an upper bound forever after.
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** uint256(DECIMALS);

    /// @notice Mints the entire supply to the deployer. This is the only mint that ever happens.
    constructor() ERC20(TOKEN_NAME, TOKEN_SYMBOL) ERC20Permit(TOKEN_NAME) {
        _mint(msg.sender, INITIAL_SUPPLY);
    }

    /// @inheritdoc ERC20
    function decimals() public pure override returns (uint8) {
        return DECIMALS;
    }
}
