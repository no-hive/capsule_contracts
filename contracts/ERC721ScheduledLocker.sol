// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Holds each NFT until its release timestamp.
/// @dev Accepts only expected safe transfers. Plain transferFrom cannot be blocked.
contract ERC721ScheduledLocker is IERC721Receiver, ReentrancyGuard {
    struct Lock {
        address beneficiary;
        uint64 unlockAt;
    }
    mapping(address => mapping(uint256 => Lock)) public locks;
    address private expectedToken;
    address private expectedFrom;
    uint256 private expectedId;

    error InvalidLock();
    error NotReleasable();
    error UnsolicitedTransfer();
    event Locked(
        address indexed creator, address indexed token, uint256 indexed tokenId, address beneficiary, uint64 unlockAt
    );
    event Released(address indexed token, uint256 indexed tokenId, address indexed beneficiary, address destination);

    function lock(address token, uint256 tokenId, address beneficiary, uint64 unlockAt) external nonReentrant {
        if (
            token.code.length == 0 || !_validNFTBeneficiary(beneficiary) || unlockAt <= block.timestamp
                || locks[token][tokenId].beneficiary != address(0) || IERC721(token).ownerOf(tokenId) != msg.sender
        ) revert InvalidLock();
        locks[token][tokenId] = Lock(beneficiary, unlockAt);
        expectedToken = token;
        expectedFrom = msg.sender;
        expectedId = tokenId;
        IERC721(token).safeTransferFrom(msg.sender, address(this), tokenId);
        if (IERC721(token).ownerOf(tokenId) != address(this)) revert InvalidLock();
        delete expectedToken;
        delete expectedFrom;
        delete expectedId;
        emit Locked(msg.sender, token, tokenId, beneficiary, unlockAt);
    }

    function _validNFTBeneficiary(address beneficiary) internal view virtual returns (bool) {
        return beneficiary != address(0) && beneficiary != address(this);
    }

    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata)
        public
        view
        virtual
        returns (bytes4)
    {
        if (
            expectedToken == address(0) || msg.sender != expectedToken || operator != address(this)
                || from != expectedFrom || tokenId != expectedId
        ) revert UnsolicitedTransfer();
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice Anyone can release the NFT to its beneficiary after the deadline.
    function release(address token, uint256 tokenId) external nonReentrant {
        _release(token, tokenId, locks[token][tokenId].beneficiary, false);
    }

    /// @notice Lets the beneficiary choose a destination after the deadline.
    function releaseTo(address token, uint256 tokenId, address destination) external nonReentrant {
        _release(token, tokenId, destination, true);
    }

    function _release(address token, uint256 tokenId, address destination, bool custom) private {
        Lock memory item = locks[token][tokenId];
        if (
            item.beneficiary == address(0) || block.timestamp < item.unlockAt || destination == address(0)
                || destination == address(this) || (custom && msg.sender != item.beneficiary)
        ) revert NotReleasable();
        delete locks[token][tokenId];
        IERC721(token).safeTransferFrom(address(this), destination, tokenId);
        emit Released(token, tokenId, item.beneficiary, destination);
    }
}
