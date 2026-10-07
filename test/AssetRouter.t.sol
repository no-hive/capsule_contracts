// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {AssetRouter} from "../contracts/AssetRouter.sol";
import {VestingFactory, FixedBeneficiaryVesting} from "../contracts/VestingFactory.sol";
import {ERC20BatchDistributor} from "../contracts/ERC20BatchDistributor.sol";
import {ERC721ScheduledLocker} from "../contracts/ERC721ScheduledLocker.sol";
import {ThousandYearVault} from "../contracts/ThousandYearVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {
    TestToken,
    TestNFT,
    FeeToken,
    SelectiveFalseToken,
    NoReturnToken,
    NonBurnableToken,
    NonBurnableNFT,
    FakeBurnToken,
    FakeBurnNFT,
    MaskedOwnerFakeBurnNFT,
    ReentrantToken,
    ReentrantNFTReceiver,
    NonReceiver
} from "./Mocks.sol";

abstract contract RouterTestBase is Test {
    AssetRouter internal router;
    ThousandYearVault internal vault;
    TestToken internal token;
    TestNFT internal nft;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal stranger = makeAddr("stranger");

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        router = new AssetRouter();
        vault = router.disposalVault();
        token = new TestToken();
        nft = new TestNFT();
        token.mint(alice, 10_000);
        vm.prank(alice);
        token.approve(address(router), 10_000);
        nft.mint(alice, 1);
        vm.prank(alice);
        nft.setApprovalForAll(address(router), true);
    }

    function batch() internal view returns (address[] memory recipients, uint256[] memory amounts) {
        recipients = new address[](2);
        recipients[0] = bob;
        recipients[1] = stranger;
        amounts = new uint256[](2);
        amounts[0] = 100;
        amounts[1] = 200;
    }

    function create(uint64 start, uint64 duration, uint64 cliff) internal returns (FixedBeneficiaryVesting) {
        vm.prank(alice);
        return
            FixedBeneficiaryVesting(payable(router.createVesting(address(token), 1_000, bob, start, duration, cliff)));
    }

    function approveToken(IERC20 asset, uint256 amount) internal {
        vm.prank(alice);
        asset.approve(address(router), amount);
    }

    function approveNFT(IERC721 asset) internal {
        vm.prank(alice);
        asset.setApprovalForAll(address(router), true);
    }

    function assertRouterEvent(bytes32 signature) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(router) && logs[i].topics[0] == signature) return;
        }
        fail("router event missing");
    }
}

