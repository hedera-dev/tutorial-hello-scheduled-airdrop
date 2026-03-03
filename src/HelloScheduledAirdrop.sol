// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

// OpenZeppelin
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

// Hiero system contracts (formerly hashgraph/hedera-smart-contracts)
import {HederaScheduleService} from "@hiero/system-contracts/schedule-service/HederaScheduleService.sol";
import {HederaResponseCodes} from "@hiero/system-contracts/common/HederaResponseCodes.sol";
import {PrngSystemContract} from "@hiero/system-contracts/prng/PrngSystemContract.sol";

/**
 * @title HelloScheduledAirdrop
 * @author Kiran Pachhai
 * @notice ERC20 with automated scheduled airdrops via HSS (HIP-1215)
 * @dev Demonstrates real-world use case: scheduled token distribution with capacity awareness
 *
 * Features:
 * - Users register for airdrops
 * - Admin starts scheduled minting
 * - Random recipients receive tokens at intervals
 * - Uses hasScheduleCapacity for reliable scheduling
 * - Stops automatically after N distributions
 */
contract HelloScheduledAirdrop is ERC20, Ownable, HederaScheduleService {
    uint256 constant GAS_LIMIT = 2_000_000;
    uint256 constant MAX_PROBES = 8;

    struct Config {
        uint256 amount;
        uint256 interval;
        uint256 maxDrops;
        uint256 completed;
        bool active;
        string message;
    }

    Config public config;
    address[] public recipients;
    mapping(address => bool) public isRegistered;

    event Registered(address indexed user);
    event AirdropExecuted(address indexed to, uint256 amount, uint256 dropNum, string message);
    event AirdropStarted(uint256 amount, uint256 interval, uint256 maxDrops);
    event AirdropStopped(uint256 totalDrops);
    event SlotFound(uint256 desiredTime, uint256 actualTime, uint256 probesUsed);

    constructor(string memory name, string memory symbol, uint256 initialSupply)
        payable
        ERC20(name, symbol)
        Ownable(msg.sender)
    {
        if (initialSupply > 0) _mint(msg.sender, initialSupply);
    }

    receive() external payable {}

    // ============ Public Functions ============

    function registerForAirdrop() external {
        require(!isRegistered[msg.sender], "Already registered");
        isRegistered[msg.sender] = true;
        recipients.push(msg.sender);
        emit Registered(msg.sender);
    }

    function startAirdrop(uint256 _amount, uint256 _interval, uint256 _maxDrops, string calldata _message)
        external
        onlyOwner
    {
        require(!config.active, "Already active");
        require(recipients.length > 0, "No recipients");

        config = Config({
            amount: _amount,
            interval: _interval,
            maxDrops: _maxDrops,
            completed: 0,
            active: true,
            message: _message
        });

        uint256 targetTime = block.timestamp + _interval;
        _scheduleWithCapacityCheck(targetTime);
        emit AirdropStarted(_amount, _interval, _maxDrops);
    }

    function executeAirdrop() external {
        require(config.active, "Not active");

        address to = _randomRecipient();
        _mint(to, config.amount);
        config.completed++;

        emit AirdropExecuted(to, config.amount, config.completed, config.message);

        if (config.maxDrops > 0 && config.completed >= config.maxDrops) {
            config.active = false;
            emit AirdropStopped(config.completed);
        } else {
            uint256 targetTime = block.timestamp + config.interval;
            _scheduleWithCapacityCheck(targetTime);
        }
    }

    function stopAirdrop() external onlyOwner {
        config.active = false;
        emit AirdropStopped(config.completed);
    }

    // ============ Internal Functions ============

    function _randomRecipient() internal returns (address) {
        bytes32 seed = PrngSystemContract(address(0x169)).getPseudorandomSeed();
        return recipients[uint256(seed) % recipients.length];
    }

    function _scheduleWithCapacityCheck(uint256 desiredTime) internal {
        uint256 actualTime = _findAvailableSecond(desiredTime);
        _schedule(actualTime);
    }

    function _findAvailableSecond(uint256 expiry) internal returns (uint256) {
        // First, try the exact desired time
        if (hasScheduleCapacity(expiry, GAS_LIMIT)) {
            emit SlotFound(expiry, expiry, 0);
            return expiry;
        }

        // Get random seed for jitter
        bytes32 seed = PrngSystemContract(address(0x169)).getPseudorandomSeed();

        // Exponential backoff with jitter
        for (uint256 i = 0; i < MAX_PROBES; i++) {
            uint256 baseDelay = 1 << i; // 1, 2, 4, 8, 16, 32, 64, 128

            // Calculate jitter from seed
            bytes32 hash = keccak256(abi.encodePacked(seed, i));
            uint16 randomValue = uint16(uint256(hash));
            uint256 jitter = uint256(randomValue) % (baseDelay + 1);

            uint256 candidate = expiry + baseDelay + jitter;

            if (hasScheduleCapacity(candidate, GAS_LIMIT)) {
                emit SlotFound(expiry, candidate, i + 1);
                return candidate;
            }
        }

        // If all probes fail, use fallback time
        uint256 fallbackTime = expiry + (1 << MAX_PROBES);
        emit SlotFound(expiry, fallbackTime, MAX_PROBES);
        return fallbackTime;
    }

    function _schedule(uint256 time) internal {
        bytes memory data = abi.encodeWithSelector(this.executeAirdrop.selector);
        (int64 responseCode,) = scheduleCall(address(this), time, GAS_LIMIT, 0, data);
        require(responseCode == HederaResponseCodes.SUCCESS, "Schedule failed");
    }

    // ============ View Functions ============

    function getStatus()
        external
        view
        returns (
            bool active,
            uint256 amount,
            uint256 interval,
            uint256 maxDrops,
            uint256 completed,
            uint256 recipientCount
        )
    {
        return (config.active, config.amount, config.interval, config.maxDrops, config.completed, recipients.length);
    }

    function getRecipients() external view returns (address[] memory) {
        return recipients;
    }
}
