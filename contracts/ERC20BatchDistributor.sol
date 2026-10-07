// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Sends a batch from the caller to recipients in one transaction.
/// @dev Each recipient must receive the exact amount requested.
contract ERC20BatchDistributor is ReentrancyGuard {
    using SafeERC20 for IERC20;
    error InvalidBatch();
    error UnsupportedTransfer();
    event BatchDistributed(
        address indexed sender, address indexed token, bytes32 indexed batchHash, uint256 total, uint256 count
    );

    function distribute(address token, address[] calldata recipients, uint256[] calldata amounts)
        external
        nonReentrant
    {
        uint256 n = recipients.length;
        if (token.code.length == 0 || n == 0 || n != amounts.length) revert InvalidBatch();
        uint256 total;
        for (uint256 i; i < n; ++i) {
            if (
                recipients[i] == address(0) || recipients[i] == msg.sender || recipients[i] == address(this)
                    || amounts[i] == 0
            ) revert InvalidBatch();
            total += amounts[i];
        }
        IERC20 asset = IERC20(token);
        for (uint256 i; i < n; ++i) {
            uint256 beforeBalance = asset.balanceOf(recipients[i]);
            asset.safeTransferFrom(msg.sender, recipients[i], amounts[i]);
            if (asset.balanceOf(recipients[i]) - beforeBalance != amounts[i]) {
                revert UnsupportedTransfer();
            }
        }
        emit BatchDistributed(
            msg.sender, token, keccak256(abi.encode(msg.sender, token, recipients, amounts)), total, n
        );
    }
}