contract BatchTest is RouterTestBase {
    function testBatchTransfersDirectlyAndEmitsEvent() public {
        (address[] memory recipients, uint256[] memory amounts) = batch();
        vm.recordLogs();
        vm.prank(alice);
        router.distribute(address(token), recipients, amounts);
        assertEq(token.balanceOf(bob), 100);
        assertEq(token.balanceOf(stranger), 200);
        assertEq(token.balanceOf(address(router)), 0);
        assertEq(token.allowance(alice, address(router)), 9_700);
        assertRouterEvent(keccak256("BatchDistributed(address,address,bytes32,uint256,uint256)"));
    }

    function testBatchCannotSpendAnotherUsersAllowance() public {
        (address[] memory recipients, uint256[] memory amounts) = batch();
        vm.prank(stranger);
        vm.expectRevert();
        router.distribute(address(token), recipients, amounts);
        assertEq(token.balanceOf(alice), 10_000);
    }

    function testBatchRejectsInvalidInputs() public {
        (address[] memory recipients, uint256[] memory amounts) = batch();
        vm.startPrank(alice);
        vm.expectRevert(ERC20BatchDistributor.InvalidBatch.selector);
        router.distribute(address(token), new address[](0), new uint256[](0));
        vm.expectRevert(ERC20BatchDistributor.InvalidBatch.selector);
        router.distribute(address(token), recipients, new uint256[](1));
        recipients[0] = address(0);
        vm.expectRevert(ERC20BatchDistributor.InvalidBatch.selector);
        router.distribute(address(token), recipients, amounts);
        recipients[0] = alice;
        vm.expectRevert(ERC20BatchDistributor.InvalidBatch.selector);
        router.distribute(address(token), recipients, amounts);
        recipients[0] = address(router);
        vm.expectRevert(ERC20BatchDistributor.InvalidBatch.selector);
        router.distribute(address(token), recipients, amounts);
        recipients[0] = bob;
        amounts[0] = 0;
        vm.expectRevert(ERC20BatchDistributor.InvalidBatch.selector);
        router.distribute(address(token), recipients, amounts);
        vm.expectRevert(ERC20BatchDistributor.InvalidBatch.selector);
        router.distribute(alice, recipients, amounts);
        vm.stopPrank();
    }

    function testSecondTransferFailureRollsBackFirstAndAllowance() public {
        SelectiveFalseToken asset = new SelectiveFalseToken();
        asset.mint(alice, 1_000);
        asset.setBlocked(stranger);
        approveToken(asset, 1_000);
        (address[] memory recipients, uint256[] memory amounts) = batch();
        vm.prank(alice);
        vm.expectRevert();
        router.distribute(address(asset), recipients, amounts);
        assertEq(asset.balanceOf(alice), 1_000);
        assertEq(asset.balanceOf(bob), 0);
        assertEq(asset.allowance(alice, address(router)), 1_000);
    }

    function testBatchRejectsTransferFeesAtomically() public {
        FeeToken asset = new FeeToken();
        asset.mint(alice, 1_000);
        approveToken(asset, 1_000);
        (address[] memory recipients, uint256[] memory amounts) = batch();
        vm.prank(alice);
        vm.expectRevert(ERC20BatchDistributor.UnsupportedTransfer.selector);
        router.distribute(address(asset), recipients, amounts);
        assertEq(asset.balanceOf(alice), 1_000);
        assertEq(asset.balanceOf(bob), 0);
        assertEq(asset.totalSupply(), 1_000);
    }

    function testBatchSupportsTokensWithoutReturnValues() public {
        NoReturnToken asset = new NoReturnToken();
        asset.mint(alice, 1_000);
        vm.prank(alice);
        asset.approve(address(router), 1_000);
        (address[] memory recipients, uint256[] memory amounts) = batch();
        vm.prank(alice);
        router.distribute(address(asset), recipients, amounts);
        assertEq(asset.balanceOf(bob), 100);
        assertEq(asset.balanceOf(stranger), 200);
    }

    function testFuzzBatchConservesBalances(uint64 first, uint64 second) public {
        first = uint64(bound(first, 1, 4_000));
        second = uint64(bound(second, 1, 4_000));
        (address[] memory recipients, uint256[] memory amounts) = batch();
        amounts[0] = first;
        amounts[1] = second;
        vm.prank(alice);
        router.distribute(address(token), recipients, amounts);
        assertEq(token.balanceOf(bob), first);
        assertEq(token.balanceOf(stranger), second);
        assertEq(token.balanceOf(alice), 10_000 - uint256(first) - second);
        assertEq(token.totalSupply(), 10_000);
    }
}

