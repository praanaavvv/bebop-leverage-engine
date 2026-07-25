// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Position, IERC20} from "../../src/Position.sol";

/// Layer 3: real Aave + real Morpho + a REAL Bebop RFQ fill on a Base fork.
/// This is the test that proves the whole integration — including that a
/// contract taker can self-execute a PMM quote (open question 5 in the notes).
///
/// The quote is fetched off-chain for a FIXED taker address, then the Position
/// runtime code (immutables baked in) is etched at that address on the fork.
///
/// Refresh the fixture and run within its 60s expiry:
///   node ../bebop.ts --api pmm --chain base quote \
///     --sell 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 \
///     --buy 0x4200000000000000000000000000000000000006 \
///     --amount 300000000 --taker 0x1111111111111111111111111111111111111111 \
///     --gasless false > test/fixtures/quote-open.json \
///   && forge test --match-contract BebopForkTest -vv
contract BebopForkTest is Test {
    address constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant A_WETH = 0xD4a0e0b9149BCee3C920d2E00b5dE09138fd8bb7;
    address constant VDEBT_USDC = 0x59dca05b6c26dbd64b5381374aAaC5CD05644C28;

    address user = makeAddr("user");

    struct Quote {
        address taker;
        address target;
        address approvalTarget;
        bytes data;
        uint256 expiry;
        uint256 sellAmt;
        uint256 minOut;
    }

    function _loadQuote() internal returns (Quote memory q) {
        string memory path = "test/fixtures/quote-open.json";
        if (!vm.exists(path)) {
            emit log("SKIP: no fixture - see the fetch command in this file's header");
            vm.skip(true);
        }
        string memory j = vm.readFile(path);
        q.taker = vm.parseJsonAddress(j, ".taker");
        q.target = vm.parseJsonAddress(j, ".tx.to");
        q.approvalTarget = vm.parseJsonAddress(j, ".approvalTarget");
        q.data = vm.parseJsonBytes(j, ".tx.data");
        q.expiry = vm.parseJsonUint(j, ".expiry");
        q.sellAmt = vm.parseJsonUint(j, ".sellTokens.0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913.amount");
        q.minOut = vm.parseJsonUint(j, ".buyTokens.0x4200000000000000000000000000000000000006.minimumAmount");
    }

    function test_open_with_real_bebop_quote() public {
        Quote memory q = _loadQuote();

        vm.createSelectFork(vm.envOr("BASE_RPC", string("https://base-rpc.publicnode.com")));
        if (block.timestamp > q.expiry) {
            emit log("SKIP: fixture quote expired - refetch and rerun (see file header)");
            vm.skip(true);
        }

        // Deploy the implementation with the quote's target/approvalTarget allow-listed,
        // then etch its runtime code at the taker address the maker signed for.
        Position impl = new Position(MORPHO, POOL, q.target, q.approvalTarget);
        vm.etch(q.taker, address(impl).code);
        Position pos = Position(q.taker);
        pos.initialize(user);

        // the fixed taker address may hold pre-existing dust on mainnet - assert deltas
        uint256 usdcBefore = IERC20(USDC).balanceOf(q.taker);

        uint256 equity = q.sellAmt / 3; // 3x: one third equity, two thirds flash
        deal(USDC, user, equity);
        vm.prank(user);
        IERC20(USDC).approve(q.taker, equity);

        Position.Action memory a;
        a.position = q.taker;
        a.deadline = q.expiry;
        a.mode = 0; // OPEN
        a.collateral = WETH;
        a.debt = USDC;
        a.equity = equity;
        a.maxSell = q.sellAmt;
        a.minOut = q.minOut;
        a.flash = q.sellAmt - equity;
        a.minHealthFactor = 1e18;
        a.receiver = user;

        vm.prank(user);
        pos.execute(a, "", Position.SwapCall(q.target, q.approvalTarget, q.data));

        assertGe(IERC20(A_WETH).balanceOf(q.taker), q.minOut, "collateral supplied from real fill");
        assertApproxEqAbs(IERC20(VDEBT_USDC).balanceOf(q.taker), q.sellAmt - equity, 2, "debt equals flash size");
        assertEq(IERC20(USDC).balanceOf(q.taker), usdcBefore, "no stranded USDC beyond pre-existing dust");
        assertEq(IERC20(WETH).balanceOf(q.taker), 0, "full realized balance supplied");
    }
}
