# Token Tools Kit

Foundry contracts for ERC20 locks and vesting, ERC721 locks, ERC20 batch transfers, and asset disposal. All application calls and operation events go through `AssetRouter`.

This is a prototype without an independent security audit.

## Setup

Install [Foundry](https://getfoundry.sh/introduction/installation/) 1.8.5 or newer and Git. Then run from this directory:

```sh
forge install --no-git $(cat dependencies.txt)
forge build
forge test
```

`dependencies.txt` pins OpenZeppelin Contracts 5.6.1 and forge-std 1.17.0 to exact commits. `remappings.txt` resolves their imports. Solidity 0.8.37 and the Cancun EVM target are set in `foundry.toml`. Deploy only on a chain that supports Cancun.

The kit contains source files and configuration. Dependencies are downloaded into `lib/`; `forge build` generates ABI, bytecode, and build metadata in `out/` and `cache/`. Those directories are excluded from the kit. `forge fmt --check` checks formatting.

## Deploy

Deploy `AssetRouter` only. Its constructor creates a separate `ThousandYearVault`. Each ERC20 schedule creates its own `FixedBeneficiaryVesting` wallet. The factory, NFT locker, and batch distributor are inherited router modules.

Preview a deployment:

```sh
forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC_URL"
```

Broadcast using a Foundry keystore account:

```sh
forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC_URL" --account deployer --broadcast
```

Replace `deployer` with your account name. Foundry writes deployment results to `broadcast/`. Read the vault address with `disposalVault()` on the router.

## Use the router

Approve the router on each asset contract before depositing or distributing. ERC20 calls use the caller's allowance. NFT calls require the caller to own the NFT and approve the router. Amounts are integer base units; timestamps and durations are seconds.

| Operation | Router function | Result |
|---|---|---|
| ERC20 lock or vesting | `createVesting(token, amount, beneficiary, start, duration, cliff)` | Creates and funds a wallet; returns its address |
| Release vested ERC20 | `releaseVesting(wallet, token)` | Pays the fixed beneficiary |
| Release vested native currency | `releaseVestingNative(wallet)` | Pays incidental native deposits to the same beneficiary |
| NFT lock | `lock(collection, tokenId, beneficiary, unlockAt)` | Holds the NFT at the router until the deadline |
| Release NFT | `release(collection, tokenId)` | Pays the recorded beneficiary |
| Redirect NFT release | `releaseTo(collection, tokenId, destination)` | Beneficiary chooses another destination after the deadline |
| ERC20 batch | `distribute(token, recipients, amounts)` | Transfers directly from the caller to each recipient |
| ERC20 disposal | `disposeERC20(token, amount, nativeBurn)` | Burns or deposits into the long-term vault |
| NFT disposal | `disposeERC721(collection, tokenId, nativeBurn)` | Burns or deposits into the long-term vault |
| Release disposal lock | `releaseDisposalLock(depositId)` | Pays the recorded beneficiary after maturity |
| Redirect disposal release | `releaseDisposalLockTo(depositId, destination)` | Beneficiary chooses another destination after maturity |

Anyone can trigger a release to the recorded beneficiary. Only that beneficiary can redirect it. Release requires a transaction; reaching a deadline does not move assets automatically.

### ERC20 schedules

For a date lock, set `start = unlockAt`, `duration = 0`, and `cliff = 0`. For linear vesting, set `duration > 0`. The start cannot be in the past, and the cliff cannot exceed the duration.

A cliff delays access while accrual still starts at `start`. For 1,000 units over 1,000 seconds with a 200-second cliff, 200 units become available at the cliff. Additional deposits into a wallet follow its original schedule.

Read wallet balances with `releasable(token)`, `released(token)`, and `vestedAmount(token, timestamp)`. The beneficiary is fixed, and wallet releases must go through the creating router.

### Burn or long-term lock

Set `nativeBurn = true` only when the asset has a verified compatible `burn(uint256)` implementation. The router takes custody, calls `burn`, and checks the resulting balance and supply or NFT ownership state. A failed burn reverts the entire transaction.

Set `nativeBurn = false` for the fallback lock. The asset goes into the separate vault for exactly `1000 * 365 days` (31,536,000,000 seconds). It can be released after that deadline, so this is a long lock rather than a permanent burn. The depositing user is its beneficiary.

ERC20 and ERC721 do not provide a standard way to detect burn support. The application must select the mode using verified asset information. It must not silently retry a failed burn as a lock.

### Batch input

The frontend parses JSON into parallel `recipients` and `amounts` arrays and submits one `distribute` call. This kit contains the contracts; JSON parsing belongs in the application.

Use address validation and integer amount strings in the frontend. Convert human-readable amounts to base units without floating-point arithmetic. Estimate gas before submitting; the chain's transaction gas limit bounds batch size.

All transfers succeed or the whole batch reverts. Each recipient must receive the exact requested amount. Zero amounts and zero, caller, or router recipient addresses are rejected. Duplicate recipients are allowed, and the same batch can be submitted again.

## Events and reads

Listen at the router address for `VestingCreated`, `VestingReleased`, `NativeVestingReleased`, `Locked`, `Released`, `BatchDistributed`, `ERC20Burned`, `ERC721Burned`, `DisposalLocked`, and `DisposalLockReleased`.

Read NFT schedules with `locks(collection, tokenId)`, registered wallets with `isVestingWallet(wallet)`, and disposal records with `deposits(depositId)` on the vault. Token contracts and vesting wallets also emit their own standard events. Direct deposits outside the router do not produce router events.

## Constraints

The contracts have no admin, upgrades, cancellation, or early withdrawals. Use ordinary ERC20 and ERC721 implementations. Transfer fees are rejected on deposits and batches; rebasing, malicious assets, and tokens with unusual balance or transfer rules need separate integration. Burn checks cannot establish trust in a malicious asset contract.

Do not send assets directly to the router or vault. Unsolicited safe NFT transfers are rejected, but ERC20 transfers and plain NFT `transferFrom` cannot be blocked. Unrecorded deposits have no recovery route. Choose a beneficiary that can receive the asset; ERC20 vesting has no redirect function.

Do not use the vesting wallet for a chain asset that can be withdrawn as both native currency and ERC20 without adapting its accounting.

## Tests

The Solidity suite covers schedule boundaries, fixed beneficiaries, approvals, exact transfers, rollback, native deposits, burn checks, long-term maturity, router events, shared reentrancy protection, and router deployment size. Fuzz tests check batch balance conservation and vesting accrual.
