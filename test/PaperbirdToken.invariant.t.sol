// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PaperbirdToken} from "../src/PaperbirdToken.sol";

/// @notice Drives the token with random sequences of every state-changing entry point (transfer,
///         approve, transferFrom, burn, burnFrom, permit) from a small set of actors, keeping an
///         independent model of balances, allowances, burns and nonces. Calls the model says must
///         fail are made too, and the handler checks they revert and change nothing.
contract PaperbirdHandler is Test {
    PaperbirdToken public immutable token;

    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    address[] internal actors;
    uint256[] internal keys;

    // Model of what the token must hold.
    mapping(address => uint256) public ghostBalance;
    mapping(address => mapping(address => uint256)) public ghostAllowance;
    mapping(address => uint256) public ghostNonce;
    uint256 public ghostBurned;
    uint256 public ghostMoved;

    // Call counters, so a run that exercised nothing is visible.
    uint256 public successfulCalls;
    uint256 public expectedFailures;

    constructor(PaperbirdToken token_, address deployer) {
        token = token_;
        actors.push(deployer);
        keys.push(0);
        for (uint256 i; i < 4; ++i) {
            (address a, uint256 k) = makeAddrAndKey(string.concat("actor", vm.toString(i)));
            actors.push(a);
            keys.push(k);
        }
        ghostBalance[deployer] = token_.totalSupply();
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @dev Mostly in range, sometimes just past the limit, so both branches are exercised.
    function _amount(uint256 seed, uint256 limit) internal pure returns (uint256) {
        uint256 mode = seed % 8;
        if (mode == 0) return 0;
        if (mode == 1) return limit;
        if (mode == 2) return limit == type(uint256).max ? limit : limit + 1;
        return _bound(seed >> 8, 0, limit);
    }

    function _snapshot(address a, address b) internal view returns (uint256, uint256, uint256) {
        return (token.balanceOf(a), token.balanceOf(b), token.totalSupply());
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 amount = _amount(amountSeed, ghostBalance[from]);

        vm.prank(from);
        if (amount > ghostBalance[from]) {
            (uint256 bf, uint256 bt, uint256 s) = _snapshot(from, to);
            vm.expectRevert();
            token.transfer(to, amount);
            (uint256 af, uint256 at, uint256 s2) = _snapshot(from, to);
            assertEq(af, bf);
            assertEq(at, bt);
            assertEq(s2, s);
            ++expectedFailures;
            return;
        }
        assertTrue(token.transfer(to, amount));
        ghostBalance[from] -= amount;
        ghostBalance[to] += amount;
        if (from != to) ghostMoved += amount;
        ++successfulCalls;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 amount = amountSeed % 5 == 0 ? type(uint256).max : _bound(amountSeed, 0, token.INITIAL_SUPPLY());

        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        ghostAllowance[owner][spender] = amount;
        ++successfulCalls;
    }

    function transferFrom(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 amountSeed) external {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 allowed = ghostAllowance[owner][spender];
        uint256 held = ghostBalance[owner];
        uint256 amount = _amount(amountSeed, allowed < held ? allowed : held);

        vm.prank(spender);
        if (amount > allowed || amount > held) {
            (uint256 bo, uint256 bt, uint256 s) = _snapshot(owner, to);
            vm.expectRevert();
            token.transferFrom(owner, to, amount);
            (uint256 ao, uint256 at, uint256 s2) = _snapshot(owner, to);
            assertEq(ao, bo);
            assertEq(at, bt);
            assertEq(s2, s);
            assertEq(token.allowance(owner, spender), allowed, "failed transferFrom changed the allowance");
            ++expectedFailures;
            return;
        }
        assertTrue(token.transferFrom(owner, to, amount));
        if (allowed != type(uint256).max) ghostAllowance[owner][spender] = allowed - amount;
        ghostBalance[owner] -= amount;
        ghostBalance[to] += amount;
        if (owner != to) ghostMoved += amount;
        ++successfulCalls;
    }

    function burn(uint256 fromSeed, uint256 amountSeed) external {
        address from = _actor(fromSeed);
        uint256 amount = _amount(amountSeed, ghostBalance[from]);

        vm.prank(from);
        if (amount > ghostBalance[from]) {
            uint256 s = token.totalSupply();
            vm.expectRevert();
            token.burn(amount);
            assertEq(token.totalSupply(), s);
            ++expectedFailures;
            return;
        }
        token.burn(amount);
        ghostBalance[from] -= amount;
        ghostBurned += amount;
        ++successfulCalls;
    }

    function burnFrom(uint256 spenderSeed, uint256 ownerSeed, uint256 amountSeed) external {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        uint256 allowed = ghostAllowance[owner][spender];
        uint256 held = ghostBalance[owner];
        uint256 amount = _amount(amountSeed, allowed < held ? allowed : held);

        vm.prank(spender);
        if (amount > allowed || amount > held) {
            uint256 s = token.totalSupply();
            uint256 bo = token.balanceOf(owner);
            vm.expectRevert();
            token.burnFrom(owner, amount);
            assertEq(token.totalSupply(), s);
            assertEq(token.balanceOf(owner), bo);
            ++expectedFailures;
            return;
        }
        token.burnFrom(owner, amount);
        if (allowed != type(uint256).max) ghostAllowance[owner][spender] = allowed - amount;
        ghostBalance[owner] -= amount;
        ghostBurned += amount;
        ++successfulCalls;
    }

    /// @dev Signs a permit for a keyed actor. Sometimes the signature is deliberately wrong (stale
    ///      nonce, expired deadline, wrong signer), and then the call must revert with nothing changed.
    function permit(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed, uint256 faultSeed) external {
        uint256 idx = 1 + (ownerSeed % (actors.length - 1)); // actors with a known key
        address owner = actors[idx];
        address spender = _actor(spenderSeed);
        uint256 value = _bound(amountSeed, 0, type(uint256).max);
        uint256 nonce = ghostNonce[owner];
        uint256 deadline = block.timestamp + 1 hours;
        uint256 signer = keys[idx];

        uint256 fault = faultSeed % 4; // 0: valid; 1: replayed nonce; 2: expired; 3: wrong signer
        if (fault == 1) nonce += 1;
        if (fault == 2) deadline = block.timestamp - 1;
        if (fault == 3) signer = keys[1 + (idx % (actors.length - 1))]; // always another keyed actor

        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                token.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline))
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signer, digest);

        if (fault != 0) {
            uint256 before = token.allowance(owner, spender);
            vm.expectRevert();
            token.permit(owner, spender, value, deadline, v, r, s);
            assertEq(token.allowance(owner, spender), before, "rejected permit changed the allowance");
            assertEq(token.nonces(owner), ghostNonce[owner], "rejected permit consumed a nonce");
            ++expectedFailures;
            return;
        }
        token.permit(owner, spender, value, deadline, v, r, s);
        ghostAllowance[owner][spender] = value;
        ghostNonce[owner] += 1;
        ++successfulCalls;
    }

    /// @dev Time passes between calls; nothing in the token should depend on it except permit deadlines.
    function warp(uint256 secondsSeed) external {
        vm.warp(block.timestamp + _bound(secondsSeed, 1, 30 days));
    }
}

