// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {PaperbirdToken} from "../src/PaperbirdToken.sol";

/// @notice Boundary cases the main suite does not pin: the full supply, one wei, the maximum
///         allowance, burning everything, permit at its edges, and the launch flows the factory runs
///         (the swarm share, the pool seed, the remainder) arriving exact.
contract PaperbirdTokenEdgesTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    address internal constant DEPLOYER = address(0xFAC7);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    PaperbirdToken internal token;

    function setUp() public {
        vm.prank(DEPLOYER);
        token = new PaperbirdToken();
    }

    // ----------------------------------------------------------------------------- supply boundaries

    function test_transferOfTheWholeSupply() public {
        vm.prank(DEPLOYER);
        token.transfer(ALICE, SUPPLY);
        assertEq(token.balanceOf(ALICE), SUPPLY);
        assertEq(token.balanceOf(DEPLOYER), 0);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, DEPLOYER, 0, 1));
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 1);
    }

    function test_transferOfOneWeiMoreThanTheSupplyReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, DEPLOYER, SUPPLY, SUPPLY + 1)
        );
        vm.prank(DEPLOYER);
        token.transfer(ALICE, SUPPLY + 1);
    }

    function test_transferOfMaxUintReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, DEPLOYER, SUPPLY, type(uint256).max)
        );
        vm.prank(DEPLOYER);
        token.transfer(ALICE, type(uint256).max);
    }

    function test_oneWeiTransfer() public {
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 1);
        assertEq(token.balanceOf(ALICE), 1);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_burnTheWholeSupplyLeavesZero() public {
        vm.prank(DEPLOYER);
        token.burn(SUPPLY);
        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(DEPLOYER), 0);

        // With nothing left, nothing can be moved or burned, and nothing re-mints.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, DEPLOYER, 0, 1));
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, DEPLOYER, 0, 1));
        vm.prank(DEPLOYER);
        token.burn(1);
    }

    function test_burnOfZeroIsANoOp() public {
        vm.prank(ALICE);
        token.burn(0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_burnFromWithUnlimitedAllowanceKeepsTheAllowance() public {
        vm.prank(DEPLOYER);
        token.approve(ALICE, type(uint256).max);
        vm.prank(ALICE);
        token.burnFrom(DEPLOYER, 10 ether);
        assertEq(token.allowance(DEPLOYER, ALICE), type(uint256).max);
        assertEq(token.totalSupply(), SUPPLY - 10 ether);
    }

    function test_burnFromRevertsBeyondBalanceEvenWithAllowance() public {
        vm.prank(ALICE);
        token.approve(BOB, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        vm.prank(BOB);
        token.burnFrom(ALICE, 1);
    }

    function test_burnFromTheZeroAddressReverts() public {
        // address(0) cannot approve anyone, so the allowance check fails first.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.burnFrom(address(0), 1);
    }

    // ------------------------------------------------------------------------------------- allowances

    function test_approveOverwritesRatherThanAdds() public {
        vm.startPrank(DEPLOYER);
        token.approve(ALICE, 10 ether);
        token.approve(ALICE, 3 ether);
        vm.stopPrank();
        assertEq(token.allowance(DEPLOYER, ALICE), 3 ether);
    }

    function test_approveToZeroRevokes() public {
        vm.prank(DEPLOYER);
        token.approve(ALICE, 10 ether);
        vm.prank(DEPLOYER);
        token.approve(ALICE, 0);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transferFrom(DEPLOYER, BOB, 1);
    }

    function test_transferFromOfZeroWithoutAllowanceSucceeds() public {
        vm.prank(ALICE);
        assertTrue(token.transferFrom(DEPLOYER, BOB, 0));
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
    }

    function test_transferFromToTheZeroAddressReverts() public {
        vm.prank(DEPLOYER);
        token.approve(ALICE, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(ALICE);
        token.transferFrom(DEPLOYER, address(0), 1);
        assertEq(token.allowance(DEPLOYER, ALICE), 1 ether, "reverted call spent allowance");
    }

    function test_selfAllowanceIsStillRequiredForTransferFrom() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, DEPLOYER, 0, 1));
        vm.prank(DEPLOYER);
        token.transferFrom(DEPLOYER, ALICE, 1);
    }

    function test_allowanceSpentExactlyToZero() public {
        vm.prank(DEPLOYER);
        token.approve(ALICE, 5 ether);
        vm.prank(ALICE);
        token.transferFrom(DEPLOYER, BOB, 5 ether);
        assertEq(token.allowance(DEPLOYER, ALICE), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transferFrom(DEPLOYER, BOB, 1);
    }

    // ----------------------------------------------------------------------------------------- permit

    function test_permitAtExactlyTheDeadlineSucceeds() public {
        (address owner, uint256 key) = makeAddrAndKey("owner");
        uint256 deadline = vm.getBlockTimestamp() + 100;
        (uint8 v, bytes32 r, bytes32 s) = _sign(key, owner, ALICE, 1 ether, 0, deadline);
        vm.warp(deadline);
        token.permit(owner, ALICE, 1 ether, deadline, v, r, s);
        assertEq(token.allowance(owner, ALICE), 1 ether);
    }

    function test_permitToTheZeroSpenderReverts() public {
        (address owner, uint256 key) = makeAddrAndKey("owner");
        uint256 deadline = vm.getBlockTimestamp() + 100;
        (uint8 v, bytes32 r, bytes32 s) = _sign(key, owner, address(0), 1 ether, 0, deadline);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.permit(owner, address(0), 1 ether, deadline, v, r, s);
        assertEq(token.nonces(owner), 0, "reverted permit consumed the nonce");
    }

    function test_permitWithMalleableHighSReverts() public {
        (address owner, uint256 key) = makeAddrAndKey("owner");
        uint256 deadline = vm.getBlockTimestamp() + 100;
        (uint8 v, bytes32 r, bytes32 s) = _sign(key, owner, ALICE, 1 ether, 0, deadline);
        // The mirrored signature recovers the same key on raw ecrecover; ECDSA must refuse it.
        bytes32 highS = bytes32(SECP256K1_N - uint256(s));
        uint8 flippedV = v == 27 ? 28 : 27;
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, highS));
        token.permit(owner, ALICE, 1 ether, deadline, flippedV, r, highS);
    }

    function test_permitWithGarbageSignatureReverts() public {
        (address owner,) = makeAddrAndKey("owner");
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        token.permit(owner, ALICE, 1 ether, type(uint256).max, 27, bytes32(0), bytes32(0));
    }

    function test_permitForTheZeroOwnerCannotBeForged() public {
        // A signature that fails to recover must not authorise address(0)'s (empty) allowance either.
        vm.expectRevert();
        token.permit(address(0), ALICE, 1 ether, type(uint256).max, 27, bytes32(uint256(1)), bytes32(uint256(1)));
        assertEq(token.allowance(address(0), ALICE), 0);
    }

    function test_permitThenTransferFrom() public {
        (address owner, uint256 key) = makeAddrAndKey("owner");
        vm.prank(DEPLOYER);
        token.transfer(owner, 10 ether);
        uint256 deadline = vm.getBlockTimestamp() + 100;
        (uint8 v, bytes32 r, bytes32 s) = _sign(key, owner, ALICE, 4 ether, 0, deadline);
        token.permit(owner, ALICE, 4 ether, deadline, v, r, s);

        vm.prank(ALICE);
        token.transferFrom(owner, BOB, 4 ether);
        assertEq(token.balanceOf(BOB), 4 ether);
        assertEq(token.allowance(owner, ALICE), 0);
    }

    function test_permitSignedForAnotherDeploymentFails() public {
        (address owner, uint256 key) = makeAddrAndKey("owner");
        vm.prank(DEPLOYER);
        PaperbirdToken other = new PaperbirdToken();
        uint256 deadline = vm.getBlockTimestamp() + 100;
        (uint8 v, bytes32 r, bytes32 s) = _sign(key, owner, ALICE, 1 ether, 0, deadline);
        vm.expectRevert();
        other.permit(owner, ALICE, 1 ether, deadline, v, r, s);
    }

    function test_eip712Domain() public view {
        (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        ) = token.eip712Domain();
        assertEq(fields, hex"0f");
        assertEq(name, "paperbird");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifyingContract, address(token));
        assertEq(salt, bytes32(0));
        assertEq(extensions.length, 0);

        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("paperbird"),
                keccak256("1"),
                block.chainid,
                address(token)
            )
        );
        assertEq(token.DOMAIN_SEPARATOR(), expected);
    }

    // ------------------------------------------------------------------------------ launch flows exact

    /// @dev The factory's three outflows: 10% to the distributor, a pool seed, and the remainder.
    ///      Each must arrive whole, and the distributor's claims must leave it whole.
    function testFuzz_launchFlowsArriveExact(uint256 poolBps) public {
        poolBps = _bound(poolBps, 0, 9_000);
        address distributor = address(0xD157);
        address pool = address(0x9001);
        address requester = address(0x4E9);

        uint256 swarm = SUPPLY * 1_000 / 10_000;
        uint256 seed = SUPPLY * poolBps / 10_000;
        uint256 rest = SUPPLY - swarm - seed;

        vm.startPrank(DEPLOYER);
        token.transfer(distributor, swarm);
        token.transfer(pool, seed);
        token.transfer(requester, rest);
        vm.stopPrank();

        assertEq(token.balanceOf(distributor), swarm);
        assertEq(token.balanceOf(pool), seed);
        assertEq(token.balanceOf(requester), rest);
        assertEq(token.balanceOf(DEPLOYER), 0);

        // Claims out of the distributor, in two uneven parts.
        vm.startPrank(distributor);
        token.transfer(ALICE, swarm / 3);
        token.transfer(BOB, swarm - swarm / 3);
        vm.stopPrank();
        assertEq(token.balanceOf(distributor), 0);
        assertEq(token.balanceOf(ALICE) + token.balanceOf(BOB), swarm);
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ---------------------------------------------------------------------------- stateless fuzzing

    function testFuzz_burnFromRespectsAllowanceAndBalance(uint256 held, uint256 allowed, uint256 burned) public {
        held = _bound(held, 0, SUPPLY);
        allowed = _bound(allowed, 0, SUPPLY);
        burned = _bound(burned, 0, SUPPLY);
        vm.prank(DEPLOYER);
        token.transfer(ALICE, held);
        vm.prank(ALICE);
        token.approve(BOB, allowed);

        vm.prank(BOB);
        if (burned > allowed) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, allowed, burned)
            );
            token.burnFrom(ALICE, burned);
            assertEq(token.balanceOf(ALICE), held);
        } else if (burned > held) {
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, held, burned));
            token.burnFrom(ALICE, burned);
            assertEq(token.balanceOf(ALICE), held);
        } else {
            token.burnFrom(ALICE, burned);
            assertEq(token.balanceOf(ALICE), held - burned);
            assertEq(token.allowance(ALICE, BOB), allowed - burned);
            assertEq(token.totalSupply(), SUPPLY - burned);
        }
    }

    function testFuzz_transferBetweenThirdParties(address from, address to, uint256 seeded, uint256 amount) public {
        from = address(uint160(_bound(uint160(from), 1, type(uint160).max)));
        to = address(uint160(_bound(uint160(to), 1, type(uint160).max)));
        if (from == DEPLOYER) from = ALICE;
        if (to == DEPLOYER) to = BOB;
        seeded = _bound(seeded, 0, SUPPLY);
        amount = _bound(amount, 0, SUPPLY);
        vm.prank(DEPLOYER);
        token.transfer(from, seeded);

        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);
        vm.prank(from);
        if (amount > seeded) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, seeded, amount)
            );
            token.transfer(to, amount);
            assertEq(token.balanceOf(from), fromBefore);
        } else {
            token.transfer(to, amount);
            if (from == to) {
                assertEq(token.balanceOf(from), fromBefore);
            } else {
                assertEq(token.balanceOf(from), fromBefore - amount);
                assertEq(token.balanceOf(to), toBefore + amount);
            }
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_permitSetsExactlyTheSignedValue(uint256 value, uint256 deadlineOffset) public {
        (address owner, uint256 key) = makeAddrAndKey("owner");
        deadlineOffset = _bound(deadlineOffset, 0, 365 days);
        uint256 deadline = vm.getBlockTimestamp() + deadlineOffset;
        (uint8 v, bytes32 r, bytes32 s) = _sign(key, owner, ALICE, value, 0, deadline);
        token.permit(owner, ALICE, value, deadline, v, r, s);
        assertEq(token.allowance(owner, ALICE), value);
        assertEq(token.nonces(owner), 1);

        // A tampered value with the same signature never sets an allowance.
        (uint8 v2, bytes32 r2, bytes32 s2) = _sign(key, owner, ALICE, value, 1, deadline);
        uint256 tampered = value == type(uint256).max ? 0 : value + 1;
        vm.expectRevert();
        token.permit(owner, ALICE, tampered, deadline, v2, r2, s2);
        assertEq(token.allowance(owner, ALICE), value);
    }

    // ---------------------------------------------------------------------------------------- helpers

    function _sign(uint256 key, address owner, address spender, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(key, digest);
    }
}
