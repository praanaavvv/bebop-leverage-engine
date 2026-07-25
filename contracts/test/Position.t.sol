// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Position} from "../src/Position.sol";
import {PositionFactory} from "../src/PositionFactory.sol";
import {MockERC20, MockMorpho, MockBebopRouter, MockPool} from "./mocks/Mocks.sol";

contract PositionTest is Test {
    uint8 constant OPEN = 0;
    uint8 constant INCREASE = 1;
    uint8 constant REDUCE = 2;
    uint256 constant MAX = type(uint256).max;

    // 3x long: 100 USDC equity, 200 flash, sell 300 -> 0.12 WETH at $2500. HF = 300*0.8/200 = 1.2
    uint256 constant E = 100e6;
    uint256 constant L = 200e6;
    uint256 constant S = 300e6;
    uint256 constant C = 0.12e18;

    MockERC20 usdc;
    MockERC20 weth;
    MockMorpho morpho;
    MockBebopRouter router;
    MockPool pool;
    PositionFactory factory;
    Position pos;

    address user = makeAddr("user");

    function setUp() public {
        usdc = new MockERC20("USDC", 6);
        weth = new MockERC20("WETH", 18);
        morpho = new MockMorpho();
        router = new MockBebopRouter();
        pool = new MockPool();

        pool.setReserve(address(usdc), 1e18, 6);
        pool.setReserve(address(weth), 2500e18, 18);

        Position impl = new Position(address(morpho), address(pool), address(router), address(router));
        factory = new PositionFactory(address(impl));
        pos = Position(factory.deploy(user, 0));

        usdc.mint(address(morpho), 1_000_000e6); // flash liquidity
        usdc.mint(address(pool), 1_000_000e6); // borrow liquidity
        weth.mint(address(router), 100e18); // maker inventory
        usdc.mint(address(router), 1_000_000e6);

        usdc.mint(user, E);
        vm.prank(user);
        usdc.approve(address(pos), MAX);
    }

    function _action(uint8 mode) internal view returns (Position.Action memory a) {
        a.position = address(pos);
        a.nonce = pos.nonce();
        a.deadline = block.timestamp + 60;
        a.mode = mode;
        a.collateral = address(weth);
        a.debt = address(usdc);
        a.minHealthFactor = 1.1e18;
        a.receiver = user;
    }

    function _swapCall(address sell, address buy, uint256 sellAmt, uint256 buyAmt)
        internal
        view
        returns (Position.SwapCall memory s)
    {
        s.target = address(router);
        s.approvalTarget = address(router);
        s.data = abi.encodeCall(MockBebopRouter.swap, (sell, buy, sellAmt, buyAmt));
    }

    function _open() internal {
        Position.Action memory a = _action(OPEN);
        a.equity = E;
        a.flash = L;
        a.maxSell = S;
        a.minOut = C;
        vm.prank(user);
        pos.execute(a, "", _swapCall(address(usdc), address(weth), S, C));
    }

    // --- happy paths ---

    function test_open() public {
        _open();
        assertEq(pool.collateralOf(address(pos), address(weth)), C);
        assertEq(pool.debtOf(address(pos), address(usdc)), L);
        assertEq(usdc.balanceOf(address(pos)), 0, "no stranded debt token");
        assertEq(weth.balanceOf(address(pos)), 0, "full realized balance supplied");
        assertEq(usdc.allowance(address(pos), address(router)), 0, "approval hygiene");
        assertEq(pos.nonce(), 1);
    }

    function test_increase() public {
        _open();
        Position.Action memory a = _action(INCREASE);
        a.flash = 25e6; // extra borrow
        a.maxSell = 25e6;
        a.minOut = 0.01e18;
        vm.prank(user);
        pos.execute(a, "", _swapCall(address(usdc), address(weth), 25e6, 0.01e18));

        assertEq(pool.collateralOf(address(pos), address(weth)), 0.13e18);
        assertEq(pool.debtOf(address(pos), address(usdc)), 225e6);
    }

    function test_reduce_partial() public {
        _open();
        Position.Action memory a = _action(REDUCE);
        a.flash = 100e6;
        a.repayAmount = 100e6;
        a.maxSell = 0.04e18; // withdraw + sell exactly what repays the flash
        a.minOut = 100e6;
        vm.prank(user);
        pos.execute(a, "", _swapCall(address(weth), address(usdc), 0.04e18, 100e6));

        assertEq(pool.collateralOf(address(pos), address(weth)), 0.08e18);
        assertEq(pool.debtOf(address(pos), address(usdc)), 100e6);
        // proportional reduce improved HF: 200*0.8/100 = 1.6
        (,,,,, uint256 hf) = pool.getUserAccountData(address(pos));
        assertEq(hf, 1.6e18);
    }

    function test_close_full_sweeps_residual() public {
        _open();
        Position.Action memory a = _action(REDUCE);
        a.flash = L;
        a.repayAmount = MAX;
        a.maxSell = C;
        a.minOut = S;
        vm.prank(user);
        pos.execute(a, "", _swapCall(address(weth), address(usdc), C, S));

        assertEq(pool.collateralOf(address(pos), address(weth)), 0);
        assertEq(pool.debtOf(address(pos), address(usdc)), 0);
        assertEq(usdc.balanceOf(user), E, "equity returned (no fees in mocks)");
        assertEq(usdc.balanceOf(address(pos)), 0);
        assertEq(weth.balanceOf(address(pos)), 0);
    }

    function test_skim() public {
        usdc.mint(address(pos), 5e6);
        vm.prank(user);
        pos.skim(address(usdc), user);
        assertEq(usdc.balanceOf(user), E + 5e6);
    }

    // --- guards ---

    function test_open_reverts_on_bad_fill() public {
        Position.Action memory a = _action(OPEN);
        a.equity = E;
        a.flash = L;
        a.maxSell = S;
        a.minOut = C;
        vm.prank(user);
        vm.expectRevert(bytes("minOut"));
        pos.execute(a, "", _swapCall(address(usdc), address(weth), S, C - 1));
    }

    function test_open_reverts_on_health_floor() public {
        Position.Action memory a = _action(OPEN);
        a.equity = E;
        a.flash = L;
        a.maxSell = S;
        a.minOut = C;
        a.minHealthFactor = 1.3e18; // actual HF is 1.2
        vm.prank(user);
        vm.expectRevert(bytes("health"));
        pos.execute(a, "", _swapCall(address(usdc), address(weth), S, C));
    }

    function test_reverts_on_non_owner() public {
        Position.Action memory a = _action(OPEN);
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(bytes("auth"));
        pos.execute(a, "", _swapCall(address(usdc), address(weth), S, C));
    }

    function test_reverts_on_bad_nonce() public {
        Position.Action memory a = _action(OPEN);
        a.nonce = 5;
        vm.prank(user);
        vm.expectRevert(bytes("nonce"));
        pos.execute(a, "", _swapCall(address(usdc), address(weth), S, C));
    }

    function test_reverts_on_deadline() public {
        Position.Action memory a = _action(OPEN);
        a.deadline = 0;
        vm.prank(user);
        vm.expectRevert(bytes("deadline"));
        pos.execute(a, "", _swapCall(address(usdc), address(weth), S, C));
    }

    function test_reverts_on_unlisted_target() public {
        Position.Action memory a = _action(OPEN);
        Position.SwapCall memory s = _swapCall(address(usdc), address(weth), S, C);
        s.target = makeAddr("evil");
        vm.prank(user);
        vm.expectRevert(bytes("target"));
        pos.execute(a, "", s);
    }

    function test_flash_callback_guards() public {
        vm.expectRevert(bytes("flash-sender"));
        pos.onMorphoFlashLoan(1, "");

        vm.prank(address(morpho));
        vm.expectRevert(bytes("flash-ctx"));
        pos.onMorphoFlashLoan(1, "garbage");
    }

    function test_trigger_blocks_early_stop() public {
        _open(); // HF = 1.2
        Position.Action memory a = _action(REDUCE);
        a.flash = 100e6;
        a.repayAmount = 100e6;
        a.maxSell = 0.04e18;
        a.minOut = 100e6;
        a.triggerHealthFactor = 1.1e18; // stop only fires below 1.1
        vm.prank(user);
        vm.expectRevert(bytes("trigger"));
        pos.execute(a, "", _swapCall(address(weth), address(usdc), 0.04e18, 100e6));
    }

    // --- factory ---

    function test_factory_predicts_and_deploys() public {
        address predicted = factory.positionOf(user, 1);
        address deployed = factory.deploy(user, 1);
        assertEq(deployed, predicted);
        assertEq(Position(deployed).owner(), user);

        assertEq(factory.deploy(user, 1), deployed, "second deploy is a no-op");

        vm.expectRevert(bytes("initialized"));
        Position(deployed).initialize(makeAddr("attacker"));
    }
}
