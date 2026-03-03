# Prerequisites

Everything you need to set up before the workshop.

## Table of Contents

1. [Hedera Testnet Account](#hedera-testnet-account)
2. [Foundry Installation](#foundry-installation)
3. [Environment Setup](#environment-setup)
4. [Testnet HBAR](#testnet-hbar)
5. [Verification](#verification)

---

## Hedera Testnet Account

You need a Hedera testnet account to deploy and interact with contracts.

### Step-by-Step

1. Go to [portal.hedera.com](https://portal.hedera.com)
2. Sign up or log in
3. Navigate to your testnet account
4. Note your **Account ID** (e.g., `0.0.12345`) and **EVM Address** (e.g., `0xabc...`)
5. Copy your **Private Key** (ECDSA hex format, starting with `0x`)

Your private key will look like:

```
0x302e020100300506032b657004220420...
```

Or in raw hex format:

```
0xabcdef1234567890...
```

## Foundry Installation

Foundry is the Solidity development toolkit we use for compiling, testing, and deploying.

### macOS / Linux

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

### WSL (Windows Subsystem for Linux)

```bash
curl -L https://foundry.paradigm.xyz | bash
source ~/.bashrc
foundryup
```

### Verify Installation

```bash
forge --version
cast --version
```

You should see version output for both commands (e.g., `forge 0.2.0`).

## Environment Setup

### 1. Clone the Repository

```bash
git clone https://github.com/hedera-dev/tutorial-hello-scheduled-airdrop.git
cd tutorial-hello-scheduled-airdrop
```

### 2. Install Dependencies

```bash
forge install
```

This installs the git submodules: `forge-std`, `openzeppelin-contracts`, and `hiero-contracts`.

### 3. Configure Environment Variables

```bash
cp .env.example .env
```

Edit `.env` with your credentials:

```
HEDERA_RPC_URL=https://testnet.hashio.io/api
HEDERA_PRIVATE_KEY=0x<your-private-key-here>
```

### 4. Load Environment

```bash
source .env
```

## Testnet HBAR

You need testnet HBAR to pay for gas when deploying and interacting with contracts.

### Get HBAR from the Faucet

1. Go to [portal.hedera.com/faucet](https://portal.hedera.com/faucet)
2. Enter your testnet Account ID
3. Click "Receive" to get testnet HBAR
4. You should receive 100 HBAR (sufficient for the workshop)

### Verify Balance

You can check your balance on [HashScan](https://hashscan.io/testnet):

1. Go to [hashscan.io/testnet](https://hashscan.io/testnet)
2. Search for your Account ID or EVM address
3. Check the HBAR balance

## Verification

Run these commands to confirm everything is working:

### 1. Check Foundry

```bash
forge --version
```

Expected: Version information printed.

### 2. Check Environment

```bash
echo $HEDERA_RPC_URL
echo $HEDERA_PRIVATE_KEY
```

Expected: Your RPC URL and private key printed (ensure they are not empty).

### 3. Compile the Project

```bash
forge build
```

Expected: `Compiler run successful` message.

### 4. Run Tests

```bash
forge test
```

Expected: All tests pass.

### 5. Test RPC Connection

```bash
cast block-number --rpc-url $HEDERA_RPC_URL
```

Expected: A block number printed (e.g., `12345678`).

---

If all five checks pass, you are ready for the workshop.
