// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Hook used by router modules to optionally reward a completed action.
abstract contract Rewardable {
    function _rewardAction(address recipient, bool wantsReward) internal virtual;
}
