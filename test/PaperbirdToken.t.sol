// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {PaperbirdToken} from "../src/PaperbirdToken.sol";

/// @notice Behaviour of the paperbird token: metadata, the one-time mint, ordinary ERC-20 transfers and
///         allowances, burning, permit, and the absence of any way to grow the supply or to interfere
///         with a holder. Tests are independent of each other, read no environment, and do not depend on
///         which address runs them: the deployer is an explicit, pranked address.
contract PaperbirdTokenTest is Test {
    uint256 internal constant EXPECTED_SUPPLY = 1_000_000_000 ether;

    address internal constant DEPLOYER = address(0xFAC7);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    PaperbirdToken internal token;

    function setUp() public {
        vm.prank(DEPLOYER);
        token = new PaperbirdToken();
    }

    // ------------------------------------------------------------------ metadata and the one-time mint

    function test_metadata() public view {
        assertEq(token.name(), "paperbird");
        assertEq(token.symbol(), "PAPERBIR");
        assertEq(token.decimals(), 18);
        assertEq(token.DECIMALS(), 18);
    }

    function test_constructorMintsTheWholeSupplyToTheDeployerOnce() public view {
        assertEq(token.INITIAL_SUPPLY(), EXPECTED_SUPPLY, "constant is not 1e9 * 1e18");
        assertEq(token.totalSupply(), EXPECTED_SUPPLY, "supply is not 1,000,000,000 tokens");
        assertEq(token.balanceOf(DEPLOYER), EXPECTED_SUPPLY, "deployer does not hold the whole supply");
    }

    function test_constructorEmitsASingleMintTransfer() public {
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(0), DEPLOYER, EXPECTED_SUPPLY);
        vm.prank(DEPLOYER);
        new PaperbirdToken();
    }

    function test_eachDeploymentMintsToItsOwnDeployer() public {
        vm.prank(ALICE);
        PaperbirdToken other = new PaperbirdToken();
        assertEq(other.balanceOf(ALICE), EXPECTED_SUPPLY);
        assertEq(other.balanceOf(DEPLOYER), 0);
        // The first deployment is untouched by the second.
        assertEq(token.balanceOf(DEPLOYER), EXPECTED_SUPPLY);
    }

    // --------------------------------------------------------------------------------------- transfers

    function test_transferMovesExactlyWhatWasSent() public {
        uint256 amount = 1_234 ether;
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(DEPLOYER, ALICE, amount);
        vm.prank(DEPLOYER);
        assertTrue(token.transfer(ALICE, amount));

        assertEq(token.balanceOf(ALICE), amount, "fee on transfer");
        assertEq(token.balanceOf(DEPLOYER), EXPECTED_SUPPLY - amount);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY, "transfer changed the supply");
    }

    function test_transferOfZeroSucceeds() public {
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 0));
        assertEq(token.balanceOf(BOB), 0);
    }

    function test_transferToSelfIsANoOp() public {
        vm.prank(DEPLOYER);
        token.transfer(DEPLOYER, 5 ether);
        assertEq(token.balanceOf(DEPLOYER), EXPECTED_SUPPLY);
    }

    function test_transferRevertsWhenBalanceIsInsufficient() public {
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 10 ether);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 10 ether, 11 ether)
        );
        vm.prank(ALICE);
        token.transfer(BOB, 11 ether);
    }

    function test_transferRevertsToTheZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(DEPLOYER);
        token.transfer(address(0), 1);
    }

    function test_transferDoesNotCallBackIntoTheReceiver() public {
        // A plain ERC-20 moves balances without hooks, so a contract with no fallback can receive it.
        NoFallback sink = new NoFallback();
        vm.prank(DEPLOYER);
        assertTrue(token.transfer(address(sink), 1 ether));
        assertEq(token.balanceOf(address(sink)), 1 ether);
    }

    // -------------------------------------------------------------------------------------- allowances

    function test_approveSetsAllowanceAndEmits() public {
        vm.expectEmit(true, true, true, true);
        emit IERC20.Approval(DEPLOYER, ALICE, 7 ether);
        vm.prank(DEPLOYER);
        assertTrue(token.approve(ALICE, 7 ether));
        assertEq(token.allowance(DEPLOYER, ALICE), 7 ether);
    }

    function test_transferFromSpendsAllowance() public {
        vm.prank(DEPLOYER);
        token.approve(ALICE, 10 ether);

        vm.prank(ALICE);
        assertTrue(token.transferFrom(DEPLOYER, BOB, 4 ether));

        assertEq(token.balanceOf(BOB), 4 ether);
        assertEq(token.balanceOf(DEPLOYER), EXPECTED_SUPPLY - 4 ether);
        assertEq(token.allowance(DEPLOYER, ALICE), 6 ether, "allowance not decremented");
    }

    function test_transferFromRevertsWithoutAllowance() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transferFrom(DEPLOYER, BOB, 1);
    }

    function test_transferFromRevertsBeyondAllowance() public {
        vm.prank(DEPLOYER);
        token.approve(ALICE, 3 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, 3 ether, 3 ether + 1)
        );
        vm.prank(ALICE);
        token.transferFrom(DEPLOYER, BOB, 3 ether + 1);
    }

    function test_transferFromRevertsWhenOwnerBalanceIsInsufficient() public {
        vm.prank(ALICE);
        token.approve(BOB, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 1 ether));
        vm.prank(BOB);
        token.transferFrom(ALICE, BOB, 1 ether);
    }

    function test_unlimitedAllowanceIsNotDecremented() public {
        vm.prank(DEPLOYER);
        token.approve(ALICE, type(uint256).max);
        vm.prank(ALICE);
        token.transferFrom(DEPLOYER, BOB, 1 ether);
        assertEq(token.allowance(DEPLOYER, ALICE), type(uint256).max);
    }

    function test_approveRevertsForTheZeroSpender() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(DEPLOYER);
        token.approve(address(0), 1);
    }

    // ----------------------------------------------------------------------------------------- burning

    function test_burnShrinksSupplyAndBalance() public {
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 100 ether);

        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(ALICE, address(0), 40 ether);
        vm.prank(ALICE);
        token.burn(40 ether);

        assertEq(token.balanceOf(ALICE), 60 ether);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY - 40 ether);
    }

    function test_burnRevertsBeyondBalance() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.burn(1);
    }

    function test_burnFromSpendsAllowance() public {
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 100 ether);
        vm.prank(ALICE);
        token.approve(BOB, 30 ether);

        vm.prank(BOB);
        token.burnFrom(ALICE, 30 ether);

        assertEq(token.balanceOf(ALICE), 70 ether);
        assertEq(token.allowance(ALICE, BOB), 0);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY - 30 ether);
    }

    function test_burnFromRevertsWithoutAllowance() public {
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 100 ether);
        uint256 before = token.balanceOf(ALICE);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, 0, 1 ether));
        vm.prank(BOB);
        token.burnFrom(ALICE, 1 ether);

        assertEq(token.balanceOf(ALICE), before, "burnFrom without allowance moved a balance");
    }

    function test_deployerCannotBurnAHoldersTokens() public {
        // The deployer (the factory, after launch) has no special power over anyone's balance.
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 100 ether);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, DEPLOYER, 0, 1));
        vm.prank(DEPLOYER);
        token.burnFrom(ALICE, 1);
        assertEq(token.balanceOf(ALICE), 100 ether);
    }

    // ------------------------------------------------------------------------------------------ permit

    function test_permitSetsAllowanceFromASignature() public {
        (address owner, uint256 key) = makeAddrAndKey("owner");
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(key, owner, ALICE, 5 ether, token.nonces(owner), deadline);

        vm.expectEmit(true, true, true, true);
        emit IERC20.Approval(owner, ALICE, 5 ether);
        // Anyone may submit the signature; the relayer pays gas, not the owner.
        vm.prank(BOB);
        token.permit(owner, ALICE, 5 ether, deadline, v, r, s);

        assertEq(token.allowance(owner, ALICE), 5 ether);
        assertEq(token.nonces(owner), 1);
    }

    function test_permitRevertsAfterTheDeadline() public {
        (address owner, uint256 key) = makeAddrAndKey("owner");
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(key, owner, ALICE, 5 ether, 0, deadline);

        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline));
        token.permit(owner, ALICE, 5 ether, deadline, v, r, s);
        assertEq(token.allowance(owner, ALICE), 0);
    }

    function test_permitRevertsForTheWrongSigner() public {
        (address owner,) = makeAddrAndKey("owner");
        (address mallory, uint256 malloryKey) = makeAddrAndKey("mallory");
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(malloryKey, owner, ALICE, 5 ether, 0, deadline);

        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612InvalidSigner.selector, mallory, owner));
        token.permit(owner, ALICE, 5 ether, deadline, v, r, s);
        assertEq(token.allowance(owner, ALICE), 0);
    }

    function test_permitCannotBeReplayed() public {
        (address owner, uint256 key) = makeAddrAndKey("owner");
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(key, owner, ALICE, 5 ether, 0, deadline);
        token.permit(owner, ALICE, 5 ether, deadline, v, r, s);

        // The nonce moved on, so the same signature now recovers to some other address.
        vm.expectRevert();
        token.permit(owner, ALICE, 5 ether, deadline, v, r, s);
        assertEq(token.nonces(owner), 1);
    }

    function test_permitIsBoundToThisChainAndContract() public {
        (address owner, uint256 key) = makeAddrAndKey("owner");
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(key, owner, ALICE, 5 ether, 0, deadline);

        // Another chain id changes the domain separator; the signature no longer recovers the owner.
        vm.chainId(block.chainid + 1);
        vm.expectRevert();
        token.permit(owner, ALICE, 5 ether, deadline, v, r, s);
    }

    // ------------------------------------------------------------------------ nothing grows the supply

    function test_noMintEntryPointExists() public {
        string[6] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setMinter(address)",
            "transferOwnership(address)"
        ];
        address[2] memory callers = [DEPLOYER, address(0xBEEF)];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], address(0xBEEF), type(uint128).max);
            for (uint256 c; c < callers.length; ++c) {
                vm.prank(callers[c]);
                (bool ok,) = address(token).call(data);
                assertFalse(ok, signatures[i]);
            }
        }
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(address(0xBEEF)), 0);
    }

    function test_noPrivilegedCallMovesOrFreezesAHolder() public {
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 1_000 ether);
        string[8] memory signatures = [
            "pause()",
            "blacklist(address)",
            "freeze(address)",
            "setBlacklist(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "seize(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            vm.prank(DEPLOYER);
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], ALICE, true));
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.balanceOf(ALICE), 1_000 ether);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 500 ether));
        assertEq(token.balanceOf(BOB), 500 ether);
    }

    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "runtime exceeds EIP-170");
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
        }
    }

    function test_tokenDoesNotAcceptEther() public {
        vm.deal(ALICE, 1 ether);
        vm.prank(ALICE);
        (bool ok,) = address(token).call{value: 1 wei}("");
        assertFalse(ok, "token accepted ether");
        assertEq(address(token).balance, 0);
    }

    // --------------------------------------------------------------------------------------------- fuzz

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != DEPLOYER);
        amount = bound(amount, 0, EXPECTED_SUPPLY);

        vm.prank(DEPLOYER);
        assertTrue(token.transfer(to, amount));

        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(DEPLOYER), EXPECTED_SUPPLY - amount);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    function testFuzz_transferRevertsBeyondBalance(uint256 held, uint256 attempt) public {
        held = bound(held, 0, EXPECTED_SUPPLY - 1);
        attempt = bound(attempt, held + 1, EXPECTED_SUPPLY);
        vm.prank(DEPLOYER);
        token.transfer(ALICE, held);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, held, attempt));
        vm.prank(ALICE);
        token.transfer(BOB, attempt);
    }

    function testFuzz_burnNeverGrowsSupply(uint256 held, uint256 burned) public {
        held = bound(held, 0, EXPECTED_SUPPLY);
        burned = bound(burned, 0, held);
        vm.prank(DEPLOYER);
        token.transfer(ALICE, held);

        vm.prank(ALICE);
        token.burn(burned);

        assertEq(token.totalSupply(), EXPECTED_SUPPLY - burned);
        assertEq(token.balanceOf(ALICE), held - burned);
        assertLe(token.totalSupply(), EXPECTED_SUPPLY);
    }

    function testFuzz_transferFromNeverExceedsAllowance(uint256 allowed, uint256 spent) public {
        allowed = bound(allowed, 0, EXPECTED_SUPPLY);
        spent = bound(spent, 0, EXPECTED_SUPPLY);
        vm.prank(DEPLOYER);
        token.approve(ALICE, allowed);

        vm.prank(ALICE);
        if (spent > allowed) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, allowed, spent)
            );
            token.transferFrom(DEPLOYER, BOB, spent);
        } else {
            assertTrue(token.transferFrom(DEPLOYER, BOB, spent));
            assertEq(token.balanceOf(BOB), spent);
            assertEq(token.allowance(DEPLOYER, ALICE), allowed - spent);
        }
    }

    // ------------------------------------------------------------------------------------------ helpers

    function _signPermit(uint256 key, address owner, address spender, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(key, digest);
    }
}

/// @dev A receiver with no fallback or receive function.
contract NoFallback {}
