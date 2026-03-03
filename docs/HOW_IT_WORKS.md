# How It Works: Technical Deep Dive

A detailed technical explanation of the self-scheduling pattern, HSS internals, PRNG, capacity-aware scheduling, and security considerations.

## Table of Contents

1. [The Self-Scheduling Loop](#the-self-scheduling-loop)
2. [HSS System Contract (0x16b)](#hss-system-contract-0x16b)
3. [PRNG System Contract (0x169)](#prng-system-contract-0x169)
4. [Capacity-Aware Scheduling](#capacity-aware-scheduling)
5. [Gas Considerations](#gas-considerations)
6. [Security Considerations](#security-considerations)

---

## The Self-Scheduling Loop

The core innovation is a contract that schedules its own future execution. Here is the flow:

```
┌──────────────────────────────────────────────────────────┐
│                     SELF-SCHEDULING LOOP                 │
│                                                          │
│   Owner ──► startAirdrop()                               │
│                  │                                       │
│                  ▼                                       │
│          scheduleCall(executeAirdrop, t+interval)        │
│                  │                                       │
│                  ▼                                       │
│    ┌─── Hedera waits until scheduled time ───┐           │
│    │                                         │           │
│    ▼                                         │           │
│   executeAirdrop()                           │           │
│    │  1. Pick random recipient (PRNG)        │           │
│    │  2. Mint tokens                         │           │
│    │  3. Increment counter                   │           │
│    │  4. Emit event                          │           │
│    │                                         │           │
│    ├─── maxDrops reached? ───► STOP          │           │
│    │                                         │           │
│    └─── scheduleCall(executeAirdrop, t+interval) ──┘     │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

Each `executeAirdrop()` call schedules the next one. The chain of scheduled calls continues until `maxDrops` is reached or the owner calls `stopAirdrop()`.

### Why This Is Different

On most EVM chains, you need one of these to trigger a contract on schedule:

| Approach | Drawback |
|----------|----------|
| Off-chain bot (cron + ethers.js) | Single point of failure, server costs, downtime risk |
| Chainlink Automation | Third-party dependency, LINK token costs, 2-block delay |
| Gelato Network | Third-party dependency, fees, centralization risk |

With HSS, the scheduling is **native to the protocol**. No external service, no extra tokens, no off-chain infrastructure.

## HSS System Contract (0x16b)

The Hedera Schedule Service is accessible via a system contract deployed at address `0x16b`. It exposes two key functions:

### `scheduleCall`

```solidity
function scheduleCall(
    address to,           // Target contract address
    uint256 expirySecond, // Unix timestamp (in seconds) for execution
    uint256 gasLimit,     // Gas allocated for execution
    uint64 value,         // HBAR to send with the call (in tinybar)
    bytes calldata data   // ABI-encoded function call
) returns (int64 responseCode, address scheduleAddress)
```

When called:

1. Hedera creates a **scheduled transaction** on the network
2. At the specified `expirySecond`, the consensus nodes execute the `data` payload against the `to` address
3. Gas is paid from the **calling contract's HBAR balance** (not the caller's EOA)
4. Returns `SUCCESS (22)` if the schedule was created successfully

### `hasScheduleCapacity`

```solidity
function hasScheduleCapacity(
    uint256 expirySecond,
    uint256 gasLimit
) returns (bool)
```

A view-like function that checks whether a specific time slot can accept another scheduled call with the given gas limit. Hedera limits total scheduled gas per second to prevent network overload.

This is unique to Hedera -- no other chain exposes scheduling capacity information.

### How We Use It

In `HelloScheduledAirdrop._schedule()`:

```solidity
function _schedule(uint256 time) internal {
    bytes memory data = abi.encodeWithSelector(this.executeAirdrop.selector);
    (int64 responseCode,) = scheduleCall(address(this), time, GAS_LIMIT, 0, data);
    require(responseCode == HederaResponseCodes.SUCCESS, "Schedule failed");
}
```

We encode a call to `executeAirdrop()` and schedule it for execution at `time`. The contract calls itself in the future.

## PRNG System Contract (0x169)

Hedera provides a built-in pseudorandom number generator at address `0x169`:

```solidity
function getPseudorandomSeed() external returns (bytes32)
```

### How It Works

- The random seed is derived from the **Hedera consensus process**
- It incorporates the transaction's running hash, consensus timestamp, and other entropy sources
- The seed is **unpredictable before consensus** but **deterministic after**
- Validators cannot manipulate it because they would need to control the entire consensus process

### How We Use It

```solidity
function _randomRecipient() internal returns (address) {
    bytes32 seed = PrngSystemContract(address(0x169)).getPseudorandomSeed();
    return recipients[uint256(seed) % recipients.length];
}
```

We get a random `bytes32`, convert it to a `uint256`, and take the modulo of the recipients array length to get a uniformly distributed random index.

### Comparison with Ethereum

| Feature | Hedera PRNG | Chainlink VRF |
|---------|-------------|---------------|
| Cost | Gas only | 0.25+ LINK (~$3-5) per request |
| Latency | Same transaction | 2-block delay for callback |
| Integration | 1 function call | Subscription + callback pattern |
| Verifiability | Consensus-derived | Cryptographically provable |
| Suitability | Airdrops, games, most DeFi | High-stakes lotteries |

## Capacity-Aware Scheduling

### The Problem

What happens when the time slot you want is already full? Another contract may have already scheduled something for that exact second.

### The Solution: Exponential Backoff with Jitter

```solidity
function _findAvailableSecond(uint256 expiry) internal returns (uint256) {
    // Try exact time first
    if (hasScheduleCapacity(expiry, GAS_LIMIT)) return expiry;

    // Get random seed for jitter
    bytes32 seed = PrngSystemContract(address(0x169)).getPseudorandomSeed();

    // Exponential backoff: probe at 1, 2, 4, 8, 16, 32, 64, 128 seconds
    for (uint256 i = 0; i < MAX_PROBES; i++) {
        uint256 baseDelay = 1 << i;
        bytes32 hash = keccak256(abi.encodePacked(seed, i));
        uint16 randomValue = uint16(uint256(hash));
        uint256 jitter = uint256(randomValue) % (baseDelay + 1);
        uint256 candidate = expiry + baseDelay + jitter;

        if (hasScheduleCapacity(candidate, GAS_LIMIT)) return candidate;
    }

    // Fallback: 256 seconds from original time
    return expiry + (1 << MAX_PROBES);
}
```

### Algorithm Breakdown

1. **Try exact time**: If the slot is available, use it (zero overhead)
2. **Exponential probing**: If not, probe at increasing distances: +1s, +2s, +4s, +8s, +16s, +32s, +64s, +128s
3. **Random jitter**: Each probe adds a random offset between 0 and `baseDelay` to prevent multiple contracts from landing on the same fallback slot
4. **Single PRNG call**: The jitter is derived from `keccak256(seed, i)` -- one PRNG call generates jitter for all 8 probes
5. **Fallback**: If all 8 probes fail, schedule at +256 seconds from the original target

### Why Exponential Backoff?

Linear probing (t+1, t+2, t+3, ...) causes a **thundering herd** problem -- all contracts trying to find an open slot will probe the same sequence of times. Exponential backoff spreads probes across a wider range, reducing collisions.

### Why Jitter?

Even with exponential backoff, multiple contracts with the same base time would still probe the same sequence. Random jitter ensures each contract probes a different set of candidate times.

### Gas Cost

Each `hasScheduleCapacity` call costs approximately 5k-10k gas. With up to 8 probes, the worst-case overhead is ~80k gas -- acceptable for reliable scheduling.

## Gas Considerations

### How Scheduled Execution Gas Is Paid

When a scheduled call executes:

1. Gas is paid from the **contract's HBAR balance** (not any EOA)
2. The gas limit is specified at scheduling time (`GAS_LIMIT = 2_000_000`)
3. Unused gas is refunded to the contract
4. If the contract runs out of HBAR, scheduled calls will fail

### HBAR Budget Planning

For a 10-drop campaign with 30-second intervals:

- Each `executeAirdrop()` costs approximately 200k-500k gas
- At testnet gas prices (~0.000001 HBAR/gas), each execution costs ~0.0002-0.0005 HBAR
- The scheduling call itself adds ~50k-100k gas
- Total for 10 drops: ~0.005-0.01 HBAR

Deploying with `--value 10ether` (10 HBAR) provides a generous budget for thousands of scheduled executions.

### GAS_LIMIT Choice

`GAS_LIMIT = 2_000_000` is set conservatively. The actual execution typically uses 200k-500k gas, but the limit must account for:

- PRNG precompile call
- Token minting (ERC20 `_mint`)
- Capacity-aware scheduling (up to 8 `hasScheduleCapacity` calls)
- The `scheduleCall` itself

## Security Considerations

### Re-Entrancy

Not a concern in this contract because:

- `_mint()` is an internal OpenZeppelin call (no external contract interaction)
- `scheduleCall()` targets a trusted system contract (`0x16b`)
- `getPseudorandomSeed()` targets a trusted system contract (`0x169`)

For production contracts using this pattern, consider adding OpenZeppelin's `ReentrancyGuard` if the scheduled function interacts with untrusted external contracts.

### Access Control

- `startAirdrop()` and `stopAirdrop()` are `onlyOwner`
- `executeAirdrop()` is `external` without access restriction -- this is intentional because the caller is the Hedera network (scheduled execution), not an EOA
- `registerForAirdrop()` is permissionless by design

### HBAR Balance Monitoring

If the contract's HBAR balance drops to zero, scheduled calls will fail silently. In production:

- Monitor the contract's HBAR balance
- Implement a minimum balance check in `executeAirdrop()`
- Set up alerts when the balance drops below a threshold
- Consider adding a `fundContract()` function or allowing anyone to send HBAR via `receive()`

### PRNG Predictability

Hedera's PRNG is pseudorandom, not cryptographically random. For this airdrop use case, it is more than sufficient. For high-stakes applications (lotteries with significant prizes), consider additional entropy sources.

### Campaign State

- The `config.active` flag prevents double-starts and controls the scheduling loop
- `stopAirdrop()` immediately sets `active = false`, which stops the loop at the next scheduled execution
- If a scheduled `executeAirdrop()` is already in-flight when `stopAirdrop()` is called, it will execute but will not schedule another call (because `config.active` will be `false` by then)
