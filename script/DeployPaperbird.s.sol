// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {PaperbirdToken} from "../src/PaperbirdToken.sol";

/// @title Local / review deployment of PaperbirdToken
/// @notice The production launch on Ethereum is performed by IMD's ProjectFactory, which deploys the
///         token from its built bytecode and receives the whole supply as `msg.sender`. This script is
///         for local chains, forks and reviews only. It reads no environment variables and takes no
///         configuration: the token has none.
/// @dev `deploy()` is the unit under test (see test/DeployPaperbird.t.sol). `run()` only wraps it in a
///      broadcast so `forge script --broadcast` can be used against a local node; the signer comes from
///      forge's own CLI flags, never from this file.
contract DeployPaperbird is Script {
    /// @notice Deploys the token. Whoever calls the constructor (the broadcast sender under `run()`,
    ///         or the caller's context in a test) receives the whole supply.
    function deploy() public returns (PaperbirdToken token) {
        token = new PaperbirdToken();
    }

    /// @notice Broadcast entry point for `forge script`.
    function run() external returns (PaperbirdToken token) {
        vm.startBroadcast();
        token = deploy();
        vm.stopBroadcast();
    }
}
