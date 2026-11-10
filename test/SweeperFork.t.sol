// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {Sweeper} from "../src/Sweeper.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function allowance(address, address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

interface IMRC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 value) external payable returns (bool);
    function owner() external view returns (address);
    function token() external view returns (address);
}

interface IChildChain {
    function tokens(address rootToken) external view returns (address);
    function onStateReceive(uint256 id, bytes calldata data) external;
}

interface IStateReceiver {
    function lastStateId() external view returns (uint256);
    function commitState(uint256 syncTime, bytes calldata recordBytes) external returns (bool);
}

interface IUSDT0 {
    function isBlocked(address) external view returns (bool);
    function nonces(address) external view returns (uint256);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

/// Delegatecall proxy whose implementation writes storage on receive.
contract SafeLikeImpl {
    uint256 public received;

    receive() external payable {
        received += msg.value;
    }
}

contract SafeLikeProxy {
    address immutable impl;

    constructor(address _impl) {
        impl = _impl;
    }

    fallback() external payable {
        address i = impl;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), i, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(ok) { revert(0, returndatasize()) }
            return(0, returndatasize())
        }
    }
}

contract Rejecting {
    receive() external payable {
        revert("no");
    }
}

/// Re-enters sweep() on every receipt.
contract Reentrant {
    Sweeper public target;
    uint256 public received;
    uint256 public calls;

    function setTarget(Sweeper t) external {
        target = t;
    }

    receive() external payable {
        received += msg.value;
        calls++;
        if (calls < 10) target.sweep();
    }
}

