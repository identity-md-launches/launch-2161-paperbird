// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployPaperbird} from "../script/DeployPaperbird.s.sol";
import {PaperbirdToken} from "../src/PaperbirdToken.sol";

/// @notice The deploy script's `deploy()` is called directly, with no broadcast and no environment, and
///         must hand the whole supply to whoever ran the constructor.
contract DeployPaperbirdTest is Test {
    function test_deployMintsTheSupplyToTheScriptsCaller() public {
        DeployPaperbird deployer = new DeployPaperbird();
        PaperbirdToken token = deployer.deploy();

        assertEq(token.name(), "paperbird");
        assertEq(token.symbol(), "PAPERBIR");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        // `new` inside the script makes the script contract the deployer, exactly as the factory is at launch.
        assertEq(token.balanceOf(address(deployer)), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function test_creationCodeTakesNoConstructorArguments() public {
        // The launch deploys the attested creation code as built, with no arguments appended.
        bytes memory code = type(PaperbirdToken).creationCode;
        address deployed;
        assembly ("memory-safe") {
            deployed := create(0, add(code, 32), mload(code))
        }
        assertTrue(deployed != address(0), "constructor failed");
        assertEq(PaperbirdToken(deployed).balanceOf(address(this)), 1_000_000_000 ether);
    }
}