contract VestingTest is RouterTestBase {
    function testCliffAccruesFromStartAndReleasesThroughRouter() public {
        uint64 start = uint64(vm.getBlockTimestamp() + 100);
        vm.recordLogs();
        FixedBeneficiaryVesting wallet = create(start, 1_000, 200);
        assertRouterEvent(keccak256("VestingCreated(address,address,address,address,uint256,uint64,uint64,uint64)"));
        assertEq(wallet.controller(), address(router));
        assertTrue(router.isVestingWallet(address(wallet)));
        assertEq(token.balanceOf(address(wallet)), 1_000);
        vm.warp(start + 199);
        assertEq(wallet.releasable(address(token)), 0);
        vm.warp(start + 200);
        assertEq(wallet.releasable(address(token)), 200);
        vm.recordLogs();
        vm.prank(stranger);
        router.releaseVesting(address(wallet), address(token));
        assertEq(token.balanceOf(bob), 200);
        assertRouterEvent(keccak256("VestingReleased(address,address,address,address,uint256)"));
        vm.warp(start + 1_000);
        router.releaseVesting(address(wallet), address(token));
        assertEq(token.balanceOf(bob), 1_000);
        assertEq(token.balanceOf(address(wallet)), 0);
    }

    function testDateLockReleasesAtExactTimestamp() public {
        uint64 unlock = uint64(vm.getBlockTimestamp() + 100);
        FixedBeneficiaryVesting wallet = create(unlock, 0, 0);
        vm.warp(unlock - 1);
        assertEq(wallet.releasable(address(token)), 0);
        vm.warp(unlock);
        router.releaseVesting(address(wallet), address(token));
        assertEq(token.balanceOf(bob), 1_000);
    }

    function testWalletHasFixedBeneficiaryAndController() public {
        FixedBeneficiaryVesting wallet = create(uint64(vm.getBlockTimestamp()), 0, 0);
        vm.startPrank(bob);
        vm.expectRevert(FixedBeneficiaryVesting.FixedBeneficiary.selector);
        wallet.transferOwnership(alice);
        vm.expectRevert(FixedBeneficiaryVesting.FixedBeneficiary.selector);
        wallet.renounceOwnership();
        vm.expectRevert(FixedBeneficiaryVesting.OnlyController.selector);
        wallet.release(address(token));
        vm.expectRevert(FixedBeneficiaryVesting.OnlyController.selector);
        wallet.release();
        vm.stopPrank();
        vm.expectRevert(VestingFactory.UnknownWallet.selector);
        router.releaseVesting(alice, address(token));
        vm.expectRevert(VestingFactory.UnknownWallet.selector);
        router.releaseVestingNative(alice);
    }

    function testVestingRejectsInvalidSchedulesAndBeneficiaries() public {
        uint64 start = uint64(vm.getBlockTimestamp() + 100);
        vm.startPrank(alice);
        vm.expectRevert(VestingFactory.InvalidParameters.selector);
        router.createVesting(address(token), 0, bob, start, 100, 0);
        vm.expectRevert(VestingFactory.InvalidParameters.selector);
        router.createVesting(alice, 100, bob, start, 100, 0);
        vm.expectRevert(VestingFactory.InvalidParameters.selector);
        router.createVesting(address(token), 100, address(0), start, 100, 0);
        vm.expectRevert(VestingFactory.InvalidParameters.selector);
        router.createVesting(address(token), 100, address(router), start, 100, 0);
        vm.expectRevert(VestingFactory.InvalidParameters.selector);
        router.createVesting(address(token), 100, address(vault), start, 100, 0);
        vm.expectRevert(VestingFactory.InvalidParameters.selector);
        router.createVesting(address(token), 100, bob, uint64(vm.getBlockTimestamp() - 1), 100, 0);
        vm.expectRevert(VestingFactory.InvalidParameters.selector);
        router.createVesting(address(token), 100, bob, start, 100, 101);
        vm.expectRevert(VestingFactory.InvalidParameters.selector);
        router.createVesting(address(token), 100, bob, type(uint64).max, 1, 0);
        vm.stopPrank();
    }

    function testVestingRejectsTransferFees() public {
        FeeToken asset = new FeeToken();
        asset.mint(alice, 1_000);
        approveToken(asset, 1_000);
        vm.prank(alice);
        vm.expectRevert(VestingFactory.UnsupportedFunding.selector);
        router.createVesting(address(asset), 1_000, bob, uint64(vm.getBlockTimestamp()), 100, 0);
        assertEq(asset.balanceOf(alice), 1_000);
        assertEq(asset.totalSupply(), 1_000);
    }

    function testNativeDepositsReleaseThroughRouter() public {
        uint64 start = uint64(vm.getBlockTimestamp() + 100);
        FixedBeneficiaryVesting wallet = create(start, 0, 0);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(wallet).call{value: 1 ether}("");
        assertTrue(ok);
        vm.warp(start);
        vm.recordLogs();
        router.releaseVestingNative(address(wallet));
        assertEq(bob.balance, 1 ether);
        assertEq(wallet.released(), 1 ether);
        assertRouterEvent(keccak256("NativeVestingReleased(address,address,address,uint256)"));
    }

    function testAdditionalFundingUsesOriginalSchedule() public {
        uint64 start = uint64(vm.getBlockTimestamp());
        FixedBeneficiaryVesting wallet = create(start, 1_000, 0);
        vm.warp(start + 500);
        vm.prank(alice);
        token.transfer(address(wallet), 1_000);
        assertEq(wallet.releasable(address(token)), 1_000);
    }

    function testFuzzVestingAccrual(uint64 elapsed) public {
        elapsed = uint64(bound(elapsed, 0, 1_000));
        uint64 start = uint64(vm.getBlockTimestamp());
        FixedBeneficiaryVesting wallet = create(start, 1_000, 0);
        vm.warp(start + elapsed);
        assertEq(wallet.releasable(address(token)), elapsed);
        router.releaseVesting(address(wallet), address(token));
        assertEq(token.balanceOf(bob), elapsed);
    }
}

