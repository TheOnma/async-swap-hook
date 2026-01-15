# AsyncSwap Hook

**Protecting large Uniswap swaps from sandwich attacks through delayed execution**

## The Problem I'm Solving

If you've ever made a large swap on Uniswap, you've probably been sandwiched without even realizing it. Here's what happens:

1. You submit a 2 ETH → USDC swap
2. A bot sees your transaction in the mempool
3. Bot buys USDC right before you, pushing the price up
4. Your swap executes at this inflated price
5. Bot immediately sells the USDC back, pocketing the difference

You just paid for the bot's profit through worse execution. On large swaps, this can cost hundreds or thousands of dollars.

I wanted to fix this at the protocol level, without requiring users to change their behavior or trust centralized relayers.

## How AsyncSwap Works

The core idea is simple: **sandwich attacks require atomicity**. If the bot can't guarantee their front-run → your swap → their back-run happens in the same block, the attack breaks down.

AsyncSwap pauses large swaps and executes them at a random time in the future:

### Step 1: Detection

When someone tries to swap more than 1% of a pool's liquidity, my hook intercepts it. I calculate this threshold dynamically based on current pool state:
```solidity
if (params.zeroForOne) {
    reserves0 = (liquidity * Q96) / sqrtPrice
    threshold = reserves0 * 1%
} else {
    reserves1 = (liquidity * sqrtPrice) / Q96  
    threshold = reserves1 * 1%
}
```

This uses Uniswap V3's concentrated liquidity math - specifically the relationship between liquidity `L`, sqrt price, and virtual reserves.

### Step 2: Custody & Delay

The hook takes custody of the input tokens and stores the swap details. Execution is scheduled for `24 seconds + random(0-60s)` in the future. This randomness comes from `block.prevrandao` and makes it impossible for bots to predict when the actual swap will happen.

### Step 3: Execution

Anyone can call `executeSwap()` after the delay period. They execute the actual swap through the PoolManager and earn 0.3% of the output as compensation for gas costs.

### Why This Works

- Bots can't front-run because they don't know when execution happens
- Even if they try to sandwich at execution time, they already lost their information advantage
- The randomized window means they'd have to hold positions for 24-84 seconds with unpredictable timing - killing profitability

## Design Decisions

**Why 1% threshold?**  
Testing showed this catches most sandwich-vulnerable swaps while letting normal trading flow through instantly. Below 1%, price impact is usually small enough that sandwiching isn't profitable.

**Why 0.3% executor fee?**  
Needs to cover gas costs (~30-50k gas) plus incentive to run the bot. At current gas prices, this is roughly break-even to slightly profitable.

**Why randomized execution?**  
Fixed delays would just shift the sandwich window. Randomization makes it economically unviable - bots would need to tie up capital for minutes with no guarantee of timing.

**Why allow cancellation?**  
If something goes wrong or too much time passes, users need an escape hatch. After `validUntil` expires, they can cancel and get their tokens back.

## Trade-offs

**What I gave up:**
- Instant execution for large swaps (24-84 second delay)
- Atomic guarantees (swap might fail if price moves against you)
- Some composability (other contracts can't use large swaps atomically)

**What users get:**
- Protection from sandwich attacks on large swaps
- Better execution prices (no MEV leak)
- Small swaps still execute instantly

I think this is a good trade. Waiting 30-60 seconds on a $10k+ swap to save $200 in MEV is worth it.

## Running Tests
```bash
forge test -vvv
```

### Key Test Scenarios
- Small swaps (<1% liquidity) pass through immediately  
- Large swaps get paused and held by the hook
- Execution after delay works correctly
- Time restrictions enforced (can't execute too early/late)
- Slippage protection prevents bad execution
- Only swap owner can cancel
- Executor receives correct fee

## Architecture
```
User → Router.swap()
  ↓
PoolManager
  ↓
AsyncSwapHook.beforeSwap() [detects large swap]
  ↓
Hook takes custody + stores pending swap
  ↓
[Time passes: 24-84 seconds]
  ↓
Executor → Hook.executeSwap()
  ↓
PoolManager.unlock() → Hook.unlockCallback()
  ↓
Actual swap executes
  ↓
Tokens distributed: User gets 99.7%, Executor gets 0.3%
```

## Status: Proof of Concept

### What Works
- Hook intercepts and pauses large swaps (>1% of liquidity)
- Randomized execution delay (24-84 seconds)
- Permissionless executor network with fee incentives
- Proper token accounting and settlement
- Slippage protection and cancellation mechanism
- **Comprehensive test coverage proving core mechanism**

### Known Limitation 🔧
The hook prevents mempool-based sandwich attacks but remains vulnerable 
to execution-time sandwiching. An attacker could front-run the 
`executeSwap()` call itself.

**This is a known limitation in asynchronous execution systems and cannot 
be solved at the smart contract level alone.**

**Built for Uniswap Hook Incubator 7**  
Contract: `0x3874c14783b5D30f52972D0D6cAa09d04A0D4088` (Sepolia)  
Demo: `https://www.loom.com/share/55cdbde2ccc940239b56f0456efb643b`
