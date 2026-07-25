// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Position, IERC20} from "../../src/Position.sol";
import {PositionFactory} from "../../src/PositionFactory.sol";
import {MockBebopRouter} from "../mocks/Mocks.sol";

interface IAaveOracle {
    function getAssetPrice(address asset) external view returns (uint256); // 8-dec USD
}

/// Layer 2: real Aave V3 + real Morpho Blue on a Base fork, swap mocked at the
/// Aave oracle price. Catches Aave semantics bugs without needing a live quote.
/// Run: BASE_RPC=<url> forge test --match-contract AaveForkTest
contract AaveForkTest is Test {
    address constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address constant ORACLE = 0x2Cc0Fc26eD4563A5ce5e8bdcfe1A2878676Ae156;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant A_WETH = 0xD4a0e0b9149BCee3C920d2E00b5dE09138fd8bb7;
    address constant VDEBT_USDC = 0x59dca05b6c26dbd64b5381374aAaC5CD05644C28;

    uint256 constant E = 100e6; // equity
    uint256 constant L = 200e6; // flash (3x)
    uint256 constant S = 300e6; // swap size

    MockBebopRouter router;
    Position pos;
    address user = makeAddr("user");

    function setUp() public {
        vm.createSelectFork(vm.envOr("BASE_RPC", string("https://base-rpc.publicnode.com")));

        router = new MockBebopRouter();
        Position impl = new Position(MORPHO, POOL, address(router), address(router));
        PositionFactory factory = new PositionFactory(address(impl));
        pos = Position(factory.deploy(user, 0));

        deal(USDC, user, E);
        deal(WETH, address(router), 100e18); // maker inventory
        deal(USDC, address(router), 1_000_000e6);
        vm.prank(user);
        IERC20(USDC).approve(address(pos), type(uint256).max);
    }

    // oracle-fair conversions, so mock fills match what Aave thinks the assets are worth
    function _usdcToWeth(uint256 usdcAmt) internal view returns (uint256) {
        return usdcAmt * IAaveOracle(ORACLE).getAssetPrice(USDC) * 1e18
            / (1e6 * IAaveOracle(ORACLE).getAssetPrice(WETH));
    }

    function _wethToUsdc(uint256 wethAmt) internal view returns (uint256) {
        return wethAmt * IAaveOracle(ORACLE).getAssetPrice(WETH) * 1e6
            / (1e18 * IAaveOracle(ORACLE).getAssetPrice(USDC));
    }

    function _action(uint8 mode) internal view returns (Position.Action memory a) {
        a.position = address(pos);
        a.nonce = pos.nonce();
        a.deadline = block.timestamp + 60;
        a.mode = mode;
        a.collateral = WETH;
        a.debt = USDC;
        a.minHealthFactor = 1.05e18;
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

    function _hf() internal view returns (uint256 hf) {
        (,,,,, hf) = Position(pos).POOL().getUserAccountData(address(pos));
    }

    function _open() internal {
        uint256 wethOut = _usdcToWeth(S);
        Position.Action memory a = _action(0);
        a.equity = E;
        a.flash = L;
        a.maxSell = S;
        a.minOut = wethOut;
        vm.prank(user);
        pos.execute(a, "", _swapCall(USDC, WETH, S, wethOut));
    }

    function test_open_on_real_aave() public {
        _open();

        assertApproxEqAbs(IERC20(A_WETH).balanceOf(address(pos)), _usdcToWeth(S), 2, "aWETH collateral");
        assertApproxEqAbs(IERC20(VDEBT_USDC).balanceOf(address(pos)), L, 2, "USDC variable debt");
        assertEq(IERC20(USDC).balanceOf(address(pos)), 0, "no stranded USDC");
        assertEq(IERC20(WETH).balanceOf(address(pos)), 0, "full balance supplied");
        // 3x at WETH's ~80% liquidation threshold -> HF around 1.2
        assertGt(_hf(), 1.05e18);
        assertLt(_hf(), 1.6e18);
    }

    function test_reduce_partial_on_real_aave() public {
        _open();
        uint256 hfBefore = _hf();

        uint256 wethIn = _usdcToWeth(100e6);
        Position.Action memory a = _action(2);
        a.flash = 100e6;
        a.repayAmount = 100e6;
        a.maxSell = wethIn;
        a.minOut = 100e6;
        vm.prank(user);
        pos.execute(a, "", _swapCall(WETH, USDC, wethIn, 100e6));

        assertApproxEqAbs(IERC20(VDEBT_USDC).balanceOf(address(pos)), 100e6, 2, "half the debt remains");
        assertGt(_hf(), hfBefore, "deleveraging improves HF");
    }

    function test_close_full_on_real_aave() public {
        _open();

        uint256 debt = IERC20(VDEBT_USDC).balanceOf(address(pos));
        uint256 wethBal = IERC20(A_WETH).balanceOf(address(pos));
        uint256 usdcOut = _wethToUsdc(wethBal);

        Position.Action memory a = _action(2);
        a.flash = debt;
        a.repayAmount = type(uint256).max;
        a.maxSell = wethBal;
        a.minOut = usdcOut;
        vm.prank(user);
        pos.execute(a, "", _swapCall(WETH, USDC, wethBal, usdcOut));

        assertEq(IERC20(VDEBT_USDC).balanceOf(address(pos)), 0, "debt fully repaid");
        assertEq(IERC20(A_WETH).balanceOf(address(pos)), 0, "collateral fully withdrawn");
        assertEq(IERC20(USDC).balanceOf(address(pos)), 0, "residual swept");
        // equity comes back minus oracle rounding (no fees/spread in the mock)
        assertApproxEqRel(IERC20(USDC).balanceOf(user), E, 0.01e18, "equity returned");
    }
}