contract NFTLockTest is RouterTestBase {
    function testNFTLockAndPermissionlessRelease() public {
        uint64 unlock = uint64(vm.getBlockTimestamp() + 100);
        vm.recordLogs();
        vm.prank(alice);
        router.lock(address(nft), 1, bob, unlock);
        assertRouterEvent(keccak256("Locked(address,address,uint256,address,uint64)"));
        assertEq(nft.ownerOf(1), address(router));
        vm.expectRevert(ERC721ScheduledLocker.NotReleasable.selector);
        router.release(address(nft), 1);
        vm.warp(unlock);
        vm.prank(stranger);
        vm.expectRevert(ERC721ScheduledLocker.NotReleasable.selector);
        router.releaseTo(address(nft), 1, stranger);
        vm.recordLogs();
        vm.prank(stranger);
        router.release(address(nft), 1);
        assertEq(nft.ownerOf(1), bob);
        assertRouterEvent(keccak256("Released(address,uint256,address,address)"));
        vm.expectRevert(ERC721ScheduledLocker.NotReleasable.selector);
        router.release(address(nft), 1);
    }

    function testNFTLockRequiresOwnershipAndApproval() public {
        uint64 unlock = uint64(vm.getBlockTimestamp() + 100);
        vm.prank(stranger);
        vm.expectRevert(ERC721ScheduledLocker.InvalidLock.selector);
        router.lock(address(nft), 1, bob, unlock);
        vm.prank(alice);
        nft.setApprovalForAll(address(router), false);
        vm.prank(alice);
        vm.expectRevert();
        router.lock(address(nft), 1, bob, unlock);
        (address beneficiary,) = router.locks(address(nft), 1);
        assertEq(beneficiary, address(0));
        assertEq(nft.ownerOf(1), alice);
    }

    function testNFTLockRejectsInvalidBeneficiariesAndTime() public {
        uint64 unlock = uint64(vm.getBlockTimestamp() + 100);
        vm.startPrank(alice);
        vm.expectRevert(ERC721ScheduledLocker.InvalidLock.selector);
        router.lock(address(nft), 1, address(0), unlock);
        vm.expectRevert(ERC721ScheduledLocker.InvalidLock.selector);
        router.lock(address(nft), 1, address(router), unlock);
        vm.expectRevert(ERC721ScheduledLocker.InvalidLock.selector);
        router.lock(address(nft), 1, address(vault), unlock);
        vm.expectRevert(ERC721ScheduledLocker.InvalidLock.selector);
        router.lock(address(nft), 1, bob, uint64(vm.getBlockTimestamp()));
        vm.stopPrank();
    }

    function testUnsolicitedSafeNFTTransfersRevert() public {
        vm.startPrank(alice);
        vm.expectRevert();
        nft.safeTransferFrom(alice, address(router), 1);
        vm.expectRevert();
        nft.safeTransferFrom(alice, address(vault), 1);
        vm.stopPrank();
        assertEq(nft.ownerOf(1), alice);
    }

    function testReceiverFailurePreservesLockAndBeneficiaryCanRedirect() public {
        NonReceiver receiver = new NonReceiver();
        uint64 unlock = uint64(vm.getBlockTimestamp() + 100);
        vm.prank(alice);
        router.lock(address(nft), 1, address(receiver), unlock);
        vm.warp(unlock);
        vm.expectRevert();
        router.release(address(nft), 1);
        (address beneficiary,) = router.locks(address(nft), 1);
        assertEq(beneficiary, address(receiver));
        assertEq(nft.ownerOf(1), address(router));
        vm.prank(address(receiver));
        router.releaseTo(address(nft), 1, bob);
        assertEq(nft.ownerOf(1), bob);
    }

    function testNFTCannotBeRedirectedIntoRouterOrVault() public {
        uint64 unlock = uint64(vm.getBlockTimestamp() + 100);
        vm.prank(alice);
        router.lock(address(nft), 1, bob, unlock);
        vm.warp(unlock);
        vm.startPrank(bob);
        vm.expectRevert();
        router.releaseTo(address(nft), 1, address(router));
        vm.expectRevert();
        router.releaseTo(address(nft), 1, address(vault));
        vm.stopPrank();
        assertEq(nft.ownerOf(1), address(router));
    }
}

