// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {Deploy} from "../../script/Deploy.s.sol";
import {ISecurityToken} from "../../src/interfaces/ISecurityToken.sol";
import {IIdentityRegistry} from "../../src/interfaces/IIdentityRegistry.sol";
import {IDividendDistributor} from "../../src/interfaces/IDividendDistributor.sol";
import {DividendDistributor} from "../../src/compliance/modules/DividendDistributor.sol";
import {MockCurrency} from "../helpers/MockCurrency.sol";

/**
 * @title RegressionsTest
 * @notice One test per bug found in the review rounds, run against the system `Deploy` produces.
 * @dev Each test asserts the correct behaviour and failed against the code before its fix. The
 *      README "Review notes" section maps every test here to its finding and its fix commit.
 */
contract RegressionsTest is Test, Deploy {
    Deployment internal d;

    address internal issuer = address(this);
    address internal agent = makeAddr("agent");
    address internal custodian = makeAddr("custodian");

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");
    address internal stranger = makeAddr("stranger");

    uint16 internal constant ES = 724;
    uint64 internal constant KYC_WINDOW = 10 * 365 days;
    uint256 internal constant AMOUNT = 1_000e18;

    function setUp() public {
        d = _deploy(issuer, agent, custodian);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _onboard(address who) internal {
        vm.prank(agent);
        d.identityRegistry.registerIdentity(who, ES, true, uint64(block.timestamp + KYC_WINDOW));
    }

    function _onboardAs(address who, bytes32 id) internal {
        vm.prank(agent);
        d.identityRegistry.registerIdentity(who, ES, true, uint64(block.timestamp + KYC_WINDOW), id);
    }

    function _sign(uint256 key, address who, uint16 country_, uint64 expiry) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                d.identityRegistry.ATTESTATION_TYPEHASH(),
                who,
                country_,
                true,
                expiry,
                bytes32(0),
                d.identityRegistry.nonces(who)
            )
        );
        bytes32 digest = MessageHashUtils.toTypedDataHash(d.identityRegistry.domainSeparator(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _attachDistributor() internal returns (DividendDistributor dist, MockCurrency currency) {
        currency = new MockCurrency();
        dist = new DividendDistributor(address(d.compliance), address(d.token), address(currency), issuer);
        d.compliance.addModule(address(dist));
        currency.mint(issuer, 1_000_000e6);
        currency.approve(address(dist), type(uint256).max);
    }

    function _liveHolders(address[4] memory wallets) internal view returns (uint256 live) {
        for (uint256 i; i < wallets.length; ++i) {
            if (d.token.balanceOf(wallets[i]) != 0) ++live;
        }
    }

    /*//////////////////////////////////////////////////////////////
                  ZERO AMOUNTS DO NOT MOVE THE HOLDER COUNT
    //////////////////////////////////////////////////////////////*/

    /// @dev A verified wallet holding nothing sends zero tokens. No holder joins or leaves, so the
    ///      count must not move, and the cap must keep refusing a third holder.
    function test_zeroAmountTransfer_doesNotDeflateHolderCount() public {
        _onboard(alice);
        _onboard(bob);
        _onboard(carol);
        d.token.mint(alice, AMOUNT);
        d.token.mint(bob, AMOUNT);
        vm.prank(agent);
        d.maxHolders.setMaxHolders(2);

        vm.prank(carol);
        d.token.transfer(alice, 0);
        vm.prank(carol);
        d.token.transfer(alice, 0);

        assertEq(d.maxHolders.holderCount(), 2, "zero-amount sends moved the count");
        vm.expectRevert(abi.encodeWithSelector(ISecurityToken.ComplianceCheckFailed.selector, address(0), carol, 1));
        d.token.mint(carol, 1);
        assertEq(_liveHolders([alice, bob, carol, dave]), 2);
    }

    /// @dev `transferFrom` with a zero amount needs no allowance, so any address can drive the
    ///      zero-amount path on behalf of an empty verified wallet. The count must still not move.
    function test_zeroAmountTransferFromByStranger_doesNotDeflateHolderCount() public {
        _onboard(alice);
        _onboard(carol);
        d.token.mint(alice, AMOUNT);

        vm.prank(stranger);
        d.token.transferFrom(carol, alice, 0);

        assertEq(d.maxHolders.holderCount(), 1);
    }

    /// @dev An issuer burn of zero from a wallet that holds nothing removes no holder.
    function test_zeroBurnFromNonHolder_doesNotDeflateHolderCount() public {
        _onboard(alice);
        d.token.mint(alice, AMOUNT);

        d.token.burn(carol, 0);

        assertEq(d.maxHolders.holderCount(), 1);
    }

    /// @dev The consequence of a deflated count: a legitimate full exit to an existing holder
    ///      underflowed and reverted. With the count intact the exit settles.
    function test_zeroAmountSends_doNotBlockLaterExits() public {
        _onboard(alice);
        _onboard(bob);
        _onboard(carol);
        d.token.mint(alice, AMOUNT);
        d.token.mint(bob, AMOUNT);

        vm.startPrank(stranger);
        d.token.transferFrom(carol, alice, 0);
        d.token.transferFrom(carol, alice, 0);
        d.token.transferFrom(carol, alice, 0);
        vm.stopPrank();

        vm.warp(block.timestamp + LOCKUP_PERIOD + 1);
        vm.prank(alice);
        d.token.transfer(bob, AMOUNT);

        assertEq(d.maxHolders.holderCount(), 1);
        assertEq(_liveHolders([alice, bob, carol, dave]), 1);
    }

    /*//////////////////////////////////////////////////////////////
            A REMOVAL OR AN AGENT UPDATE RETIRES OUTSTANDING SIGNATURES
    //////////////////////////////////////////////////////////////*/

    /// @dev An attestation issued while the investor was registered, but never submitted, must not
    ///      undo a later removal. Only a signed registration used to advance the nonce, so the
    ///      unsubmitted signature stayed valid until its expiry.
    function test_attestationSignedBeforeRemoval_isRejectedAfterIt() public {
        (address signer, uint256 key) = makeAddrAndKey("claimSigner");
        d.identityRegistry.setClaimSigner(signer);
        _onboard(alice);
        uint64 expiry = uint64(block.timestamp + 365 days);
        bytes memory sig = _sign(key, alice, ES, expiry);

        vm.prank(agent);
        d.identityRegistry.removeIdentity(alice);

        vm.prank(stranger);
        vm.expectPartialRevert(IIdentityRegistry.InvalidAttestationSigner.selector);
        d.identityRegistry.registerIdentityWithAttestation(alice, ES, true, expiry, bytes32(0), sig);
        assertFalse(d.identityRegistry.isVerified(alice));
    }

    /// @dev An agent rewriting a record supersedes any attestation issued before the rewrite, so a
    ///      stale signature cannot roll the record back to the attributes it carried.
    function test_attestationSignedBeforeAgentUpdate_isRejectedAfterIt() public {
        (address signer, uint256 key) = makeAddrAndKey("claimSigner");
        d.identityRegistry.setClaimSigner(signer);
        uint64 expiry = uint64(block.timestamp + 365 days);
        bytes memory sig = _sign(key, alice, ES, expiry);

        uint16 fr = 250;
        vm.prank(agent);
        d.identityRegistry.registerIdentity(alice, fr, true, expiry);

        vm.prank(stranger);
        vm.expectPartialRevert(IIdentityRegistry.InvalidAttestationSigner.selector);
        d.identityRegistry.registerIdentityWithAttestation(alice, ES, true, expiry, bytes32(0), sig);
        assertEq(d.identityRegistry.country(alice), fr);
    }

    /*//////////////////////////////////////////////////////////////
              A REMOVED LOST WALLET CAN STILL BE RECOVERED
    //////////////////////////////////////////////////////////////*/

    /// @dev Compliance suspends a wallet with `removeIdentity`, then the investor reports it lost.
    ///      The removal used to delete the investor id, so recovery reverted with
    ///      `RecoveryAcrossInvestors(0, id)` and the position stayed stranded.
    function test_forcedRecovery_succeedsAfterAgentRemovedLostWallet() public {
        bytes32 id = keccak256("investor-alice");
        address aliceNew = makeAddr("aliceNew");
        _onboardAs(alice, id);
        _onboardAs(aliceNew, id);
        d.token.mint(alice, AMOUNT);

        vm.prank(agent);
        d.identityRegistry.removeIdentity(alice);
        assertEq(d.identityRegistry.investorId(alice), id, "removal must keep the investor id");

        vm.prank(custodian);
        d.token.forcedRecovery(alice, aliceNew);

        assertEq(d.token.balanceOf(aliceNew), AMOUNT);
        assertEq(d.token.balanceOf(alice), 0);
        assertFalse(d.identityRegistry.isVerified(alice));
    }

    /*//////////////////////////////////////////////////////////////
              FORCED RECOVERY DOES NOT RESTART THE LOCKUP
    //////////////////////////////////////////////////////////////*/

    /// @dev A position whose lockup already expired must still be free after recovery. The
    ///      recovery hook used to look like a fresh acquisition to `LockupModule`, which started a
    ///      new full-period clock on the destination.
    function test_forcedRecovery_keepsAnExpiredLockupExpired() public {
        bytes32 id = keccak256("investor-alice");
        address aliceNew = makeAddr("aliceNew");
        _onboardAs(alice, id);
        _onboardAs(aliceNew, id);
        _onboard(bob);
        d.token.mint(alice, AMOUNT);
        uint64 start = d.lockup.lockStart(alice);
        vm.warp(block.timestamp + LOCKUP_PERIOD + 1);

        vm.prank(custodian);
        d.token.forcedRecovery(alice, aliceNew);

        assertEq(d.lockup.lockStart(aliceNew), start, "recovery restarted the clock");
        assertEq(d.lockup.lockStart(alice), 0, "lost wallet kept a clock");
        vm.prank(aliceNew);
        d.token.transfer(bob, 1);
    }

    /// @dev An unexpired lockup keeps its original unlock time: recovery neither shortens nor
    ///      extends it.
    function test_forcedRecovery_keepsTheOriginalUnlockTime() public {
        bytes32 id = keccak256("investor-alice");
        address aliceNew = makeAddr("aliceNew");
        _onboardAs(alice, id);
        _onboardAs(aliceNew, id);
        d.token.mint(alice, AMOUNT);
        uint64 unlocksAt = d.lockup.unlocksAt(alice);
        vm.warp(block.timestamp + 100 days);

        vm.prank(custodian);
        d.token.forcedRecovery(alice, aliceNew);

        assertEq(d.lockup.unlocksAt(aliceNew), unlocksAt);
    }

    /// @dev Recovering into a wallet the investor already holds on keeps the earlier of the two
    ///      starts: both lots belong to one investor, and the lockup runs from initial acquisition.
    function test_forcedRecovery_intoHoldingWallet_keepsTheEarlierStart() public {
        bytes32 id = keccak256("investor-alice");
        address aliceNew = makeAddr("aliceNew");
        _onboardAs(alice, id);
        _onboardAs(aliceNew, id);
        d.token.mint(alice, AMOUNT);
        uint64 earlier = d.lockup.lockStart(alice);
        vm.warp(block.timestamp + 30 days);
        d.token.mint(aliceNew, AMOUNT);
        assertGt(d.lockup.lockStart(aliceNew), earlier);

        vm.prank(custodian);
        d.token.forcedRecovery(alice, aliceNew);

        assertEq(d.lockup.lockStart(aliceNew), earlier);
    }

    /*//////////////////////////////////////////////////////////////
          INCOME IS WITHHELD FROM FROZEN AND UNVERIFIED HOLDERS
    //////////////////////////////////////////////////////////////*/

    /// @dev A fully frozen holder cannot claim, and the income is kept for them rather than
    ///      forfeited: lifting the freeze releases it, including what accrued meanwhile.
    function test_claim_blockedWhileFullyFrozen_releasedAfterUnfreeze() public {
        (DividendDistributor dist, MockCurrency currency) = _attachDistributor();
        _onboard(alice);
        d.token.mint(alice, AMOUNT);
        dist.deposit(900e6);
        vm.prank(agent);
        d.token.setAddressFrozen(alice, true);
        dist.deposit(900e6);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IDividendDistributor.ClaimantFrozen.selector, alice));
        dist.claim(alice);

        vm.prank(agent);
        d.token.setAddressFrozen(alice, false);
        uint256 owed = dist.claimable(alice);
        assertGe(owed + 1, 1_800e6, "income accrued during the freeze was lost");
        vm.prank(alice);
        dist.claim(alice);
        assertEq(currency.balanceOf(alice), owed);
    }

    /// @dev A holder whose identity was withdrawn cannot claim until verified again.
    function test_claim_blockedWhileUnverified_releasedAfterReverification() public {
        (DividendDistributor dist, MockCurrency currency) = _attachDistributor();
        _onboard(alice);
        d.token.mint(alice, AMOUNT);
        dist.deposit(900e6);
        vm.prank(agent);
        d.identityRegistry.removeIdentity(alice);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IDividendDistributor.ClaimantNotVerified.selector, alice));
        dist.claim(alice);

        _onboard(alice);
        vm.prank(alice);
        dist.claim(alice);
        assertEq(currency.balanceOf(alice), 900e6 - 1);
    }

    /// @dev An expired KYC counts as not verified.
    function test_claim_blockedAfterKycExpiry() public {
        (DividendDistributor dist,) = _attachDistributor();
        vm.prank(agent);
        d.identityRegistry.registerIdentity(alice, ES, true, uint64(block.timestamp + 30 days));
        d.token.mint(alice, AMOUNT);
        dist.deposit(900e6);
        vm.warp(block.timestamp + 30 days);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IDividendDistributor.ClaimantNotVerified.selector, alice));
        dist.claim(alice);
    }

    /// @dev A partial freeze immobilises a lot of tokens, not the holder, so it does not withhold
    ///      income.
    function test_claim_allowedUnderPartialFreeze() public {
        (DividendDistributor dist, MockCurrency currency) = _attachDistributor();
        _onboard(alice);
        d.token.mint(alice, AMOUNT);
        dist.deposit(900e6);
        vm.prank(agent);
        d.token.freezePartialTokens(alice, AMOUNT);

        vm.prank(alice);
        dist.claim(alice);
        assertEq(currency.balanceOf(alice), 900e6 - 1);
    }
}
