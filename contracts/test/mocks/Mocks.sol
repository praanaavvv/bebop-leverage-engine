// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "../../src/Position.sol";

contract MockERC20 {
    string public name;
    uint8 public decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory name_, uint8 decimals_) {
        name = name_;
        decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }


    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

interface IMorphoFlashBorrower {
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external;
}

/// Morpho Blue flash-loan shape: send to caller, call back caller, pull back. Zero fee.
contract MockMorpho {
    function flashLoan(address token, uint256 assets, bytes calldata data) external {
        IERC20(token).transfer(msg.sender, assets);
        IMorphoFlashBorrower(msg.sender).onMorphoFlashLoan(assets, data);
        IERC20(token).transferFrom(msg.sender, address(this), assets);
    }
}


/// Firm-price RFQ fill: pulls exactly sellAmount from the caller, pushes exactly
/// buyAmount (must be pre-funded). Mirrors Bebop self-execution semantics.
contract MockBebopRouter {
    function swap(address sellToken, address buyToken, uint256 sellAmount, uint256 buyAmount) external {
        IERC20(sellToken).transferFrom(msg.sender, address(this), sellAmount);
        IERC20(buyToken).transfer(msg.sender, buyAmount);
    }
}

/// Aave V3 Pool reduced to what Position touches: per-user collateral/debt books,
/// fixed 1e18 prices, LT = 0.8, HF checks on borrow and withdraw, MAX semantics
/// on repay/withdraw, HF = type(uint256).max when debt-free.
contract MockPool {
    uint256 public constant LT = 0.8e18;

    struct Reserve {
        uint256 price; // 1e18 per whole token
        uint8 decimals;
    }

    mapping(address => Reserve) public reserves;
    mapping(address => mapping(address => uint256)) public collateralOf; // user => asset => amount
    mapping(address => mapping(address => uint256)) public debtOf;
    address[] public assets;

    function setReserve(address asset, uint256 price, uint8 decimals_) external {
        if (reserves[asset].price == 0) assets.push(asset);
        reserves[asset] = Reserve(price, decimals_);
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        collateralOf[onBehalfOf][asset] += amount;
    }

    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16, address onBehalfOf) external {
        require(interestRateMode == 2, "rate"); // stable removed in V3.3
        require(msg.sender == onBehalfOf, "delegation"); // credit delegation not modeled
        debtOf[onBehalfOf][asset] += amount;
        IERC20(asset).transfer(msg.sender, amount);
        require(_hf(onBehalfOf) >= 1e18, "ltv");
    }

    function repay(address asset, uint256 amount, uint256, address onBehalfOf) external returns (uint256) {
        uint256 debt = debtOf[onBehalfOf][asset];
        uint256 pay = amount >= debt ? debt : amount; // MAX semantics
        IERC20(asset).transferFrom(msg.sender, address(this), pay);
        debtOf[onBehalfOf][asset] = debt - pay;
        return pay;
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        uint256 bal = collateralOf[msg.sender][asset];
        uint256 amt = amount == type(uint256).max ? bal : amount; // MAX semantics
        collateralOf[msg.sender][asset] = bal - amt;
        IERC20(asset).transfer(to, amt);
        require(_hf(msg.sender) >= 1e18, "hf");
        return amt;
    }

    function setUserEMode(uint8) external {}
    function setUserUseReserveAsCollateral(address, bool) external {}

    function getUserAccountData(address user)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        return (0, 0, 0, 0, 0, _hf(user));
    }

    function _hf(address user) internal view returns (uint256) {
        uint256 col;
        uint256 debt;
        for (uint256 i; i < assets.length; i++) {
            Reserve memory r = reserves[assets[i]];
            col += collateralOf[user][assets[i]] * r.price / 10 ** r.decimals;
            debt += debtOf[user][assets[i]] * r.price / 10 ** r.decimals;
        }
        if (debt == 0) return type(uint256).max;
        return col * LT / debt;
    }
}
