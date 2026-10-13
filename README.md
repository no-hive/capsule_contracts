<div align="center">
  <h1>Capsule Contracts</h1>
  <p>Smart contracts to manage your assets on Elysium (Hyperliquid L2) in one place.</p>
  <p>
    <a href="https://capsule-lock.space">Live App</a>
    &nbsp;·&nbsp;
    <a href="https://github.com/cape4labs/capsule_dapp">Frontend Code</a>
    &nbsp;·&nbsp;
    <a href="https://github.com/cape4labs">Team Behind</a>
  </p>
</div>

## What it does

`AssetRouter` is the single entry point for the application. It supports:

- ERC-20 locks and vesting;
- scheduled NFT locks;
- ERC-20 batch transfers;
- asset burning or long-term disposal locks;
- optional ERC-20 rewards for completed actions.

## Contracts

| Contract | Purpose |
|---|---|
| `AssetRouter` | Main application contract |
| `FixedBeneficiaryVesting` | ERC-20 vesting wallet with a fixed beneficiary |
| `ThousandYearVault` | Holds disposal deposits for 1,000 years |

Deployment addresses will be added here after launch.

## Actions

| Use case | Method |
|---|---|
| Create ERC-20 lock or vesting | `createVesting(...)` |
| Release vested funds | `releaseVesting(...)`, `releaseVestingNative(...)` |
| Lock or release NFT | `lock(...)`, `release(...)`, `releaseTo(...)` |
| Send ERC-20 to multiple wallets | `distribute(...)` |
| Burn or long-term lock an asset | `disposeERC20(...)`, `disposeERC721(...)` |
| Release a disposal lock | `releaseDisposalLock(...)`, `releaseDisposalLockTo(...)` |

Approve the router before transferring ERC-20 tokens or NFTs. Token amounts use base units; timestamps use Unix seconds.

## Ownership and rewards

The deployer is the initial owner. The owner can transfer ownership and set the ERC-20 reward token:

```solidity
transferOwnership(newOwner);
setRewardToken(tokenAddress);
```

Send reward tokens directly to the `AssetRouter` balance after setting the token.

Every action also has a version with `bool wantsReward` as its final parameter:

```solidity
router.lock(collection, tokenId, beneficiary, unlockAt, true);
```

`true` pays the caller `ACTION_REWARD()` from the router balance; `false` skips the reward. The current amount is `10 ether` (`10 * 10**18` base units). Reward tokens should use 18 decimals.

The transaction reverts if a requested reward cannot be paid. Original methods without `wantsReward` remain available and never pay a reward.

## Deploy

Deploy only `AssetRouter`:

```sh
forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC_URL" --account deployer --broadcast
```

Then:

1. Add the router address to the frontend configuration.
2. Set the reward token as the owner.
3. Fund the router with reward tokens.

## Development

Requires Foundry 1.8.5 or newer.

```sh
forge install --no-git $(cat dependencies.txt)
forge build
forge test
forge fmt --check
```

Solidity `0.8.37` · OpenZeppelin `5.6.1` · Cancun EVM

## Security

- Do not send assets directly to the router or vault: unrecorded deposits cannot be recovered.
- Use standard ERC-20 and ERC-721 implementations. Tokens with transfer fees or unusual behavior may be rejected.
- Use native burn mode only with a verified compatible `burn` function.

## License

MIT
