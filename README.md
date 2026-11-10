# sweeper

`Sweeper` is a contract whose `sweep()` anyone can call: it sends its whole native balance to one address baked
into the code. Nothing else can move value.

## What it does

`src/Sweeper.sol`, about 15 lines of logic:

- `RECOVERY` is an immutable set in the constructor. Immutables are inlined into the runtime bytecode, so the
  installed code needs no storage and nothing can change it.
- `sweep()` can be called by anyone. It sends the full native balance to `RECOVERY` with `call` and reverts if
  that call fails. On a zero balance it returns without calling `RECOVERY` or emitting anything.
- `receive()` is empty, so the address keeps accepting native transfers, including from senders that forward very
  little gas. Anything received can only leave through `sweep()`.

There is no owner, admin, upgrade path, fallback, token logic, `delegatecall`, `selfdestruct` or storage
write. ERC20 balances held by the address are not reachable from this code at all.

## Producing the runtime code

```sh
script/runtime-code.sh <recovery-address>
```

It builds the contract, deploys `Sweeper(<recovery>)` on a throwaway local anvil (using anvil's unlocked dev
account, no keys), checks `RECOVERY()` and prints the runtime bytecode, its size and its keccak256. That runtime
bytecode is what gets installed at the target address. Compiler settings are pinned in `foundry.toml` (solc
0.8.30, optimizer 200 runs, no metadata hash) so the output is reproducible.

Each recovery address gives a different bytecode (the address is embedded). Addresses that share a recovery
address get identical code.

## Tests

```sh
forge test
```

Covers: full balance to `RECOVERY` from any caller (fuzzed), no way to redirect (extra calldata, other
selectors), ERC20 balances untouched, code size and an opcode scan (no `SSTORE`, `CREATE`, `CALLCODE`,
`DELEGATECALL`, `SELFDESTRUCT`, exactly one `CALL`), runtime code installed with `vm.etch` at an address that
already has a balance and nonce, a re-entering `RECOVERY`, a reverting `RECOVERY`, zero balance, and receiving
native value under a 2300/5000 gas stipend.

### Mainnet fork

```sh
POLYGON_RPC_URL=<polygon rpc> forge test            # fork tests are skipped without it
POLYGON_RPC_URL=<polygon rpc> script/fork-check.sh  # real txs on a local anvil fork
script/bor-check.sh <recovery-address>              # bor's own state transition
```

- `forge test` (fork): installs the runtime at real accounts (balance and nonce kept), sweeps each from a random
  caller and checks the full balance reaches `RECOVERY` while token balances do not move; repeated sweeps by many
  callers; native value sent after install through a plain transfer, `0x1010.transfer` and a bridge deposit
  through the `0x1001 -> ChildChain -> MRC20.deposit` path, all then sweepable; `RECOVERY` as a Safe, a
  delegatecall proxy that writes storage on receive, a reverting contract and a re-entering contract; replacing an
  existing 7702 delegation; and that no approval or permit path can move native value.
- `script/fork-check.sh`: the same sweep as real transactions, with receipt gas (about 38k into a Safe, about 57k
  into a fresh account, the extra being new-account cost). anvil does not enforce the EIP-3607 sender check, so it
  cannot show that an account holding the code can no longer send; that is what the next script is for.
- `script/bor-check.sh`: runs `test/bor/sweeper_core_test.go` inside bor's `core` package (v2.11.0 by default) with
  the real runtime code. A transaction signed by an address holding the code fails with `sender not an eoa`; an
  EIP-7702 authorization signed for it afterwards is skipped (`ErrAuthorizationDestinationHasCode`), so code and
  nonce stay; `sweep()` pays `RECOVERY`. It uses bor's state transition with a test consensus engine, not a full
  bor node.

## Trust assumptions

- `RECOVERY` is baked into the code. Whoever controls it gets the native balance.
- Anyone can trigger `sweep()`, but it can only ever pay `RECOVERY`. The caller pays the gas and chooses when.
- `RECOVERY` must accept native value. If it is a contract that reverts on receipt, `sweep()` reverts and the funds
  stay where they are.
