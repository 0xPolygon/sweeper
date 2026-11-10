// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {SweeperRuntime} from "./SweeperRuntime.sol";

interface ISweeper {
    function sweep() external;
    function RECOVERY() external view returns (address);
}

/// RECOVERY stand-in that reverts on receipt.
contract RevertingRecovery {
    fallback() external payable {
        revert();
    }
}

/// RECOVERY stand-in that, on receipt, calls back into the sweeper with a chosen selector,
/// one 32-byte argument and a chosen value, up to two levels deep.
contract ReentrantRecovery {
    address public immutable target;
    bytes4 public sel;
    bytes32 public arg;
    uint256 public value;
    uint256 public depth;

    constructor(address t) {
        target = t;
    }

    function set(bytes4 s, bytes32 a, uint256 v) external {
        sel = s;
        arg = a;
        value = v;
    }

    fallback() external payable {
        if (depth >= 2) return;
        depth++;
        uint256 v = value > address(this).balance ? address(this).balance : value;
        (bool ok,) = target.call{value: v}(abi.encodeWithSelector(sel, arg));
        ok;
    }
}

/// Symbolic proofs over the exact runtime bytecode produced by script/runtime-code.sh.
contract SweeperProofs is Test {
    address constant RECOVERY = SweeperRuntime.RECOVERY;
    bytes4 constant SWEEP = ISweeper.sweep.selector;
    bytes4 constant GETTER = ISweeper.RECOVERY.selector;
    address sweeper;

    function setUp() public {
        bytes memory code = SweeperRuntime.CODE;
        // PUSH2 len, DUP1, PUSH1 10, PUSH0, CODECOPY, PUSH0, RETURN, then the runtime.
        bytes memory init = abi.encodePacked(hex"61", uint16(code.length), hex"80600a5f395ff3", code);
        address a;
        assembly {
            a := create(0, add(init, 0x20), mload(init))
        }
        require(a != address(0));
        sweeper = a;
    }

    /// The runtime never reads CALLER or ORIGIN (checked in prove_opcodeScan), so a fixed caller
    /// stands for every caller.
    address constant CALLER = address(0xCA11E5);

    /// The deployed code is byte-for-byte the runtime under proof.
    function prove_codeIsRuntime() public view {
        assert(keccak256(sweeper.code) == SweeperRuntime.CODEHASH);
        assert(ISweeper(sweeper).RECOVERY() == RECOVERY);
    }

    /// 5 + opcode facts. Linear decode of the runtime (PUSH data skipped, which is exactly how the
    /// EVM finds valid jump targets, so no other instruction can ever execute): no SSTORE, CREATE, CREATE2,
    /// CALLCODE, DELEGATECALL, STATICCALL, SELFDESTRUCT, CALLER or ORIGIN; exactly one CALL and one LOG1.
    function prove_opcodeScan() public view {
        bytes memory code = sweeper.code;
        uint256 calls;
        uint256 logs;
        for (uint256 i; i < code.length; i++) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assert(op != 0x55 && op != 0xf0 && op != 0xf5 && op != 0xf2 && op != 0xf4 && op != 0xfa && op != 0xff);
            assert(op != 0x32 && op != 0x33);
            if (op == 0xf1) calls++;
            if (op >= 0xa0 && op <= 0xa4) {
                assert(op == 0xa1);
                logs++;
            }
        }
        assert(calls == 1);
        assert(logs == 1);
    }

    // Calldata is modeled as a symbolic selector plus one symbolic word, and separately as every
    // length from 0 to 3 bytes.

    function _short(uint256 n, bytes3 b) internal pure returns (bytes memory d) {
        d = new bytes(n);
        for (uint256 k; k < n; k++) {
            d[k] = b[k];
        }
    }

    /// 1a. Any call carrying value reverts, whatever the calldata, and moves nothing.
    function prove_valueReverts(bytes4 sel, bytes32 word, bytes3 short, uint256 value, uint256 bal) public {
        vm.assume(value > 0 && value <= type(uint128).max && bal <= type(uint128).max);
        vm.deal(sweeper, bal);
        vm.deal(CALLER, value * 5);
        uint256 rb = RECOVERY.balance;
        vm.prank(CALLER);
        (bool ok,) = sweeper.call{value: value}(abi.encodePacked(sel, word));
        assert(!ok);
        for (uint256 n; n < 4; n++) {
            vm.prank(CALLER);
            (ok,) = sweeper.call{value: value}(_short(n, short));
            assert(!ok);
        }
        assert(sweeper.balance == bal);
        assert(CALLER.balance == value * 5);
        assert(RECOVERY.balance == rb);
    }

    /// 1b. Calldata whose selector is neither sweep() nor RECOVERY(), or shorter than a selector,
    /// reverts and moves nothing.
    function prove_unknownSelectorReverts(bytes4 sel, bytes32 word, bytes3 short, uint256 bal) public {
        vm.assume(sel != SWEEP && sel != GETTER);
        vm.assume(bal <= type(uint128).max);
        vm.deal(sweeper, bal);
        uint256 rb = RECOVERY.balance;
        vm.prank(CALLER);
        (bool ok,) = sweeper.call(abi.encodePacked(sel, word));
        assert(!ok);
        for (uint256 n; n < 4; n++) {
            vm.prank(CALLER);
            (ok,) = sweeper.call(_short(n, short));
            assert(!ok);
        }
        assert(sweeper.balance == bal);
        assert(RECOVERY.balance == rb);
    }

    /// 1c. RECOVERY() is read-only: it returns the baked address and moves nothing.
    function prove_getterMovesNothing(bytes32 word, uint256 bal) public {
        vm.assume(bal <= type(uint128).max);
        vm.deal(sweeper, bal);
        uint256 rb = RECOVERY.balance;
        vm.prank(CALLER);
        (bool ok, bytes memory ret) = sweeper.call(abi.encodePacked(GETTER, word));
        assert(ok);
        assert(abi.decode(ret, (address)) == RECOVERY);
        assert(sweeper.balance == bal);
        assert(RECOVERY.balance == rb);
    }

    /// 2 + 3. sweep(), with or without trailing calldata, and any balance: the whole balance goes to
    /// the baked RECOVERY and it succeeds when RECOVERY accepts value. Since the sweeper's loss
    /// equals RECOVERY's gain, no other account receives anything. On zero balance nothing moves.
    function prove_sweepPaysRecovery(bool withWord, bytes32 word, uint256 bal, uint256 rb) public {
        vm.assume(bal <= type(uint128).max && rb <= type(uint128).max);
        vm.deal(sweeper, bal);
        vm.deal(RECOVERY, rb);
        uint256 cb = CALLER.balance;
        bytes memory data = withWord ? abi.encodePacked(SWEEP, word) : abi.encodePacked(SWEEP);
        vm.prank(CALLER);
        (bool ok,) = sweeper.call(data);
        assert(ok);
        assert(sweeper.balance == 0);
        assert(RECOVERY.balance == rb + bal);
        assert(CALLER.balance == cb);
    }

    /// 2. If the transfer to RECOVERY fails, sweep() reverts and the balance stays whole.
    function prove_failedTransferReverts(uint256 bal) public {
        vm.assume(bal > 0 && bal <= type(uint128).max);
        vm.etch(RECOVERY, address(new RevertingRecovery()).code);
        vm.deal(sweeper, bal);
        uint256 rb = RECOVERY.balance;
        vm.prank(CALLER);
        (bool ok,) = sweeper.call(abi.encodeWithSelector(SWEEP));
        assert(!ok);
        assert(sweeper.balance == bal);
        assert(RECOVERY.balance == rb);
    }

    /// 4. A RECOVERY that re-enters (any selector, any 32-byte argument, any value) gets exactly
    /// the balance and no more.
    function prove_reentrancyBounded(bytes4 sel, bytes32 arg, uint256 v, uint256 bal) public {
        vm.assume(bal <= type(uint128).max);
        vm.etch(RECOVERY, address(new ReentrantRecovery(sweeper)).code);
        ReentrantRecovery(payable(RECOVERY)).set(sel, arg, v);
        vm.deal(sweeper, bal);
        vm.deal(RECOVERY, 0);
        vm.prank(CALLER);
        (bool ok,) = sweeper.call(abi.encodeWithSelector(SWEEP));
        assert(ok);
        assert(sweeper.balance == 0);
        assert(RECOVERY.balance == bal);
    }
}
