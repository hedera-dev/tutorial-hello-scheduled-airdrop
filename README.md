# Hello Scheduled Airdrop

**Build a Self-Scheduling ERC20 Airdrop on Hedera**

A hands-on workshop project demonstrating how smart contracts can autonomously schedule their own future execution using Hedera Schedule Service (HSS) and HIP-1215. No off-chain bots. No cron jobs. Just a contract that runs itself.

## What You'll Build

A self-scheduling ERC20 token contract that:

1. Lets users register for airdrops
2. Picks random recipients using Hedera's on-chain PRNG (0x169)
3. Mints tokens to winners at configurable intervals
4. Schedules its own next execution via HSS (0x16b)
5. Handles scheduling congestion with exponential backoff and jitter
6. Stops automatically after a configurable number of drops

## Key Concepts

- **Hedera Schedule Service (HSS)** -- The system contract at `0x16b` that enables on-chain scheduling
- **HIP-1215** -- The Hedera Improvement Proposal that allows contracts to schedule calls to themselves
- **Self-Scheduling Loop** -- The pattern where `executeAirdrop()` schedules the next `executeAirdrop()`
- **Capacity-Aware Scheduling** -- Using `hasScheduleCapacity()` with exponential backoff to find available time slots
- **On-Chain PRNG** -- Hedera's pseudorandom number generator at `0x169` for random recipient selection

## Quick Start

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) installed
- A Hedera testnet account ([portal.hedera.com](https://portal.hedera.com))
- Testnet HBAR from the [faucet](https://portal.hedera.com/faucet)

### Setup

```bash
# Clone the repository
git clone https://github.com/hedera-dev/tutorial-hello-scheduled-airdrop.git
cd tutorial-hello-scheduled-airdrop

# Install dependencies
forge install

# Configure environment
cp .env.example .env
# Edit .env with your Hedera testnet credentials
```

### Build & Test

```bash
# Compile
forge build

# Run tests
forge test
```

### Deploy

```bash
# Load environment variables
source .env

# Deploy with 10 HBAR for scheduled execution gas
forge create src/HelloScheduledAirdrop.sol:HelloScheduledAirdrop \
  --rpc-url $HEDERA_RPC_URL \
  --broadcast \
  --private-key $HEDERA_PRIVATE_KEY \
  --value 10ether \
  --constructor-args "Workshop Token" "WKSP" 0

# Save the deployed address
export CONTRACT_ADDR=0x<your-deployed-address>
```

### Interact

```bash
# Register yourself as a recipient
cast send $CONTRACT_ADDR 'registerForAirdrop()' \
  --rpc-url $HEDERA_RPC_URL --private-key $HEDERA_PRIVATE_KEY

# Start the airdrop: 1 token every 30 seconds, 10 drops max
cast send $CONTRACT_ADDR \
  'startAirdrop(uint256,uint256,uint256,string)' \
  1000000000000000000 30 10 'Hello from the future!' \
  --rpc-url $HEDERA_RPC_URL --private-key $HEDERA_PRIVATE_KEY

# Check status
cast call $CONTRACT_ADDR 'getStatus()(bool,uint256,uint256,uint256,uint256,uint256)' --rpc-url $HEDERA_RPC_URL
```

### Watch on HashScan

Open [hashscan.io/testnet](https://hashscan.io/testnet) and navigate to your contract address. Click the **Events** tab to see `AirdropExecuted` events appearing every ~30 seconds -- all triggered autonomously by the Hedera network.

## Project Structure

```
hello-scheduled-airdrop/
├── .env.example                    # Environment variable template
├── .gitignore                      # Git ignore rules
├── .gitmodules                     # Git submodule definitions
├── .vscode/
│   └── settings.json               # VS Code Solidity settings
├── LICENSE                         # MIT License
├── README.md                       # This file
├── docs/
│   ├── GUIDE.md                    # Full step-by-step workshop guide
│   ├── HOW_IT_WORKS.md             # Deep dive on the self-scheduling pattern
│   ├── PREREQUISITES.md            # Setup instructions
│   └── diagrams/
│       └── architecture.md         # Mermaid diagram of the self-scheduling loop
├── foundry.toml                    # Foundry configuration with remappings
├── lib/
│   ├── forge-std/                  # Foundry standard library (submodule)
│   ├── hiero-contracts/            # Hiero system contracts (submodule)
│   └── openzeppelin-contracts/     # OpenZeppelin contracts (submodule)
├── src/
│   └── HelloScheduledAirdrop.sol   # The main contract
└── test/
    └── HelloScheduledAirdrop.t.sol # Foundry tests
```

## How It Works

The contract uses a **self-scheduling loop** pattern:

1. **Owner** calls `startAirdrop()` with campaign parameters
2. The contract calls `scheduleCall()` on the HSS system contract (`0x16b`) to schedule `executeAirdrop()` for a future time
3. When the scheduled time arrives, the **Hedera network** automatically calls `executeAirdrop()`
4. `executeAirdrop()` picks a random recipient via PRNG (`0x169`), mints tokens, and schedules the **next** `executeAirdrop()`
5. The loop continues until `maxDrops` is reached or the owner calls `stopAirdrop()`

For a detailed technical explanation, see [docs/HOW_IT_WORKS.md](docs/HOW_IT_WORKS.md).

## Resources

- [HIP-1215: Contract-to-Contract Scheduled Transactions](https://hips.hedera.com/hip/hip-1215)
- [Hedera Schedule Service Documentation](https://docs.hedera.com/hedera/core-concepts/smart-contracts/system-smart-contracts/hedera-schedule-service)
- [hiero-contracts Repository](https://github.com/hiero-ledger/hiero-contracts)
- [Hedera Developer Portal](https://portal.hedera.com)
- [Foundry Book](https://book.getfoundry.sh/)

## License

[MIT](LICENSE)