contract PaperbirdInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    address internal constant DEPLOYER = address(0xFAC7);

    PaperbirdToken internal token;
    PaperbirdHandler internal handler;

    function setUp() public {
        vm.prank(DEPLOYER);
        token = new PaperbirdToken();
        handler = new PaperbirdHandler(token, DEPLOYER);
        targetContract(address(handler));
    }

    /// @dev Every token in existence is held by someone the model knows: no balance appears from nowhere.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_sumOfBalancesEqualsTotalSupply() public view {
        uint256 sum;
        for (uint256 i; i < handler.actorCount(); ++i) {
            sum += token.balanceOf(handler.actorAt(i));
        }
        assertEq(sum, token.totalSupply(), "balances do not add up to the supply");
    }

    /// @dev The supply only falls, and only by exactly what was burned.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_supplyIsInitialMinusBurned() public view {
        assertEq(token.totalSupply(), SUPPLY - handler.ghostBurned(), "supply moved other than by burns");
        assertLe(token.totalSupply(), SUPPLY, "supply grew past the one-time mint");
    }

    /// @dev Each actor's balance is exactly what the model says: no fee, no reflection, no hidden move.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_balancesMatchModel() public view {
        for (uint256 i; i < handler.actorCount(); ++i) {
            address a = handler.actorAt(i);
            assertEq(token.balanceOf(a), handler.ghostBalance(a), "balance diverged from the model");
        }
    }

    /// @dev Allowances and permit nonces are exactly what the model says.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_allowancesAndNoncesMatchModel() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address owner = handler.actorAt(i);
            assertEq(token.nonces(owner), handler.ghostNonce(owner), "nonce diverged from the model");
            for (uint256 j; j < n; ++j) {
                address spender = handler.actorAt(j);
                assertEq(
                    token.allowance(owner, spender),
                    handler.ghostAllowance(owner, spender),
                    "allowance diverged from the model"
                );
            }
        }
    }

    /// @dev Nobody outside the actor set ever receives tokens, and the token never holds itself.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_noTokensLeakOutsideTheActors() public view {
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(0)), 0);
    }

    /// @dev A run that never changed state would make every invariant above vacuous.
    function afterInvariant() public view {
        assertGt(handler.successfulCalls(), 0, "the handler changed no state in this run");
    }

    /// @dev Metadata is fixed whatever sequence ran.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_metadataIsFixed() public view {
        assertEq(token.decimals(), 18);
        assertEq(token.name(), "paperbird");
        assertEq(token.symbol(), "PAPERBIR");
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
    }
}
