// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";
import {VestingWalletCliff} from "@openzeppelin/contracts/finance/VestingWalletCliff.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Rewardable} from "./Rewardable.sol";

/// @notice Vesting wallet with a fixed beneficiary and router-controlled releases.
contract FixedBeneficiaryVesting is VestingWalletCliff {
    address public immutable controller;
    error FixedBeneficiary();
    error OnlyController();

    constructor(address beneficiary, uint64 start, uint64 duration, uint64 cliff)
        VestingWallet(beneficiary, start, duration)
        VestingWalletCliff(cliff)
    {
        controller = msg.sender;
    }

    function transferOwnership(address) public pure override {
        revert FixedBeneficiary();
    }

    function renounceOwnership() public pure override {
        revert FixedBeneficiary();
    }

    function release(address token) public override {
        if (msg.sender != controller) revert OnlyController();
        super.release(token);
    }

    function release() public override {
        if (msg.sender != controller) revert OnlyController();
        super.release();
    }
}

/// @notice Creates and funds an OpenZeppelin vesting wallet in one transaction.
abstract contract VestingFactory is Rewardable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    mapping(address => bool) public isVestingWallet;
    error InvalidParameters();
    error UnsupportedFunding();
    error UnknownWallet();
    event VestingCreated(
        address indexed creator,
        address indexed beneficiary,
        address indexed wallet,
        address token,
        uint256 amount,
        uint64 start,
        uint64 duration,
        uint64 cliff
    );
    event VestingReleased(
        address indexed caller, address indexed wallet, address indexed token, address beneficiary, uint256 amount
    );
    event NativeVestingReleased(
        address indexed caller, address indexed wallet, address indexed beneficiary, uint256 amount
    );

    /// @notice Backwards-compatible entrypoint that does not request an action reward.
    function createVesting(
        address token,
        uint256 amount,
        address beneficiary,
        uint64 start,
        uint64 duration,
        uint64 cliff
    ) external nonReentrant returns (address wallet) {
        return _createVesting(token, amount, beneficiary, start, duration, cliff, false);
    }

    function createVesting(
        address token,
        uint256 amount,
        address beneficiary,
        uint64 start,
        uint64 duration,
        uint64 cliff,
        bool wantsReward
    ) external nonReentrant returns (address wallet) {
        return _createVesting(token, amount, beneficiary, start, duration, cliff, wantsReward);
    }

    function _createVesting(
        address token,
        uint256 amount,
        address beneficiary,
        uint64 start,
        uint64 duration,
        uint64 cliff,
        bool wantsReward
    ) private returns (address wallet) {
        if (
            token.code.length == 0 || amount == 0 || !_validVestingBeneficiary(beneficiary) || start < block.timestamp
                || cliff > duration || uint256(start) + duration > type(uint64).max
        ) revert InvalidParameters();
        wallet = address(new FixedBeneficiaryVesting(beneficiary, start, duration, cliff));
        isVestingWallet[wallet] = true;
        IERC20 asset = IERC20(token);
        uint256 beforeBalance = asset.balanceOf(wallet);
        asset.safeTransferFrom(msg.sender, wallet, amount);
        if (asset.balanceOf(wallet) - beforeBalance != amount) revert UnsupportedFunding();
        emit VestingCreated(msg.sender, beneficiary, wallet, token, amount, start, duration, cliff);
        _rewardAction(msg.sender, wantsReward);
    }

    function _validVestingBeneficiary(address beneficiary) internal view virtual returns (bool) {
        return beneficiary != address(0) && beneficiary != address(this);
    }

    /// @notice Releases vested tokens to the beneficiary and emits a router event.
    /// @notice Backwards-compatible entrypoint that does not request an action reward.
    function releaseVesting(address wallet, address token) external nonReentrant {
        _releaseVesting(wallet, token, false);
    }

    function releaseVesting(address wallet, address token, bool wantsReward) external nonReentrant {
        _releaseVesting(wallet, token, wantsReward);
    }

    function _releaseVesting(address wallet, address token, bool wantsReward) private {
        if (!isVestingWallet[wallet]) revert UnknownWallet();
        FixedBeneficiaryVesting target = FixedBeneficiaryVesting(payable(wallet));
        uint256 beforeReleased = target.released(token);
        target.release(token);
        uint256 releasedAmount = target.released(token) - beforeReleased;
        emit VestingReleased(msg.sender, wallet, token, target.owner(), releasedAmount);
        if (releasedAmount != 0) _rewardAction(msg.sender, wantsReward);
    }

    /// @notice Releases vested native currency to the beneficiary.
    /// @notice Backwards-compatible entrypoint that does not request an action reward.
    function releaseVestingNative(address wallet) external nonReentrant {
        _releaseVestingNative(wallet, false);
    }

    function releaseVestingNative(address wallet, bool wantsReward) external nonReentrant {
        _releaseVestingNative(wallet, wantsReward);
    }

    function _releaseVestingNative(address wallet, bool wantsReward) private {
        if (!isVestingWallet[wallet]) revert UnknownWallet();
        FixedBeneficiaryVesting target = FixedBeneficiaryVesting(payable(wallet));
        uint256 beforeReleased = target.released();
        target.release();
        uint256 releasedAmount = target.released() - beforeReleased;
        emit NativeVestingReleased(msg.sender, wallet, target.owner(), releasedAmount);
        if (releasedAmount != 0) _rewardAction(msg.sender, wantsReward);
    }
}
