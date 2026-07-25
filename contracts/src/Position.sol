// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
}

interface IMorpho {
    /// Sends `assets` to msg.sender, calls onMorphoFlashLoan on msg.sender,
    /// then pulls `assets` back via transferFrom. Zero fee.
    function flashLoan(address token, uint256 assets, bytes calldata data) external;
}

interface IPool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf)
        external;
    function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf)
        external
        returns (uint256);
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function setUserEMode(uint8 categoryId) external;
    function setUserUseReserveAsCollateral(address asset, bool useAsCollateral) external;
    function getUserAccountData(address user)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256 healthFactor);
}

/// @notice One isolated Aave V3 position per CREATE2 clone. Executes Bebop RFQ
/// self-execution calldata (gasless=false) that this contract did not build, so
/// every swap is verified by balance deltas behind an immutable target allow-list —
/// never by trusting return data.
///
/// SECURITY GUARANTEE (why the signature will bind bounds, not calldata):
/// a Bebop quote is fetched seconds before execution, so v2 gasless signatures
/// cannot commit to swap calldata. Instead the Action binds the economics —
/// maxSell, minOut, minHealthFactor, deadline, receiver, token pair — and the
/// relayer's only degree of freedom is price improvement. This is deliberate.
contract Position {
    uint8 public constant OPEN = 0;
    uint8 public constant INCREASE = 1;
    uint8 public constant REDUCE = 2;

    IMorpho public immutable MORPHO;
    IPool public immutable POOL;
    address public immutable BEBOP_ROUTER;
    address public immutable BEBOP_SETTLEMENT;

    address public owner;
    uint256 public nonce;

    // Lifecycle events (architecture §7 step 19) — for indexers / keepers / the UI.
    event Opened(address indexed owner, address collateral, address debt, uint256 equity, uint256 healthFactor);
    event Increased(address indexed owner, uint256 healthFactor);
    event Reduced(address indexed owner, uint256 healthFactor);
    event Closed(address indexed owner);

    /// keccak of the flash payload while a loan is in flight. Doubles as the
    /// reentrancy lock; set to 1 ("consumed") on callback entry so a duplicate
    /// callback in the same tx reverts. Morpho passes no initiator, so this
    /// flag is doing real work.
    bytes32 transient flashCtx;

    struct Action {
        address position;
        uint256 nonce;
        uint256 deadline;
        uint8 mode; // OPEN | INCREASE | REDUCE
        address collateral;
        address debt;
        uint256 equity; // OPEN: pulled from owner
        uint256 maxSell; // swap input cap; REDUCE: also the collateral withdraw amount
        uint256 minOut; // swap output floor (= quote's buy amount)
        uint256 flash; // OPEN/REDUCE: flash size. INCREASE: extra borrow amount.
        uint256 repayAmount; // REDUCE; type(uint256).max = full close
        uint8 eMode; // OPEN: category entered after supply, before borrow (0 = none)
        uint256 minHealthFactor; // 1e18 scale, asserted after every action
        address receiver; // REDUCE residual sweep destination
        uint256 triggerHealthFactor; // 0 = none; else require live HF < this (stop-loss)
    }

    struct SwapCall {
        address target; // quote's tx.to — must be on the allow-list
        address approvalTarget; // from the quote response — must be on the allow-list
        bytes data; // quote's tx.data, opaque
    }

    constructor(address morpho, address pool, address bebopRouter, address bebopSettlement) {
        MORPHO = IMorpho(morpho);
        POOL = IPool(pool);
        BEBOP_ROUTER = bebopRouter;
        BEBOP_SETTLEMENT = bebopSettlement;
        owner = address(0xdead); // brick the implementation; clones start at 0
    }

    function initialize(address owner_) external {
        require(owner == address(0), "initialized");
        require(owner_ != address(0), "owner");
        owner = owner_;
    }

    /// v1: sig must be empty and msg.sender must be the owner.
    /// v2: sig is an EIP-712 signature over Action and anyone may relay.
    function execute(Action calldata a, bytes calldata sig, SwapCall calldata swap) external {
        require(msg.sender == owner && sig.length == 0, "auth");
        require(a.position == address(this), "position");
        require(block.timestamp <= a.deadline, "deadline");
        require(a.nonce == nonce++, "nonce");
        require(a.collateral != a.debt, "pair");
        require(swap.target == BEBOP_ROUTER || swap.target == BEBOP_SETTLEMENT, "target");
        require(swap.approvalTarget == BEBOP_ROUTER || swap.approvalTarget == BEBOP_SETTLEMENT, "approvalTarget");
        require(flashCtx == 0, "reentrant");
        if (a.triggerHealthFactor != 0) {
            require(_healthFactor() < a.triggerHealthFactor, "trigger");
        }

        if (a.mode == INCREASE) {
            // No flash needed: borrow first (capped by Aave's availableBorrows), then swap, then supply.
            POOL.borrow(a.debt, a.flash, 2, 0, address(this));
            _swap(swap, a.debt, a.collateral, a.maxSell, a.minOut);
            _supplyAll(a.collateral);
        } else {
            require(a.mode == OPEN || a.mode == REDUCE, "mode");
            if (a.mode == OPEN) {
                require(IERC20(a.debt).transferFrom(owner, address(this), a.equity), "pull");
            }
            bytes memory data = abi.encode(a, swap);
            flashCtx = keccak256(data);
            MORPHO.flashLoan(a.debt, a.flash, data);
            flashCtx = 0;
        }

        uint256 hf = _healthFactor();
        require(hf >= a.minHealthFactor, "health");
        if (a.mode == OPEN) emit Opened(owner, a.collateral, a.debt, a.equity, hf);
        else if (a.mode == INCREASE) emit Increased(owner, hf);
        else if (a.repayAmount == type(uint256).max) emit Closed(owner);
        else emit Reduced(owner, hf);
    }

    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external {
        require(msg.sender == address(MORPHO), "flash-sender");
        require(flashCtx == keccak256(data), "flash-ctx");
        flashCtx = bytes32(uint256(1)); // consumed

        (Action memory a, SwapCall memory swap) = abi.decode(data, (Action, SwapCall));

        if (a.mode == OPEN) {
            // Holds equity + flash of debt token. Swap all of it, supply the full
            // realized collateral balance (never the quoted minimum), enter eMode
            // after supply / before borrow, borrow exactly the flash size back.
            _swap(swap, a.debt, a.collateral, a.maxSell, a.minOut);
            _supplyAll(a.collateral);
            if (a.eMode != 0) {
                POOL.setUserEMode(a.eMode);
                POOL.setUserUseReserveAsCollateral(a.collateral, true);
            }
            POOL.borrow(a.debt, assets, 2, 0, address(this));
        } else {
            // REDUCE: debt-first ordering so Aave's checks never see an invalid
            // intermediate state. MAX repay/withdraw on full close so interest
            // accrual can't strand dust.
            bool fullClose = a.repayAmount == type(uint256).max;
            _approve(a.debt, address(POOL), assets);
            POOL.repay(a.debt, a.repayAmount, 2, address(this));
            _approve(a.debt, address(POOL), 0);
            POOL.withdraw(a.collateral, fullClose ? type(uint256).max : a.maxSell, address(this));
            _swap(swap, a.collateral, a.debt, a.maxSell, a.minOut);
            // Sweep residuals of both tokens, keeping exactly `assets` for Morpho's pull.
            uint256 debtBal = IERC20(a.debt).balanceOf(address(this));
            if (debtBal > assets) require(IERC20(a.debt).transfer(a.receiver, debtBal - assets), "sweep-debt");
            uint256 colBal = IERC20(a.collateral).balanceOf(address(this));
            if (colBal != 0) require(IERC20(a.collateral).transfer(a.receiver, colBal), "sweep-col");
        }

        _approve(a.debt, address(MORPHO), assets); // Morpho pulls exactly this back
    }

    /// Rescue stranded dust. Positions should never hold loose tokens between txs.
    function skim(address token, address to) external {
        require(msg.sender == owner, "auth");
        require(IERC20(token).transfer(to, IERC20(token).balanceOf(address(this))), "skim");
    }

    /// Executes opaque quote calldata; trusts nothing but its own balance deltas.
    function _swap(SwapCall memory s, address sellToken, address buyToken, uint256 maxSell, uint256 minOut) internal {
        uint256 sellBefore = IERC20(sellToken).balanceOf(address(this));
        uint256 buyBefore = IERC20(buyToken).balanceOf(address(this));
        _approve(sellToken, s.approvalTarget, maxSell);
        (bool ok,) = s.target.call(s.data);
        require(ok, "swap");
        _approve(sellToken, s.approvalTarget, 0);
        require(sellBefore - IERC20(sellToken).balanceOf(address(this)) <= maxSell, "maxSell");
        require(IERC20(buyToken).balanceOf(address(this)) - buyBefore >= minOut, "minOut");
        require(IERC20(sellToken).allowance(address(this), s.approvalTarget) == 0, "allowance");
    }

    function _supplyAll(address token) internal {
        uint256 bal = IERC20(token).balanceOf(address(this));
        _approve(token, address(POOL), bal);
        POOL.supply(token, bal, address(this), 0);
    }

    function _approve(address token, address spender, uint256 amount) internal {
        require(IERC20(token).approve(spender, amount), "approve");
    }

    /// Aave returns type(uint256).max when the position has no debt.
    function _healthFactor() internal view returns (uint256 hf) {
        (,,,,, hf) = POOL.getUserAccountData(address(this));
    }
}