contract DisposalTest is RouterTestBase {
    function testNativeBurnPreservesExistingRouterAssetsAndEmitsEvents() public {
        token.mint(address(router), 7);
        nft.mint(alice, 2);
        vm.prank(alice);
        router.lock(address(nft), 2, bob, uint64(vm.getBlockTimestamp() + 100));
        vm.recordLogs();
        vm.prank(alice);
        router.disposeERC20(address(token), 100, true);
        assertEq(token.totalSupply(), 9_907);
        assertEq(token.balanceOf(address(router)), 7);
        assertRouterEvent(keccak256("ERC20Burned(address,address,uint256)"));
        vm.recordLogs();
        vm.prank(alice);
        router.disposeERC721(address(nft), 1, true);
        assertEq(nft.balanceOf(address(router)), 1);
        assertEq(nft.ownerOf(2), address(router));
        vm.expectRevert();
        nft.ownerOf(1);
        assertRouterEvent(keccak256("ERC721Burned(address,address,uint256)"));
    }

    function testERC20DisposalLocksForExactDurationAndReleasesAtMaturity() public {
        NonBurnableToken asset = new NonBurnableToken();
        asset.mint(alice, 1_000);
        approveToken(asset, 1_000);
        uint256 depositedAt = vm.getBlockTimestamp();
        vm.recordLogs();
        vm.prank(alice);
        router.disposeERC20(address(asset), 100, false);
        (address beneficiary, address storedAsset, uint256 amount, uint64 unlock, bool isNFT, bool released) =
            vault.deposits(0);
        assertEq(beneficiary, alice);
        assertEq(storedAsset, address(asset));
        assertEq(amount, 100);
        assertEq(unlock, depositedAt + 31_536_000_000);
        assertFalse(isNFT);
        assertFalse(released);
        assertEq(asset.balanceOf(address(vault)), 100);
        assertEq(asset.totalSupply(), 1_000);
        assertRouterEvent(keccak256("DisposalLocked(address,address,uint256,bool,uint256,uint64,address)"));
        vm.warp(unlock - 1);
        vm.expectRevert(ThousandYearVault.NotReleasable.selector);
        router.releaseDisposalLock(0);
        vm.warp(unlock);
        vm.prank(stranger);
        vm.expectRevert(AssetRouter.WrongBeneficiary.selector);
        router.releaseDisposalLockTo(0, bob);
        vm.recordLogs();
        vm.prank(stranger);
        router.releaseDisposalLock(0);
        assertEq(asset.balanceOf(alice), 1_000);
        assertRouterEvent(keccak256("DisposalLockReleased(address,address,uint256,address,bool,uint256,address)"));
        vm.expectRevert(ThousandYearVault.NotReleasable.selector);
        router.releaseDisposalLock(0);
    }

    function testNFTDisposalAndBeneficiaryRedirectAtMaturity() public {
        NonBurnableNFT asset = new NonBurnableNFT();
        asset.mint(alice, 0);
        approveNFT(asset);
        vm.prank(alice);
        router.disposeERC721(address(asset), 0, false);
        assertEq(asset.ownerOf(0), address(vault));
        (,,, uint64 unlock, bool isNFT,) = vault.deposits(0);
        assertTrue(isNFT);
        vm.expectRevert(ThousandYearVault.NotReleasable.selector);
        router.releaseDisposalLock(0);
        vm.warp(unlock);
        vm.startPrank(alice);
        vm.expectRevert(AssetRouter.InvalidDisposal.selector);
        router.releaseDisposalLockTo(0, address(router));
        vm.expectRevert(AssetRouter.InvalidDisposal.selector);
        router.releaseDisposalLockTo(0, address(vault));
        vm.expectRevert(ThousandYearVault.NotReleasable.selector);
        router.releaseDisposalLockTo(0, address(0));
        router.releaseDisposalLockTo(0, bob);
        vm.stopPrank();
        assertEq(asset.ownerOf(0), bob);
    }

    function testVaultOnlyAcceptsItsRouterAsController() public {
        assertEq(vault.controller(), address(router));
        vm.expectRevert(ThousandYearVault.OnlyController.selector);
        vault.record(alice, address(token), 100, false);
        vm.expectRevert(ThousandYearVault.OnlyController.selector);
        vault.release(0, alice);
        vm.prank(stranger);
        vm.expectRevert(AssetRouter.InvalidDisposal.selector);
        router.disposeERC721(address(nft), 1, false);
    }

    function testMissingBurnFunctionsRevertWithoutCreatingLocks() public {
        NonBurnableToken asset = new NonBurnableToken();
        asset.mint(alice, 100);
        approveToken(asset, 100);
        vm.prank(alice);
        vm.expectRevert();
        router.disposeERC20(address(asset), 100, true);
        assertEq(asset.balanceOf(alice), 100);
        assertEq(asset.allowance(alice, address(router)), 100);
        NonBurnableNFT collection = new NonBurnableNFT();
        collection.mint(alice, 1);
        approveNFT(collection);
        vm.prank(alice);
        vm.expectRevert();
        router.disposeERC721(address(collection), 1, true);
        assertEq(collection.ownerOf(1), alice);
        assertEq(vault.nextId(), 0);
    }

    function testFakeBurnsRollBackBalancesAndOwnership() public {
        FakeBurnToken asset = new FakeBurnToken();
        asset.mint(alice, 100);
        approveToken(asset, 100);
        vm.prank(alice);
        vm.expectRevert(AssetRouter.IncorrectBurn.selector);
        router.disposeERC20(address(asset), 100, true);
        assertEq(asset.balanceOf(alice), 100);
        assertEq(asset.totalSupply(), 100);
        FakeBurnNFT collection = new FakeBurnNFT();
        collection.mint(alice, 1);
        approveNFT(collection);
        vm.prank(alice);
        vm.expectRevert(AssetRouter.IncorrectBurn.selector);
        router.disposeERC721(address(collection), 1, true);
        assertEq(collection.ownerOf(1), alice);
        assertEq(vault.nextId(), 0);
    }

    function testRevertingOwnerQueryAloneDoesNotProveNFTBurn() public {
        MaskedOwnerFakeBurnNFT asset = new MaskedOwnerFakeBurnNFT();
        asset.mint(alice, 1);
        approveNFT(asset);
        vm.prank(alice);
        vm.expectRevert(AssetRouter.IncorrectBurn.selector);
        router.disposeERC721(address(asset), 1, true);
        assertEq(asset.ownerOf(1), alice);
    }

    function testDisposalRejectsTransferFeesInBothModes() public {
        FeeToken asset = new FeeToken();
        asset.mint(alice, 1_000);
        approveToken(asset, 1_000);
        vm.startPrank(alice);
        vm.expectRevert(AssetRouter.IncorrectDeposit.selector);
        router.disposeERC20(address(asset), 100, true);
        vm.expectRevert(AssetRouter.IncorrectDeposit.selector);
        router.disposeERC20(address(asset), 100, false);
        vm.stopPrank();
        assertEq(asset.balanceOf(alice), 1_000);
        assertEq(asset.totalSupply(), 1_000);
        assertEq(asset.balanceOf(address(router)), 0);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(vault.nextId(), 0);
    }

    function testDisposalRejectsInvalidInputsAndTimestampOverflow() public {
        vm.startPrank(alice);
        vm.expectRevert(AssetRouter.InvalidDisposal.selector);
        router.disposeERC20(address(token), 0, false);
        vm.expectRevert(AssetRouter.InvalidDisposal.selector);
        router.disposeERC20(alice, 100, false);
        vm.expectRevert(AssetRouter.InvalidDisposal.selector);
        router.disposeERC721(alice, 1, false);
        vm.warp(type(uint64).max);
        vm.expectRevert(ThousandYearVault.InvalidDeposit.selector);
        router.disposeERC20(address(token), 100, false);
        vm.stopPrank();
        assertEq(vault.nextId(), 0);
    }

    function testDisposalCannotSpendAnotherUsersAllowance() public {
        vm.prank(stranger);
        vm.expectRevert();
        router.disposeERC20(address(token), 100, false);
        assertEq(token.balanceOf(alice), 10_000);
        assertEq(vault.nextId(), 0);
    }

    function testDisposalRejectsMissingApproval() public {
        vm.startPrank(alice);
        token.approve(address(router), 0);
        vm.expectRevert();
        router.disposeERC20(address(token), 100, false);
        nft.setApprovalForAll(address(router), false);
        vm.expectRevert();
        router.disposeERC721(address(nft), 1, false);
        vm.stopPrank();
        assertEq(vault.nextId(), 0);
    }

    function testERC20DisposalRedirectRejectsRouterAndVaultAfterMaturity() public {
        vm.prank(alice);
        router.disposeERC20(address(token), 100, false);
        (,,, uint64 unlock,,) = vault.deposits(0);
        vm.warp(unlock);
        vm.startPrank(alice);
        vm.expectRevert(AssetRouter.InvalidDisposal.selector);
        router.releaseDisposalLockTo(0, address(router));
        vm.expectRevert(AssetRouter.InvalidDisposal.selector);
        router.releaseDisposalLockTo(0, address(vault));
        router.releaseDisposalLockTo(0, bob);
        vm.stopPrank();
        assertEq(token.balanceOf(bob), 100);
    }
}

