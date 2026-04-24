# StreamPay — Real-time USDC Streaming on Arc

> USDC flows every second. Withdraw anytime. Cancel for instant fair refund.

[![Arc Testnet](https://img.shields.io/badge/Arc-Testnet-e040fb?style=flat-square&logo=ethereum)](https://testnet.arcscan.app)
[![USDC](https://img.shields.io/badge/Token-USDC-2775CA?style=flat-square)](https://www.circle.com/usdc)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.24-363636?style=flat-square&logo=solidity)](https://soliditylang.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-00ff88?style=flat-square)](LICENSE)
[![Built with Foundry](https://img.shields.io/badge/Built_with-Foundry-orange?style=flat-square)](https://getfoundry.sh)

---

## What is StreamPay?

StreamPay is a **real-time USDC payment streaming protocol** built natively on Arc. Instead of sending a lump-sum payment, a sender deposits USDC into a stream — and it flows continuously to the recipient, second by second, until the stream ends or is cancelled.

**Why Arc?**
- Arc's **sub-second deterministic finality** means payments settle the moment you click — no waiting for confirmations
- **$0.01/tx gas in USDC** makes per-second micropayment streams economically viable — impossible on chains with volatile gas
- **ERC-20 USDC as native token** means no currency conversion, no volatility exposure

---

## Live Contracts (Arc Testnet)

| Contract | Address |
|---|---|
| **StreamPay** | [`0x46937C3663101b3fE7F282A49F397d1f5C17a54B`](https://testnet.arcscan.app/address/0x46937C3663101b3fE7F282A49F397d1f5C17a54B) |
| **USDC** (6 dec) | [`0x3600000000000000000000000000000000000000`](https://testnet.arcscan.app/address/0x3600000000000000000000000000000000000000) |

**Network:** Arc Testnet · Chain ID `5042002` · RPC `https://rpc.testnet.arc.network`

---

## How It Works

```
Sender                    StreamPay Contract              Recipient
  │                             │                              │
  ├── approve(USDC) ───────────►│                              │
  ├── createStream() ──────────►│ USDC locked                  │
  │                             │ flowing per second ─────────►│
  │                             │                              │
  │                    (anytime)│◄──── withdraw() ─────────────│
  │                             │ earned USDC sent instantly   │
  │                             │                              │
  ├── cancel() ────────────────►│ earned → recipient           │
  │◄────────────────────────────│ unspent → sender refund      │
```

### Four actions, all onchain:

| Action | Who | What happens |
|---|---|---|
| `createStream()` | Sender | Locks USDC, stream starts flowing immediately |
| `withdraw()` | Recipient | Claims all earned USDC up to this second |
| `cancel()` | Sender | Atomic split: earned to recipient, rest refunded |
| `topUp()` | Sender | Adds USDC, extends stream duration proportionally |

---

## Use Cases

- **Freelancer salaries** — pay per second worked, not monthly
- **Subscriptions** — streaming SaaS payments that stop the moment you cancel
- **Escrow with time** — release funds gradually as milestones are met over time
- **SEA gig workers** — eliminate the 24–48hr platform payout delay
- **DAO contributor pay** — stream tokens to contributors for the duration of a proposal

---

## Technical Design

### USDC Decimal Safety
Arc's USDC has two decimal contexts. StreamPay uses **ERC-20 exclusively (6 decimals)**:

| Interface | Decimals | Usage in StreamPay |
|---|---|---|
| ERC-20 (`transfer`, `balanceOf`) | **6** | All amounts — `1 USDC = 1_000_000` |
| Native gas token (`msg.value`) | 18 | Never used for amounts |

### Rate Precision
`ratePerSecond` is stored scaled by `1e18` to avoid rounding-to-zero for small amounts over long durations:

```solidity
uint256 ratePerSecond = (deposit * 1e18) / duration;
// descale when reading: earned = (ratePerSecond * elapsed) / 1e18
```

This allows streaming as little as `1 USDC over 1 year` without precision loss.

### Withdrawable Calculation (view, no gas)
```solidity
function withdrawable(uint256 streamId) external view returns (uint256) {
    uint256 elapsed  = min(block.timestamp, s.stopTime) - s.startTime;
    uint256 earned   = min(s.deposit, (s.ratePerSecond * elapsed) / 1e18);
    return earned > s.withdrawn ? earned - s.withdrawn : 0;
}
```

---

## Project Structure

```
streampay/
├── src/
│   └── StreamPay.sol          — Core protocol (single contract, ~270 lines)
├── test/
│   └── StreamPay.t.sol        — Foundry test suite
├── script/
│   └── Deploy.s.sol           — Arc testnet deploy script
├── web/
│   └── index.html             — Full web UI (single file, no build step)
└── foundry.toml
```

---

## Quickstart

### 1. Add Arc Testnet to MetaMask

| Field | Value |
|---|---|
| Network name | Arc Testnet |
| RPC URL | `https://rpc.testnet.arc.network` |
| Chain ID | `5042002` |
| Currency | USDC |
| Explorer | `https://testnet.arcscan.app` |

Get testnet USDC: [faucet.circle.com](https://faucet.circle.com)

### 2. Install & build

```bash
git clone https://github.com/YOUR_USERNAME/streampay
cd streampay
forge install foundry-rs/forge-std
forge build
```

### 3. Deploy

```bash
export PRIVATE_KEY=0x_YOUR_PRIVATE_KEY

forge script script/Deploy.s.sol \
  --rpc-url https://rpc.testnet.arc.network \
  --broadcast \
  --private-key $PRIVATE_KEY
```

### 4. Configure & run web UI

Edit `web/index.html`:
```js
let STREAMPAY_ADDR = "0xYOUR_DEPLOYED_ADDRESS";
```

```bash
cd web
npx serve .
# Open http://localhost:3000
```

---

## Web UI Features

- **Create Stream** — Set recipient, amount, duration, label. Live rate preview shows $/sec and $/hr before confirming
- **Receiving tab** — All incoming streams with live USDC counter (updates 10x/second), withdraw button
- **Sent tab** — All outgoing streams with cancel and top-up actions, CSV export
- **Dashboard** — Portfolio overview: total sent/received, active count, earnings right now, flow rate chart
- **History** — Filterable full stream history (All / Sent / Received / Active / Completed / Cancelled) with CSV export

---

## CSV Export Format

```
Stream ID, Role, Description, Sender, Recipient, Deposit (USDC),
Rate (USDC/hr), Withdrawn (USDC), Status, Start Date, End Date, Duration (days)
```

---

## What Makes StreamPay Different

| Feature | StreamPay | Traditional transfer | Typical streaming (Ethereum) |
|---|---|---|---|
| Settlement speed | Per-second | Lump sum | Per-second |
| Fee predictability | $0.01 USDC fixed | Varies | $5–$50 ETH volatile |
| Cancel & refund | Instant, atomic | No partial refund | Yes but expensive |
| Token | USDC (stablecoin) | Native asset | ETH/ERC-20 |
| Finality | <1 second | Minutes | Minutes + reorg risk |

---

## Built on Arc

StreamPay is built on [Arc](https://arc.network) — the Layer-1 blockchain built for stablecoin-native finance, developed by Circle. Arc's design choices (USDC as gas token, sub-second finality, EVM compatibility) make StreamPay viable where it wouldn't be elsewhere.

---

## License

MIT

---

*Deployed on Arc testnet. Not financial advice. Testnet USDC has no real value.*
