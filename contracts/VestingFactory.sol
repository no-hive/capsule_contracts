// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";
import {VestingWalletCliff} from "@openzeppelin/contracts/finance/VestingWalletCliff.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

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
contract VestingFactory is ReentrancyGuard {
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

    function createVesting(
        address token,
        uint256 amount,
        address beneficiary,
        uint64 start,
        uint64 duration,
        uint64 cliff
    ) external nonReentrant returns (address wallet) {
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
    }

    function _validVestingBeneficiary(address beneficiary) internal view virtual returns (bool) {
        return beneficiary != address(0) && beneficiary != address(this);
    }

    /// @notice Releases vested tokens to the beneficiary and emits a router event.
    function releaseVesting(address wallet, address token) external nonReentrant {
        if (!isVestingWallet[wallet]) revert UnknownWallet();
        FixedBeneficiaryVesting target = FixedBeneficiaryVesting(payable(wallet));
        uint256 beforeReleased = target.released(token);
        target.release(token);
        emit VestingReleased(msg.sender, wallet, token, target.owner(), target.released(token) - beforeReleased);
    }

    /// @notice Releases vested native currency to the beneficiary.
    function releaseVestingNative(address wallet) external nonReentrant {
        if (!isVestingWallet[wallet]) revert UnknownWallet();
        FixedBeneficiaryVesting target = FixedBeneficiaryVesting(payable(wallet));
        uint256 beforeReleased = target.released();
        target.release();
        emit NativeVestingReleased(msg.sender, wallet, target.owner(), target.released() - beforeReleased);
    }
}
