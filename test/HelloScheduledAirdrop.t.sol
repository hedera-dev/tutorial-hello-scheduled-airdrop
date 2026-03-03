// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {HelloScheduledAirdrop} from "../src/HelloScheduledAirdrop.sol";

contract HelloScheduledAirdropTest is Test {
    HelloScheduledAirdrop public token;
    address public owner;
    address public user1;
    address public user2;
    address public user3;

    function setUp() public {
        owner = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");

        token = new HelloScheduledAirdrop{value: 10 ether}("Airdrop Token", "ADT", 1_000_000 ether);
    }

    // ============ Token Metadata Tests ============

    function test_TokenMetadata() public view {
        assertEq(token.name(), "Airdrop Token");
        assertEq(token.symbol(), "ADT");
        assertEq(token.decimals(), 18);
    }

    function test_InitialSupply() public view {
        assertEq(token.totalSupply(), 1_000_000 ether);
        assertEq(token.balanceOf(owner), 1_000_000 ether);
    }

    function test_ZeroInitialSupply() public {
        HelloScheduledAirdrop zeroToken = new HelloScheduledAirdrop("Zero Token", "ZTK", 0);
        assertEq(zeroToken.totalSupply(), 0);
        assertEq(zeroToken.balanceOf(address(this)), 0);
    }

    function test_InitialBalance() public view {
        assertEq(address(token).balance, 10 ether);
    }

    // ============ Registration Tests ============

    function test_Register() public {
        vm.prank(user1);
        token.registerForAirdrop();

        assertTrue(token.isRegistered(user1));
        assertEq(token.recipients(0), user1);
    }

    function test_RegisterMultipleUsers() public {
        vm.prank(user1);
        token.registerForAirdrop();

        vm.prank(user2);
        token.registerForAirdrop();

        vm.prank(user3);
        token.registerForAirdrop();

        address[] memory recipients = token.getRecipients();
        assertEq(recipients.length, 3);
        assertEq(recipients[0], user1);
        assertEq(recipients[1], user2);
        assertEq(recipients[2], user3);
    }

    function test_RevertWhen_AlreadyRegistered() public {
        vm.startPrank(user1);
        token.registerForAirdrop();

        vm.expectRevert("Already registered");
        token.registerForAirdrop();
        vm.stopPrank();
    }

    // ============ Start Airdrop Validation Tests ============

    function test_RevertWhen_StartWithoutRecipients() public {
        vm.expectRevert("No recipients");
        token.startAirdrop(100 ether, 20, 5, "Test");
    }

    function test_RevertWhen_NonOwnerStarts() public {
        vm.prank(user1);
        token.registerForAirdrop();

        vm.prank(user1);
        vm.expectRevert();
        token.startAirdrop(100 ether, 20, 5, "Test");
    }

    // Note: Cannot test "Already active" revert because startAirdrop calls
    // _scheduleWithCapacityCheck which invokes the HSS precompile (0x16b),
    // which is not available in Foundry's local EVM.

    // ============ Execute Airdrop Tests ============

    function test_RevertWhen_ExecuteNotActive() public {
        vm.expectRevert("Not active");
        token.executeAirdrop();
    }

    // ============ Stop Airdrop Tests ============

    function test_StopWhenNotActive() public {
        // Should not revert, just sets active to false and emits event
        token.stopAirdrop();

        (bool active,,,,,) = token.getStatus();
        assertFalse(active);
    }

    function test_RevertWhen_NonOwnerStops() public {
        vm.prank(user1);
        vm.expectRevert();
        token.stopAirdrop();
    }

    // ============ Status Tests ============

    function test_GetStatus_Initial() public {
        vm.prank(user1);
        token.registerForAirdrop();

        (bool active, uint256 amount, uint256 interval, uint256 maxDrops, uint256 completed, uint256 recipientCount) =
            token.getStatus();

        assertFalse(active);
        assertEq(amount, 0);
        assertEq(interval, 0);
        assertEq(maxDrops, 0);
        assertEq(completed, 0);
        assertEq(recipientCount, 1);
    }

    function test_GetStatus_NoRecipients() public view {
        (bool active,,,,, uint256 recipientCount) = token.getStatus();

        assertFalse(active);
        assertEq(recipientCount, 0);
    }

    // ============ Get Recipients Tests ============

    function test_GetRecipients_Empty() public view {
        address[] memory recipients = token.getRecipients();
        assertEq(recipients.length, 0);
    }

    function test_GetRecipients() public {
        vm.prank(user1);
        token.registerForAirdrop();
        vm.prank(user2);
        token.registerForAirdrop();

        address[] memory recipients = token.getRecipients();
        assertEq(recipients.length, 2);
        assertEq(recipients[0], user1);
        assertEq(recipients[1], user2);
    }

    // ============ Receive HBAR Tests ============

    function test_ReceiveHBAR() public {
        uint256 balanceBefore = address(token).balance;
        payable(address(token)).transfer(5 ether);
        assertEq(address(token).balance, balanceBefore + 5 ether);
    }

    // ============ Fuzz Tests ============

    function testFuzz_Register(address user) public {
        vm.assume(user != address(0));
        vm.assume(!token.isRegistered(user));

        vm.prank(user);
        token.registerForAirdrop();

        assertTrue(token.isRegistered(user));
    }

    function testFuzz_ReceiveHBAR(uint256 amount) public {
        amount = bound(amount, 0, 100 ether);
        uint256 balanceBefore = address(token).balance;
        deal(address(this), amount);
        payable(address(token)).transfer(amount);
        assertEq(address(token).balance, balanceBefore + amount);
    }
}
