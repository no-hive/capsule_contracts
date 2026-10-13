// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {VestingFactory} from "./VestingFactory.sol";
import {ERC20BatchDistributor} from "./ERC20BatchDistributor.sol";
import {ERC721ScheduledLocker} from "./ERC721ScheduledLocker.sol";
import {ThousandYearVault} from "./ThousandYearVault.sol";
import {IERC20Burnable, IERC721Burnable} from "./IBurnable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Creates locks and vesting, sends batches, and handles asset disposal.
/// @dev Set nativeBurn only for a verified burn implementation. Failed burns revert.
contract AssetRouter is Ownable, VestingFactory, ERC20BatchDistributor, ERC721ScheduledLocker {
    using SafeERC20 for IERC20;
    uint256 public constant ACTION_REWARD = 10 ether;
    ThousandYearVault public immutable disposalVault;
    IERC20 public rewardToken;
    address private burningCollection;
    address private burningOwner;
    uint256 private burningId;
    error InvalidDisposal();
    error IncorrectBurn();
    error IncorrectDeposit();
    error WrongBeneficiary();
    error InvalidRewardToken();
    error UnsupportedRewardTransfer();
    event ERC20Burned(address indexed sender, address indexed token, uint256 amount);
    event ERC721Burned(address indexed sender, address indexed collection, uint256 indexed tokenId);
    event DisposalLocked(
        address indexed sender,
        address indexed asset,
        uint256 indexed depositId,
        bool isNFT,
        uint256 quantity,
        uint64 unlockAt,
        address vault
    );
    event DisposalLockReleased(
        address indexed caller,
        address indexed beneficiary,
        uint256 indexed depositId,
        address asset,
        bool isNFT,
        uint256 quantity,
        address destination
    );
    event RewardTokenUpdated(address indexed previousToken, address indexed newToken);
    event ActionRewardPaid(address indexed recipient, address indexed token, uint256 amount);

    constructor() Ownable(msg.sender) {
        disposalVault = new ThousandYearVault();
    }

    /// @notice Changes the ERC20 paid from this router for completed actions.
    function setRewardToken(address newRewardToken) external onlyOwner {
        if (newRewardToken.code.length == 0) revert InvalidRewardToken();
        address previousToken = address(rewardToken);
        rewardToken = IERC20(newRewardToken);
        emit RewardTokenUpdated(previousToken, newRewardToken);
    }

    /// @notice Backwards-compatible entrypoint that does not request an action reward.
    function disposeERC20(address token, uint256 amount, bool nativeBurn) external nonReentrant {
        _disposeERC20(token, amount, nativeBurn, false);
    }

    function disposeERC20(address token, uint256 amount, bool nativeBurn, bool wantsReward) external nonReentrant {
        _disposeERC20(token, amount, nativeBurn, wantsReward);
    }

    function _disposeERC20(address token, uint256 amount, bool nativeBurn, bool wantsReward) private {
        if (token.code.length == 0 || amount == 0) revert InvalidDisposal();
        IERC20 asset = IERC20(token);
        if (nativeBurn) {
            uint256 beforeBalance = asset.balanceOf(address(this));
            uint256 beforeSupply = asset.totalSupply();
            asset.safeTransferFrom(msg.sender, address(this), amount);
            if (asset.balanceOf(address(this)) - beforeBalance != amount) revert IncorrectDeposit();
            IERC20Burnable(token).burn(amount);
            if (
                asset.balanceOf(address(this)) != beforeBalance || beforeSupply < amount
                    || asset.totalSupply() != beforeSupply - amount
            ) revert IncorrectBurn();
            emit ERC20Burned(msg.sender, token, amount);
        } else {
            (uint256 id, uint64 unlockAt) = disposalVault.record(msg.sender, token, amount, false);
            uint256 beforeBalance = asset.balanceOf(address(disposalVault));
            asset.safeTransferFrom(msg.sender, address(disposalVault), amount);
            if (asset.balanceOf(address(disposalVault)) - beforeBalance != amount) revert IncorrectDeposit();
            emit DisposalLocked(msg.sender, token, id, false, amount, unlockAt, address(disposalVault));
        }
        _rewardAction(msg.sender, wantsReward);
    }

    /// @notice Backwards-compatible entrypoint that does not request an action reward.
    function disposeERC721(address collection, uint256 tokenId, bool nativeBurn) external nonReentrant {
        _disposeERC721(collection, tokenId, nativeBurn, false);
    }

    function disposeERC721(address collection, uint256 tokenId, bool nativeBurn, bool wantsReward)
        external
        nonReentrant
    {
        _disposeERC721(collection, tokenId, nativeBurn, wantsReward);
    }

    function _disposeERC721(address collection, uint256 tokenId, bool nativeBurn, bool wantsReward) private {
        if (collection.code.length == 0 || IERC721(collection).ownerOf(tokenId) != msg.sender) {
            revert InvalidDisposal();
        }
        if (nativeBurn) {
            uint256 beforeCount = IERC721(collection).balanceOf(address(this));
            burningCollection = collection;
            burningOwner = msg.sender;
            burningId = tokenId;
            IERC721(collection).safeTransferFrom(msg.sender, address(this), tokenId);
            if (IERC721(collection).ownerOf(tokenId) != address(this)) revert IncorrectDeposit();
            IERC721Burnable(collection).burn(tokenId);
            if (IERC721(collection).balanceOf(address(this)) != beforeCount) revert IncorrectBurn();
            (bool ok, bytes memory result) = collection.staticcall(abi.encodeCall(IERC721.ownerOf, (tokenId)));
            if (ok && (result.length != 32 || abi.decode(result, (address)) != address(0))) revert IncorrectBurn();
            delete burningCollection;
            delete burningOwner;
            delete burningId;
            emit ERC721Burned(msg.sender, collection, tokenId);
        } else {
            (uint256 id, uint64 unlockAt) = disposalVault.record(msg.sender, collection, tokenId, true);
            IERC721(collection).safeTransferFrom(msg.sender, address(disposalVault), tokenId);
            if (IERC721(collection).ownerOf(tokenId) != address(disposalVault)) revert IncorrectDeposit();
            emit DisposalLocked(msg.sender, collection, id, true, tokenId, unlockAt, address(disposalVault));
        }
        _rewardAction(msg.sender, wantsReward);
    }

    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        public
        view
        override
        returns (bytes4)
    {
        if (
            burningCollection != address(0) && msg.sender == burningCollection && operator == address(this)
                && from == burningOwner && tokenId == burningId
        ) {
            return IERC721Receiver.onERC721Received.selector;
        }
        return super.onERC721Received(operator, from, tokenId, data);
    }

    /// @notice Backwards-compatible entrypoint that does not request an action reward.
    function releaseDisposalLock(uint256 id) external nonReentrant {
        (address beneficiary,,,,,) = disposalVault.deposits(id);
        _releaseDisposalAndReward(id, beneficiary, false, false);
    }

    function releaseDisposalLock(uint256 id, bool wantsReward) external nonReentrant {
        (address beneficiary,,,,,) = disposalVault.deposits(id);
        _releaseDisposalAndReward(id, beneficiary, false, wantsReward);
    }

    /// @notice Backwards-compatible entrypoint that does not request an action reward.
    function releaseDisposalLockTo(uint256 id, address destination) external nonReentrant {
        _releaseDisposalAndReward(id, destination, true, false);
    }

    function releaseDisposalLockTo(uint256 id, address destination, bool wantsReward) external nonReentrant {
        _releaseDisposalAndReward(id, destination, true, wantsReward);
    }

    function _releaseDisposalAndReward(uint256 id, address destination, bool custom, bool wantsReward) private {
        _releaseDisposal(id, destination, custom);
        _rewardAction(msg.sender, wantsReward);
    }

    function _releaseDisposal(uint256 id, address destination, bool custom) private {
        if (destination == address(this) || destination == address(disposalVault)) revert InvalidDisposal();
        (address beneficiary, address asset, uint256 quantity,, bool isNFT,) = disposalVault.deposits(id);
        if (custom && msg.sender != beneficiary) revert WrongBeneficiary();
        disposalVault.release(id, destination);
        emit DisposalLockReleased(msg.sender, beneficiary, id, asset, isNFT, quantity, destination);
    }

    function _validVestingBeneficiary(address beneficiary) internal view override returns (bool) {
        return super._validVestingBeneficiary(beneficiary) && beneficiary != address(disposalVault);
    }

    function _validNFTBeneficiary(address beneficiary) internal view override returns (bool) {
        return super._validNFTBeneficiary(beneficiary) && beneficiary != address(disposalVault);
    }

    function _rewardAction(address recipient, bool wantsReward) internal override {
        if (!wantsReward) return;
        IERC20 token = rewardToken;
        if (address(token) == address(0)) revert InvalidRewardToken();
        uint256 beforeBalance = token.balanceOf(recipient);
        token.safeTransfer(recipient, ACTION_REWARD);
        if (token.balanceOf(recipient) - beforeBalance != ACTION_REWARD) revert UnsupportedRewardTransfer();
        emit ActionRewardPaid(recipient, address(token), ACTION_REWARD);
    }
}