contract RouterGuardTest is RouterTestBase {
    function testTokenCallbackCannotEnterAnotherRouterModule() public {
        ReentrantToken asset = new ReentrantToken();
        asset.mint(alice, 1_000);
        approveToken(asset, 1_000);
        asset.configure(address(router), abi.encodeCall(router.disposeERC20, (address(asset), 1, false)));
        (address[] memory recipients, uint256[] memory amounts) = batch();
        vm.prank(alice);
        router.distribute(address(asset), recipients, amounts);
        assertTrue(asset.guardObserved());
        assertEq(vault.nextId(), 0);
    }

    function testNFTReceiverCannotEnterAnotherRouterModule() public {
        ReentrantNFTReceiver receiver = new ReentrantNFTReceiver();
        receiver.configure(address(router), abi.encodeCall(router.releaseDisposalLock, (0)));
        uint64 unlock = uint64(vm.getBlockTimestamp() + 100);
        vm.prank(alice);
        router.lock(address(nft), 1, address(receiver), unlock);
        vm.warp(unlock);
        router.release(address(nft), 1);
        assertTrue(receiver.guardObserved());
        assertEq(nft.ownerOf(1), address(receiver));
    }

    function testRouterFitsDeploymentSizeLimit() public view {
        assertLe(address(router).code.length, 24_576);
    }
}
