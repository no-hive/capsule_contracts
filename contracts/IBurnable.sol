// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev Optional burn extensions. The router takes custody before calling burn.
interface IERC20Burnable {
    function burn(uint256 amount) external;
}

interface IERC721Burnable {
    function burn(uint256 tokenId) external;
}
