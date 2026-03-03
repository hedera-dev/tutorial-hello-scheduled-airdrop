# Workshop Guide: Deploying Smart Contracts with Native On-Chain Automation

A step-by-step guide to building, deploying, and interacting with a self-scheduling ERC20 airdrop contract on Hedera.

## Table of Contents

1. [Introduction](#introduction)
2. [The Problem](#the-problem)
3. [The Solution](#the-solution)
4. [Understanding the Contract](#understanding-the-contract)
5. [Deploying to Testnet](#deploying-to-testnet)
6. [Interacting with the Contract](#interacting-with-the-contract)
7. [Verifying the Contract on HashScan](#verifying-the-contract-on-hashscan)
8. [Watching on HashScan](#watching-on-hashscan)
9. [Beyond the Workshop: Full HSS Capabilities](#beyond-the-workshop-full-hss-capabilities)
10. [Use Cases](#use-cases)
11. [Troubleshooting](#troubleshooting)

---

## Introduction

In this workshop, you will build and deploy **HelloScheduledAirdrop** -- an ERC20 token contract that autonomously schedules its own future execution on the Hedera network. No off-chain bots, no cron jobs, no external keepers. The contract schedules itself.

By the end of this guide, you will:

- Understand why smart contracts on most EVM chains cannot self-execute
- Know how Hedera Schedule Service (HSS) and HIP-1215 solve this limitation
- Deploy a working self-scheduling contract to Hedera testnet
- Watch it execute autonomously on HashScan

## The Problem

Smart contracts on EVM-compatible blockchains are **passive by design**. They sit on-chain waiting for someone (or something) to call them. They cannot:

- Wake up at a specific time
- Execute a function on a schedule
- React to the passage of time without an external trigger

**Example:** Imagine you want a contract to distribute tokens to random recipients every 30 seconds. On Ethereum, you would need:

- **Off-chain bot** running 24/7 on a server, calling the contract on schedule
- **Chainlink Keepers** (now Chainlink Automation) -- a paid third-party service
- **Gelato Network** -- another paid automation service

All of these require off-chain infrastructure, introduce single points of failure, and cost additional fees.

## The Solution

Hedera Schedule Service (HSS) with **HIP-1215** enables contracts to schedule calls to other contracts (including themselves) directly on-chain. This creates a **self-scheduling loop**:

```
Owner calls startAirdrop()
    └── Contract schedules executeAirdrop() via HSS (0x16b)
            └── Hedera network executes executeAirdrop() at scheduled time
                    └── executeAirdrop() schedules NEXT executeAirdrop()
                            └── Loop continues...
```

Key features of HSS:

- **System contract at `0x16b`**: `scheduleCall()` schedules a future function call
- **`hasScheduleCapacity()`**: Checks if a time slot has room for another scheduled call
- **Gas is prepaid**: The contract's HBAR balance pays for scheduled executions
- **Protocol-level execution**: The Hedera consensus nodes execute the calls -- no intermediary

## Understanding the Contract

### Imports and Inheritance

```solidity
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {HederaScheduleService} from "@hiero/system-contracts/schedule-service/HederaScheduleService.sol";
import {HederaResponseCodes} from "@hiero/system-contracts/common/HederaResponseCodes.sol";
import {PrngSystemContract} from "@hiero/system-contracts/prng/PrngSystemContract.sol";

contract HelloScheduledAirdrop is ERC20, Ownable, HederaScheduleService {
```

- **ERC20** (OpenZeppelin): Standard fungible token with `_mint`, `transfer`, `balanceOf`
- **Ownable** (OpenZeppelin v5): Access control -- only the owner can start/stop airdrops. Constructor requires `Ownable(msg.sender)`
- **HederaScheduleService**: Abstract contract providing `scheduleCall()` and `hasScheduleCapacity()` -- routes calls to the system contract at `0x16b`
- **HederaResponseCodes**: Status code constants; we check for `SUCCESS = 22`
- **PrngSystemContract**: Wraps the PRNG precompile at `0x169` for on-chain randomness

### State Variables and Config Struct

```solidity
uint256 constant GAS_LIMIT = 2_000_000;
uint256 constant MAX_PROBES = 8;

struct Config {
    uint256 amount;     // tokens per airdrop
    uint256 interval;   // seconds between drops
    uint256 maxDrops;   // 0 = unlimited
    uint256 completed;  // counter
    bool active;
    string message;
}

Config public config;
address[] public recipients;
mapping(address => bool) public isRegistered;
```

- **GAS_LIMIT**: Gas allocated for each scheduled execution (2 million)
- **MAX_PROBES**: Maximum number of time slots to probe during capacity-aware scheduling
- **Config**: Bundles all campaign settings into a single struct
- **recipients**: Array of registered addresses (needed for random index selection)
- **isRegistered**: Mapping for O(1) duplicate checking

### Registration Flow

```solidity
function registerForAirdrop() external {
    require(!isRegistered[msg.sender], "Already registered");
    isRegistered[msg.sender] = true;
    recipients.push(msg.sender);
    emit Registered(msg.sender);
}
```

Anyone can register. No approval needed. Prevents double registration via the `isRegistered` mapping.

### startAirdrop and the First Schedule

```solidity
function startAirdrop(
    uint256 _amount, uint256 _interval,
    uint256 _maxDrops, string calldata _message
) external onlyOwner {
    require(!config.active, "Already active");
    require(recipients.length > 0, "No recipients");

    config = Config({
        amount: _amount, interval: _interval,
        maxDrops: _maxDrops, completed: 0,
        active: true, message: _message
    });

    uint256 targetTime = block.timestamp + _interval;
    _scheduleWithCapacityCheck(targetTime);
    emit AirdropStarted(_amount, _interval, _maxDrops);
}
```

Only the owner can start. Validates that a campaign is not already running and that recipients exist. Sets up the config and immediately schedules the first `executeAirdrop()` call.

### executeAirdrop and the Self-Scheduling Loop

```solidity
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
```

This is the heart of the contract. The Hedera network calls this automatically at the scheduled time. It:

1. Picks a random recipient via PRNG
2. Mints tokens to them
3. Increments the counter
4. Emits an event
5. If not done, schedules the NEXT `executeAirdrop()` -- creating the loop

### Random Recipient Selection via PRNG

```solidity
function _randomRecipient() internal returns (address) {
    bytes32 seed = PrngSystemContract(address(0x169)).getPseudorandomSeed();
    return recipients[uint256(seed) % recipients.length];
}
```

Calls Hedera's built-in PRNG at `0x169`. The random seed is derived from the consensus process. No external oracle needed.

### Capacity-Aware Scheduling with Exponential Backoff

```solidity
function _findAvailableSecond(uint256 expiry) internal returns (uint256) {
    if (hasScheduleCapacity(expiry, GAS_LIMIT)) {
        emit SlotFound(expiry, expiry, 0);
        return expiry;
    }

    bytes32 seed = PrngSystemContract(address(0x169)).getPseudorandomSeed();

    for (uint256 i = 0; i < MAX_PROBES; i++) {
        uint256 baseDelay = 1 << i; // 1, 2, 4, 8, 16, 32, 64, 128
        bytes32 hash = keccak256(abi.encodePacked(seed, i));
        uint16 randomValue = uint16(uint256(hash));
        uint256 jitter = uint256(randomValue) % (baseDelay + 1);
        uint256 candidate = expiry + baseDelay + jitter;

        if (hasScheduleCapacity(candidate, GAS_LIMIT)) {
            emit SlotFound(expiry, candidate, i + 1);
            return candidate;
        }
    }

    uint256 fallbackTime = expiry + (1 << MAX_PROBES);
    emit SlotFound(expiry, fallbackTime, MAX_PROBES);
    return fallbackTime;
}
```

If the desired time slot is full, the contract probes nearby time slots with increasing distances (exponential backoff) and random offsets (jitter) to avoid thundering herd problems.

## Deploying to Testnet

### 1. Compile

```bash
forge build
```

You should see a green success message.

### 2. Load Environment

```bash
source .env
```

### 3. Deploy

```bash
forge create src/HelloScheduledAirdrop.sol:HelloScheduledAirdrop \
  --rpc-url $HEDERA_RPC_URL \
  --broadcast \
  --private-key $HEDERA_PRIVATE_KEY \
  --value 10ether \
  --constructor-args "Workshop Token" "WKSP" 0
```

- `--value 10ether` sends 10 HBAR to the contract (gas budget for scheduled executions)
- Constructor args: token name, symbol, initial supply (0 = all tokens minted via airdrops)

### 4. Save the Address

```bash
export CONTRACT_ADDR=0x<your-deployed-address>
```

Copy the `Deployed to:` address from the output.

## Interacting with the Contract

### Register Multiple Recipients

For the best demo experience, register **multiple addresses** before starting the airdrop. With only one recipient, the PRNG always picks the same address. With 3+ recipients, each airdrop visibly picks a different random address on HashScan.

**Register yourself:**

```bash
cast send $CONTRACT_ADDR "registerForAirdrop()" \
  --rpc-url $HEDERA_RPC_URL --private-key $HEDERA_PRIVATE_KEY
```

**Register a second account (if you have one):**

```bash
cast send $CONTRACT_ADDR "registerForAirdrop()" \
  --rpc-url $HEDERA_RPC_URL --private-key $SECOND_PRIVATE_KEY
```

**Audience participation (workshop setting):**

Share your contract address with the audience. Anyone can register on your contract using their own private key -- `registerForAirdrop()` is permissionless:

```bash
# Anyone can register on ANY deployed HelloScheduledAirdrop contract:
cast send <CONTRACT_ADDRESS> "registerForAirdrop()" \
  --rpc-url $HEDERA_RPC_URL --private-key $YOUR_PRIVATE_KEY
```

**Verify registrations:**

```bash
cast call $CONTRACT_ADDR "getRecipients()" --rpc-url $HEDERA_RPC_URL
```

### Start the Airdrop

```bash
cast send $CONTRACT_ADDR \
  "startAirdrop(uint256,uint256,uint256,string)" \
  1000000000000000000 30 10 "Hello from the future!" \
  --rpc-url $HEDERA_RPC_URL --private-key $HEDERA_PRIVATE_KEY
```

Parameters:

- `1000000000000000000` = 1 token (18 decimals)
- `30` = every 30 seconds
- `10` = stop after 10 drops
- `"Hello from the future!"` = message emitted with each airdrop

### Check Status

```bash
cast call $CONTRACT_ADDR "getStatus()(bool,uint256,uint256,uint256,uint256,uint256)" --rpc-url $HEDERA_RPC_URL
```

### Stop the Airdrop (Optional)

```bash
cast send $CONTRACT_ADDR "stopAirdrop()" \
  --rpc-url $HEDERA_RPC_URL --private-key $HEDERA_PRIVATE_KEY
```

## Verifying the Contract on HashScan

Verifying your contract makes the source code visible on HashScan, allowing anyone to read and audit it.

Hedera uses [Sourcify](https://docs.sourcify.dev/) for contract verification. Foundry has built-in support via the `forge verify-contract` command.

### Verify

Run the script to generate the bundles:

```bash
./generate_hedera_sc_metadata.sh HelloScheduledAirdrop
```

This produces a directory (e.g., verify-bundles/) containing a single metadata.json file for each contract.

Upload the following file to Hashscan's verification page:

- `verify-bundles/HelloScheduledWorld/metadata.json`

### View on HashScan

After verification succeeds:

1. Go to `hashscan.io/testnet/contract/<your-address>`
2. Click the **Contract** tab
3. You should see the verified Solidity source code, ABI, and constructor arguments

### Troubleshooting Verification

- **Wrong constructor args**: Ensure name, symbol, and initial supply match your deployment exactly
- **Compiler version mismatch**: Your local Solidity version must match what was used to deploy
- **Metadata mismatch**: If source files changed after deployment, you'll get a "partial match" instead of "full match" -- both still show source code

## Watching on HashScan

1. Open [hashscan.io/testnet](https://hashscan.io/testnet)
2. Paste your contract address in the search bar
3. Click on the **Events** tab
4. Watch `AirdropExecuted` events appear every ~30 seconds

What to look for:

- **Recipient address** changes each time (random selection via PRNG)
- **Drop number** increments: 1, 2, 3...
- **Message** matches what you set in `startAirdrop()`
- Nobody is calling this contract -- the **Hedera network** is executing it

You can also check the **Contract Calls** tab to see the `ScheduleCreate` transactions from the contract and the scheduled execution transactions from the network.

## Beyond the Workshop: Full HSS Capabilities

This workshop uses just two HSS functions: `scheduleCall()` and `hasScheduleCapacity()`. The full Schedule Service at `0x16b` exposes **10 functions** across three Hedera Improvement Proposals (HIPs), unlocking far more powerful design patterns.

### HIP-755: Multi-Party Authorization

| Function                       | Purpose                                                                 |
| ------------------------------ | ----------------------------------------------------------------------- |
| `authorizeSchedule(address)`   | Contract signs a pending scheduled transaction (programmatic co-signer) |
| `signSchedule(address, bytes)` | Submit EOA cryptographic signatures for a pending schedule              |

**Use cases:**

- **Multi-sig treasury**: 3-of-5 council members must authorize a payment before it executes
- **Escrow**: Both buyer and seller contracts must approve before funds are released
- **DAO governance**: Collect approval signatures over time, execute when threshold is met

### HIP-756: Native Token Scheduling

| Function                                          | Purpose                                           |
| ------------------------------------------------- | ------------------------------------------------- |
| `scheduleNative(address, bytes, address)`         | Schedule HTS operations (token creation, updates) |
| `getScheduledCreateFungibleTokenInfo(address)`    | Query details of a scheduled token creation       |
| `getScheduledCreateNonFungibleTokenInfo(address)` | Query details of a scheduled NFT creation         |

**Supported operations:** `createFungibleToken`, `createNonFungibleToken`, `createFungibleTokenWithCustomFees`, `createNonFungibleTokenWithCustomFees`, `updateToken`

**Use cases:**

- **Token launchpad**: Teams configure parameters and schedule creation for a specific launch date
- **Automated fee updates**: Periodically update custom fee schedules on tokens
- **NFT drops**: Schedule NFT collection creation at a specific time

### HIP-1215: Advanced Scheduling (Beyond scheduleCall)

| Function                           | Purpose                                                  |
| ---------------------------------- | -------------------------------------------------------- |
| `scheduleCall(...)`                | Schedule a contract call (what we used today)            |
| `scheduleCallWithPayer(...)`       | Schedule with a designated gas payer (sponsor execution) |
| `executeCallOnPayerSignature(...)` | Execute immediately when payer signs (not time-based)    |
| `deleteSchedule(address)`          | Cancel a pending scheduled transaction                   |
| `hasScheduleCapacity(...)`         | Check if a time slot has room (what we used today)       |

**Use cases:**

- **Sponsored execution**: Protocol treasury pays gas for user-initiated scheduled actions
- **Approval-gated workflows**: Scheduled action executes instantly when the approver signs
- **Cancellation flows**: Schedule a payment with the ability to cancel before execution

### Combining HIPs

The real power comes from combining capabilities across HIPs. For example:

1. A DAO votes to create a new token (**HIP-756** `scheduleNative`)
2. Three of five council members must sign (**HIP-755** `authorizeSchedule`)
3. The DAO treasury pays the gas (**HIP-1215** `scheduleCallWithPayer`)

All on-chain, all automated, all auditable.

### Where to Find These Interfaces

All function signatures are in the `hiero-contracts` library you already have installed:

```
lib/hiero-contracts/contracts/schedule-service/
├── HederaScheduleService.sol   # Unified implementation (all 10 functions)
├── IHRC755.sol                 # Multi-sig authorization interface
├── IHRC756.sol                 # Native token scheduling interface
├── IHRC1215.sol                # Advanced scheduling interface
├── IHRC755ScheduleFacade.sol   # Simplified signing interface
├── IHRC1215ScheduleFacade.sol  # Simplified deletion interface
└── IHRCScheduleFacade.sol      # Combined facade interface
```

**Further reading:**

- [HIP-755](https://hips.hedera.com/hip/hip-755) -- Schedule Service system contract
- [HIP-756](https://hips.hedera.com/hip/hip-756) -- Scheduling native system contract operations
- [HIP-1215](https://hips.hedera.com/hip/hip-1215) -- Generalized scheduled contract calls

## Use Cases

The self-scheduling pattern from this workshop can be adapted for:

- **Auto-Rebalancing Vaults** -- Rebalance DeFi portfolios on a schedule
- **Recurring Payments** -- Payroll, subscriptions, streaming payments
- **Token Vesting** -- Release tokens to team/investors on a schedule
- **Scheduled Governance** -- Timed voting rounds, automatic proposal execution
- **Game Mechanics** -- Turn-based games, auto-advancing game state
- **Oracle Refresh** -- Periodically fetch and update on-chain data

The self-scheduling pattern is identical across all use cases. Only the logic inside the scheduled function changes.

## Troubleshooting

### `INSUFFICIENT_PAYER_BALANCE`

Your account or contract does not have enough HBAR. Fund your account via the [faucet](https://portal.hedera.com/faucet) or send more HBAR to the contract.

### `CONTRACT_REVERT_EXECUTED`

Check your constructor arguments and ensure the contract compiled successfully with `forge build`.

### RPC Connection Error

Verify `HEDERA_RPC_URL` is set correctly in your `.env` file:

```
HEDERA_RPC_URL=https://testnet.hashio.io/api
```

### `Already registered`

You already called `registerForAirdrop()` from this address. Each address can only register once.

### `No recipients`

Call `registerForAirdrop()` with at least one address before calling `startAirdrop()`.

### `Already active`

An airdrop campaign is already running. Call `stopAirdrop()` first, then start a new one.

### `Not active`

The airdrop campaign is not running. Call `startAirdrop()` to begin a campaign.

### `Schedule failed`

The HSS scheduling call failed. Ensure your contract has sufficient HBAR balance to pay for scheduled execution gas. Send more HBAR to the contract:

```bash
cast send $CONTRACT_ADDR --value 10ether \
  --rpc-url $HEDERA_RPC_URL --private-key $HEDERA_PRIVATE_KEY
```

### Events Not Appearing on HashScan

HashScan refreshes every 5-10 seconds. The actual execution time may vary by a few seconds from the scheduled time due to consensus timestamp alignment. Wait up to 40 seconds after the expected interval.