/// Polygon PoS fork tests; skipped unless POLYGON_RPC_URL is set. FORK_BLOCK pins the block.
contract SweeperForkTest is Test {
    address constant ADDR_1 = 0xe4C4C39C1733e1C7c06B79f97ED442B68Df41EC6;
    address constant ADDR_2 = 0x5392587814Ce8c6af6789764f88e5e9AB0b9962C;
    address constant ADDR_3 = 0xc91ee0574a14446DE200923729c349B9CAE19b60;
    address constant ADDR_4 = 0x3f7019221a925537DC20767C38e80A7127fb1Ffa;
    address constant ADDR_5 = 0x5227f603C1eE34CE3C06eFe6477003BDfCCB2f8c;

    address constant RECOVERY_A = 0x3dcE0a29139A851Da1dFCa56Af8e8a6440b4D952;
    address RECOVERY_B;

    IMRC20 constant POL = IMRC20(0x0000000000000000000000000000000000001010);
    address constant STATE_RECEIVER = 0x0000000000000000000000000000000000001001;
    address constant SYSTEM_ADDRESS = 0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE;

    event StateCommitted(uint256 indexed stateId, bool success);
    address constant USDT0 = 0xc2132D05D31c914a87C6611C10748AEb04B58e8F;
    address constant USDC = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;
    address constant USDC_E = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;
    address constant WPOL = 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270;
    address constant WETH = 0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619;
    address constant ONEINCH = 0x111111125421cA6dc452d289314280a0f8842A65;

    address[] targets;
    address[] tokens;
    bool forked;

    function setUp() public {
        string memory rpc = vm.envOr("POLYGON_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        uint256 blockNumber = vm.envOr("FORK_BLOCK", uint256(0));
        if (blockNumber == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, blockNumber);
        forked = true;

        RECOVERY_B = makeAddr("recovery-b");
        targets = [ADDR_1, ADDR_2, ADDR_3, ADDR_4, ADDR_5];
        tokens = [
            USDT0,
            USDC,
            USDC_E,
            WPOL,
            WETH,
            0x3838a62444FDe3C846AbDF9f25D47db5451417E5,
            0x3fddEcB4f1e2dC8a34872C84b9388eE2042B7EFa,
            0xe9e9F12f66223ba61E2fEdac6766596e73ffA22b,
            0x91B0232D85A33F0A2586b93980d7C0457d151b4e,
            0xDDe776077A094989A98EC3473306aac1E857bb09,
            0xC5C817d007c0d1aAAB4704aD48A8C07b09A61aD5,
            0xfcA466F2fA8E667a517C9C6cfa99Cf985be5d9B1
        ];
    }

    modifier onlyFork() {
        if (!forked) vm.skip(true);
        _;
    }

    function _recoveryOf(address a) internal view returns (address) {
        return a == ADDR_5 ? RECOVERY_B : RECOVERY_A;
    }

    function _runtime(address recovery) internal returns (bytes memory) {
        return address(new Sweeper(recovery)).code;
    }

    /// Replaces code, keeps balance, nonce and storage.
    function _install(address at, address recovery) internal returns (Sweeper) {
        vm.etch(at, _runtime(recovery));
        return Sweeper(payable(at));
    }

    function _tokenBalance(address token, address who) internal view returns (uint256 bal, bool ok) {
        bytes memory ret;
        (ok, ret) = token.staticcall(abi.encodeCall(IERC20.balanceOf, (who)));
        ok = ok && ret.length >= 32;
        if (ok) bal = abi.decode(ret, (uint256));
    }

    function _snapshotTokens(address who) internal view returns (uint256[] memory bals) {
        bals = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; i++) {
            (bals[i],) = _tokenBalance(tokens[i], who);
        }
    }

    function _assertTokensUnchanged(address who, uint256[] memory before) internal view {
        uint256[] memory nowBals = _snapshotTokens(who);
        for (uint256 i; i < tokens.length; i++) {
            assertEq(nowBals[i], before[i], "token balance moved");
        }
    }

    function test_fork_PreState() public onlyFork {
        console2.log("fork block", block.number);
        for (uint256 i; i < targets.length; i++) {
            address a = targets[i];
            console2.log("address", a);
            console2.log("  native POL wei", a.balance);
            console2.log("  0x1010 balanceOf", POL.balanceOf(a));
            console2.log("  nonce", vm.getNonce(a));
            console2.log("  code length", a.code.length);
            (uint256 usdt0,) = _tokenBalance(USDT0, a);
            console2.log("  USDT0", usdt0);
            assertEq(POL.balanceOf(a), a.balance, "0x1010 mirrors native balance");
            assertEq(a.code.length, 0, "no existing code / 7702 delegation");
        }
        console2.log("USDT0 isBlocked(ADDR_5)", IUSDT0(USDT0).isBlocked(ADDR_5));
        console2.log("USDC allowance ADDR_3 -> ONEINCH", IERC20(USDC).allowance(ADDR_3, ONEINCH));
        console2.log("USDC balance ADDR_3", IERC20(USDC).balanceOf(ADDR_3));
        console2.log("RECOVERY_A code length", RECOVERY_A.code.length);
    }

    function test_fork_SweepAllRealAddresses() public onlyFork {
        address caller = makeAddr("random-caller");
        vm.deal(caller, 1 ether);
        for (uint256 i; i < targets.length; i++) {
            address a = targets[i];
            address rec = _recoveryOf(a);
            uint256 bal = a.balance;
            uint64 nonce = vm.getNonce(a);
            uint256 recBefore = rec.balance;
            uint256[] memory aTokens = _snapshotTokens(a);
            uint256[] memory recTokens = _snapshotTokens(rec);

            Sweeper s = _install(a, rec);
            assertEq(a.balance, bal, "install keeps balance");
            assertEq(vm.getNonce(a), nonce, "install keeps nonce");

            vm.prank(caller);
            uint256 g = gasleft();
            s.sweep();
            g -= gasleft();

            console2.log("swept", a);
            console2.log("  amount wei", bal);
            console2.log("  sweep() gas (call frame)", g);
            assertEq(a.balance, 0);
            assertEq(POL.balanceOf(a), 0);
            assertEq(rec.balance - recBefore, bal, "full balance to RECOVERY");
            assertEq(caller.balance, 1 ether, "caller gains nothing");
            _assertTokensUnchanged(a, aTokens);
            _assertTokensUnchanged(rec, recTokens);
        }
        assertTrue(IUSDT0(USDT0).isBlocked(ADDR_5), "USDT0 state unchanged");
    }

    function test_fork_RepeatedSweepsManyCallers() public onlyFork {
        Sweeper s = _install(ADDR_5, RECOVERY_B);
        uint256 bal = ADDR_5.balance;
        for (uint256 i; i < 25; i++) {
            vm.prank(address(uint160(uint256(keccak256(abi.encode("caller", i))))));
            s.sweep();
        }
        assertEq(ADDR_5.balance, 0);
        assertEq(RECOVERY_B.balance, bal);

        vm.recordLogs();
        s.sweep();
        assertEq(vm.getRecordedLogs().length, 0, "zero balance: no event");
    }

    function test_fork_IncomingValueReverts() public onlyFork {
        uint256 bal = ADDR_1.balance;
        _install(ADDR_1, RECOVERY_A);
        uint256 recBefore = RECOVERY_A.balance;
        uint256 polSupplyHolder = address(POL).balance;

        address payer = makeAddr("payer");
        vm.deal(payer, 3 ether);

        vm.prank(payer);
        (bool ok,) = ADDR_1.call{value: 1 ether}("");
        assertFalse(ok, "plain transfer");

        vm.prank(payer);
        (ok,) = ADDR_1.call{value: 1 ether, gas: 2300}("");
        assertFalse(ok, "2300 stipend");

        vm.prank(payer);
        vm.expectRevert();
        POL.transfer{value: 1 ether}(ADDR_1, 1 ether);

        address childChain = POL.owner();
        address rootToken = POL.token();
        assertEq(IChildChain(childChain).tokens(rootToken), address(POL), "ChildChain maps root POL to 0x1010");
        bytes memory deposit = abi.encode(ADDR_1, rootToken, uint256(1 ether), uint256(keccak256("unused-deposit-id")));

        // Direct 0x1001 -> ChildChain.onStateReceive -> MRC20.deposit reverts.
        vm.prank(STATE_RECEIVER);
        vm.expectRevert();
        IChildChain(childChain).onStateReceive(1, deposit);

        // Full state sync through StateReceiver.commitState is recorded as failed.
        IStateReceiver sr = IStateReceiver(STATE_RECEIVER);
        uint256 id = sr.lastStateId() + 1;
        bytes memory record =
            _rlpList(abi.encodePacked(_rlpUint(id), _rlpBytes(abi.encodePacked(childChain)), _rlpBytes(deposit)));
        vm.expectEmit(STATE_RECEIVER);
        emit StateCommitted(id, false);
        vm.prank(SYSTEM_ADDRESS);
        assertFalse(sr.commitState(block.timestamp, record), "state sync");
        assertEq(sr.lastStateId(), id);

        assertEq(ADDR_1.balance, bal, "nothing arrived");
        assertEq(payer.balance, 3 ether, "payer kept its value");
        assertEq(address(POL).balance, polSupplyHolder, "0x1010 balance unchanged");

        _install(ADDR_1, RECOVERY_A).sweep();
        assertEq(RECOVERY_A.balance - recBefore, bal);
    }

    function _rlpBytes(bytes memory b) internal pure returns (bytes memory) {
        if (b.length == 1 && uint8(b[0]) < 0x80) return b;
        return abi.encodePacked(_rlpLen(b.length, 0x80), b);
    }

    function _rlpUint(uint256 x) internal pure returns (bytes memory) {
        return x == 0 ? bytes(hex"80") : _rlpBytes(_minBytes(x));
    }

    function _rlpList(bytes memory payload) internal pure returns (bytes memory) {
        return abi.encodePacked(_rlpLen(payload.length, 0xc0), payload);
    }

    function _rlpLen(uint256 len, uint8 offset) internal pure returns (bytes memory) {
        if (len <= 55) return abi.encodePacked(uint8(offset + len));
        bytes memory l = _minBytes(len);
        return abi.encodePacked(uint8(offset + 55 + l.length), l);
    }

    function _minBytes(uint256 x) internal pure returns (bytes memory out) {
        uint256 n;
        for (uint256 y = x; y != 0; y >>= 8) {
            n++;
        }
        out = new bytes(n);
        for (uint256 k; k < n; k++) {
            out[n - 1 - k] = bytes1(uint8(x >> (8 * k)));
        }
    }

    function test_fork_RecoveryRealSafe() public onlyFork {
        uint256 bal = ADDR_5.balance;
        uint256 before = RECOVERY_A.balance;
        _install(ADDR_5, RECOVERY_A).sweep();
        assertEq(RECOVERY_A.balance - before, bal);
    }

    function test_fork_RecoverySafeLikeProxy() public onlyFork {
        SafeLikeImpl impl = new SafeLikeImpl();
        address proxy = address(new SafeLikeProxy(address(impl)));
        uint256 bal = ADDR_5.balance;
        _install(ADDR_5, proxy).sweep();
        assertEq(proxy.balance, bal);
        assertEq(SafeLikeImpl(payable(proxy)).received(), bal);
    }

    function test_fork_RecoveryRejectingKeepsFunds() public onlyFork {
        address rej = address(new Rejecting());
        uint256 bal = ADDR_5.balance;
        Sweeper s = _install(ADDR_5, rej);
        vm.expectRevert(Sweeper.SweepFailed.selector);
        s.sweep();
        assertEq(ADDR_5.balance, bal, "funds stay put");
    }

    function test_fork_RecoveryReentrantGetsOnlyBalance() public onlyFork {
        Reentrant rec = new Reentrant();
        Sweeper s = _install(ADDR_5, address(rec));
        rec.setTarget(s);
        uint256 bal = ADDR_5.balance;
        s.sweep();
        assertEq(rec.received(), bal);
        assertEq(rec.calls(), 1);
        assertEq(ADDR_5.balance, 0);
    }

    function test_fork_ReplacesExisting7702Delegation() public onlyFork {
        address impl = address(new SafeLikeImpl());
        vm.etch(ADDR_2, abi.encodePacked(hex"ef0100", impl));
        assertEq(ADDR_2.code.length, 23);

        uint256 bal = ADDR_2.balance;
        _install(ADDR_2, RECOVERY_A);
        bytes memory code = ADDR_2.code;
        assertTrue(code.length > 23 && !(code[0] == 0xef && code[1] == 0x01 && code[2] == 0x00), "no delegation");
        uint256 before = RECOVERY_A.balance;
        Sweeper(payable(ADDR_2)).sweep();
        assertEq(RECOVERY_A.balance - before, bal);
    }

    function test_fork_ApprovalsCannotTouchPol() public onlyFork {
        address spender = makeAddr("spender");
        Sweeper s = _install(ADDR_5, RECOVERY_B);
        uint256 bal = ADDR_5.balance;

        (bool ok,) = address(POL).call(abi.encodeCall(IERC20.approve, (spender, type(uint256).max)));
        assertFalse(ok, "0x1010 approve");
        (ok,) = address(POL).call(abi.encodeCall(IERC20.transferFrom, (ADDR_5, spender, 1)));
        assertFalse(ok, "0x1010 transferFrom");
        (ok,) = address(POL)
            .call(
                abi.encodeWithSignature(
                    "transferWithSig(bytes,uint256,bytes32,uint256,address)", "", 1, bytes32(0), 1, spender
                )
            );
        assertFalse(ok, "0x1010 transferWithSig");

        // Allowance as a permit would set it.
        assertTrue(IUSDT0(USDT0).DOMAIN_SEPARATOR() != bytes32(0), "USDT0 supports permit");
        vm.prank(ADDR_5);
        IERC20(USDT0).approve(spender, type(uint256).max);
        uint256 usdt = IERC20(USDT0).balanceOf(ADDR_5);
        vm.prank(spender);
        vm.expectRevert();
        IERC20(USDT0).transferFrom(ADDR_5, spender, usdt);
        assertEq(IERC20(USDT0).balanceOf(ADDR_5), usdt);

        assertEq(IERC20(WPOL).balanceOf(ADDR_5), 0);

        assertEq(ADDR_5.balance, bal, "POL untouched by any of the above");
        s.sweep();
        assertEq(RECOVERY_B.balance, bal);
    }
}
