package core

// Copied into a bor checkout's core/ package by script/bor-check.sh.

import (
	"bytes"
	"math/big"
	"os"
	"strings"
	"testing"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/consensus/beacon"
	"github.com/ethereum/go-ethereum/core/rawdb"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/params"
	"github.com/holiman/uint256"
)

func sweeperFixture(t *testing.T) (code []byte, recovery common.Address) {
	t.Helper()
	code = common.FromHex(os.Getenv("SWEEPER_RUNTIME"))
	if len(code) == 0 {
		t.Skip("SWEEPER_RUNTIME not set")
	}
	return code, common.HexToAddress(os.Getenv("SWEEPER_RECOVERY"))
}

func TestSweeperSenderRejected(t *testing.T) {
	code, _ := sweeperFixture(t)
	var (
		config   = params.MergedTestChainConfig
		signer   = types.LatestSigner(config)
		engine   = beacon.NewFaker()
		key, _   = crypto.GenerateKey()
		target   = crypto.PubkeyToAddress(key.PublicKey)
		funds    = new(big.Int).Mul(big.NewInt(1000), big.NewInt(params.Ether))
		gspec    = &Genesis{Config: config, Alloc: types.GenesisAlloc{target: {Balance: funds, Nonce: 5, Code: code}}}
		chain, _ = NewBlockChain(rawdb.NewMemoryDatabase(), gspec, engine, nil)
		tx       = types.MustSignNewTx(key, signer, &types.DynamicFeeTx{ChainID: config.ChainID, Nonce: 5, To: &common.Address{1}, Value: big.NewInt(params.Ether), Gas: 21000, GasFeeCap: newGwei(5), GasTipCap: big.NewInt(1)})
	)
	defer chain.Stop()
	block := GenerateBadBlock(gspec.ToBlock(), engine, types.Transactions{tx}, config, false)
	_, err := chain.InsertChain(types.Blocks{block}, false)
	if err == nil || !strings.Contains(err.Error(), "sender not an eoa") {
		t.Fatalf("want sender not an eoa, got %v", err)
	}
	t.Logf("rejected: %v", err)
}

func TestSweeperAuthorizationIgnoredAndSweepWorks(t *testing.T) {
	code, recovery := sweeperFixture(t)
	var (
		config      = params.MergedTestChainConfig
		signer      = types.LatestSigner(config)
		engine      = beacon.NewFaker()
		key, _      = crypto.GenerateKey()
		target      = crypto.PubkeyToAddress(key.PublicKey)
		relayKey, _ = crypto.GenerateKey()
		relayer     = crypto.PubkeyToAddress(relayKey.PublicKey)
		delegate    = common.HexToAddress("0x000000000000000000000000000000000000aaaa")
		funds       = new(big.Int).Mul(big.NewInt(1000), big.NewInt(params.Ether))
		gspec       = &Genesis{Config: config, Alloc: types.GenesisAlloc{
			target:   {Balance: funds, Nonce: 5, Code: code},
			relayer:  {Balance: funds},
			delegate: {Code: []byte{0x00}},
		}}
	)
	auth, _ := types.SignSetCode(key, types.SetCodeAuthorization{ChainID: *uint256.MustFromBig(config.ChainID), Address: delegate, Nonce: 5})
	sweep := crypto.Keccak256([]byte("sweep()"))[:4]

	_, blocks, receipts := GenerateChainWithGenesis(gspec, engine, 1, func(i int, b *BlockGen) {
		b.AddTx(types.MustSignNewTx(relayKey, signer, &types.SetCodeTx{
			ChainID: uint256.MustFromBig(config.ChainID), Nonce: 0, To: delegate, Gas: 100000,
			GasFeeCap: uint256.MustFromBig(newGwei(5)), GasTipCap: uint256.NewInt(1),
			AuthList: []types.SetCodeAuthorization{auth},
		}))
		b.AddTx(types.MustSignNewTx(relayKey, signer, &types.DynamicFeeTx{
			ChainID: config.ChainID, Nonce: 1, To: &target, Gas: 100000, GasFeeCap: newGwei(5), GasTipCap: big.NewInt(1), Data: sweep,
		}))
	})
	chain, err := NewBlockChain(rawdb.NewMemoryDatabase(), gspec, engine, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer chain.Stop()
	if n, err := chain.InsertChain(blocks, false); err != nil {
		t.Fatalf("block %d: %v", n, err)
	}
	st, _ := chain.State()
	if !bytes.Equal(st.GetCode(target), code) {
		t.Fatalf("target code changed to %x", st.GetCode(target))
	}
	if st.GetNonce(target) != 5 {
		t.Fatalf("target nonce changed to %d", st.GetNonce(target))
	}
	if !st.GetBalance(target).IsZero() || st.GetBalance(recovery).ToBig().Cmp(funds) != 0 {
		t.Fatalf("sweep: target=%v recovery=%v", st.GetBalance(target), st.GetBalance(recovery))
	}
	t.Logf("authorization ignored (code and nonce unchanged); sweep moved %v wei, receipt status %d, gasUsed %d",
		funds, receipts[0][1].Status, receipts[0][1].GasUsed)
}
