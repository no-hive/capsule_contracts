// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Holds disposal deposits for 1000 * 365 days.
contract ThousandYearVault is IERC721Receiver, ReentrancyGuard {
    using SafeERC20 for IERC20;
    uint64 public constant LOCK_DURATION = 1000 * 365 days;
    address public immutable controller;
    uint256 public nextId;

    struct Deposit {
        address beneficiary;
        address asset;
        uint256 quantity; // ERC20 base units or ERC721 tokenId
        uint64 unlockAt;
        bool isNFT;
        bool released;
    }
    mapping(uint256 => Deposit) public deposits;
    address private expectedNFT;
    address private expectedFrom;
    uint256 private expectedId;
    error OnlyController();
    error InvalidDeposit();
    error NotReleasable();
    error UnsolicitedTransfer();

    constructor() {
        controller = msg.sender;
    }
    modifier onlyController() {
        if (msg.sender != controller) revert OnlyController();
        _;
    }

    /// @dev The router records and funds each deposit in the same transaction.
    function record(address beneficiary, address asset, uint256 quantity, bool isNFT)
        external
        onlyController
        returns (uint256 id, uint64 unlockAt)
    {
        if (
            beneficiary == address(0) || beneficiary == address(this) || asset.code.length == 0
                || (!isNFT && quantity == 0) || block.timestamp > type(uint64).max - LOCK_DURATION
        ) {
            revert InvalidDeposit();
        }
        id = nextId++;
        unlockAt = uint64(block.timestamp) + LOCK_DURATION;
        deposits[id] = Deposit(beneficiary, asset, quantity, unlockAt, isNFT, false);
        if (isNFT) {
            expectedNFT = asset;
            expectedFrom = beneficiary;
            expectedId = quantity;
        }
    }

    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata)
        external
        returns (bytes4)
    {
        if (
            expectedNFT == address(0) || msg.sender != expectedNFT || operator != controller || from != expectedFrom
                || tokenId != expectedId
        ) revert UnsolicitedTransfer();
        delete expectedNFT;
        delete expectedFrom;
        delete expectedId;
        return IERC721Receiver.onERC721Received.selector;
    }

    function release(uint256 id, address destination) external onlyController nonReentrant {
        Deposit storage item = deposits[id];
        if (
            item.beneficiary == address(0) || item.released || block.timestamp < item.unlockAt
                || destination == address(0) || destination == address(this)
        ) revert NotReleasable();
        item.released = true;
        if (item.isNFT) IERC721(item.asset).safeTransferFrom(address(this), destination, item.quantity);
        else IERC20(item.asset).safeTransfer(destination, item.quantity);
    }
}
