// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Sweeper} from "../src/Sweeper.sol";

contract MockToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

/// Recovery that re-enters sweep() on every receipt and counts what it got.
contract ReentrantRecovery {
    Sweeper public target;
    uint256 public received;
    uint256 public calls;

    function setTarget(Sweeper t) external {
        target = t;
    }

    receive() external payable {
        received += msg.value;
        calls++;
        if (calls < 5) target.sweep();
    }
}

contract RejectingRecovery {
    receive() external payable {
        revert("no");
    }
}

contract SweeperTest is Test {
    event Swept(uint256 amount);

    address constant RECOVERY = address(0xBEEF);
    Sweeper sweeper;

    function setUp() public {
        sweeper = new Sweeper(RECOVERY);
    }

    /// Installs the runtime code of a Sweeper(recovery) at `at`.
    function _install(address recovery, address at) internal returns (Sweeper) {
        bytes memory runtime = address(new Sweeper(recovery)).code;
        vm.etch(at, runtime);
        return Sweeper(payable(at));
    }

    function testFuzz_SweepSendsFullBalanceFromAnyCaller(address caller, uint96 amount) public {
        vm.assume(amount > 0);
        vm.assume(caller != address(sweeper) && caller != RECOVERY);
        vm.deal(address(sweeper), amount);

        vm.expectEmit(address(sweeper));
        emit Swept(amount);
        vm.prank(caller);
        sweeper.sweep();

        assertEq(address(sweeper).balance, 0);
        assertEq(RECOVERY.balance, amount);
    }

    function test_CannotRedirect() public {
        vm.deal(address(sweeper), 10 ether);
        address other = makeAddr("other");

        vm.prank(other);
        (bool ok,) = address(sweeper).call(abi.encodeWithSignature("sweep()", other));
        assertTrue(ok);
        assertEq(RECOVERY.balance, 10 ether);
        assertEq(other.balance, 0);

        vm.deal(address(sweeper), 1 ether);
        bytes[4] memory probes = [
            abi.encodeWithSignature("sweep(address)", other),
            abi.encodeWithSignature("transfer(address,uint256)", other, 1 ether),
            abi.encodeWithSignature("setRecovery(address)", other),
            abi.encodeWithSignature("execute(address,uint256,bytes)", other, 1 ether, "")
        ];
        for (uint256 i; i < probes.length; i++) {
            vm.prank(other);
            (ok,) = address(sweeper).call(probes[i]);
            assertFalse(ok);
        }
        assertEq(sweeper.RECOVERY(), RECOVERY);
        assertEq(address(sweeper).balance, 1 ether);
    }

    function test_Erc20Untouched() public {
        MockToken token = new MockToken();
        token.mint(address(sweeper), 6_000_000e6);
        vm.deal(address(sweeper), 1 ether);

        sweeper.sweep();

        assertEq(token.balanceOf(address(sweeper)), 6_000_000e6);
        assertEq(token.balanceOf(RECOVERY), 0);
        assertEq(RECOVERY.balance, 1 ether);

        (bool ok,) = address(sweeper).call(abi.encodeWithSignature("approve(address,uint256)", RECOVERY, 1));
        assertFalse(ok);
        (ok,) = address(sweeper)
            .call(abi.encodeWithSignature("transferToken(address,address,uint256)", address(token), RECOVERY, 1));
        assertFalse(ok);
    }

    function test_RuntimeCodeSizeAndOpcodes() public view {
        bytes memory code = address(sweeper).code;
        assertGt(code.length, 0);
        assertLt(code.length, 400);

        // Opcode scan, skipping PUSH data.
        uint256 callCount;
        for (uint256 i; i < code.length; i++) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0x55, "SSTORE");
            assertTrue(op != 0xf0 && op != 0xf5, "CREATE");
            assertTrue(op != 0xf2, "CALLCODE");
            assertTrue(op != 0xf4, "DELEGATECALL");
            assertTrue(op != 0xff, "SELFDESTRUCT");
            if (op == 0xf1) callCount++;
        }
        assertEq(callCount, 1);
    }

    function test_RuntimeEmbedsRecovery() public {
        bytes memory a = address(new Sweeper(address(0xA))).code;
        bytes memory b = address(new Sweeper(address(0xB))).code;
        assertEq(a.length, b.length);
        assertTrue(keccak256(a) != keccak256(b));
        assertEq(keccak256(address(new Sweeper(address(0xA))).code), keccak256(a));
    }

    function test_EtchedRuntimeBehavesIdentically() public {
        address target = makeAddr("target");
        vm.deal(target, 123 ether);
        vm.setNonce(target, 42);

        Sweeper installed = _install(RECOVERY, target);
        assertEq(target.code, address(sweeper).code);
        assertEq(installed.RECOVERY(), RECOVERY);
        assertEq(vm.getNonce(target), 42);

        vm.prank(makeAddr("anyone"));
        installed.sweep();

        assertEq(target.balance, 0);
        assertEq(RECOVERY.balance, 123 ether);
    }

    function test_ReentrantRecoveryGetsOnlyTheBalance() public {
        ReentrantRecovery rec = new ReentrantRecovery();
        Sweeper s = _install(address(rec), makeAddr("target"));
        rec.setTarget(s);
        vm.deal(address(s), 7 ether);

        s.sweep();

        assertEq(rec.received(), 7 ether);
        assertEq(rec.calls(), 1);
        assertEq(address(rec).balance, 7 ether);
        assertEq(address(s).balance, 0);
    }

    function test_ZeroBalanceIsNoop() public {
        Sweeper s = _install(address(new RejectingRecovery()), makeAddr("target"));
        vm.recordLogs();
        s.sweep();
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(address(s).balance, 0);
    }

    function test_RejectingRecoveryReverts() public {
        Sweeper s = _install(address(new RejectingRecovery()), makeAddr("target"));
        vm.deal(address(s), 1 ether);
        vm.expectRevert(Sweeper.SweepFailed.selector);
        s.sweep();
        assertEq(address(s).balance, 1 ether);
    }

    function test_RejectsNativeValue() public {
        address payer = makeAddr("payer");
        vm.deal(payer, 3 ether);

        vm.prank(payer);
        (bool ok,) = address(sweeper).call{value: 1 ether}("");
        assertFalse(ok, "plain call");
        vm.prank(payer);
        (ok,) = address(sweeper).call{value: 1 ether, gas: 2300}("");
        assertFalse(ok, "2300 stipend");
        vm.prank(payer);
        assertFalse(payable(address(sweeper)).send(1 ether), "send");
        vm.prank(payer);
        (ok,) = address(sweeper).call{value: 1 ether}(abi.encodeCall(Sweeper.sweep, ()));
        assertFalse(ok, "value with sweep()");

        assertEq(address(sweeper).balance, 0);
        assertEq(payer.balance, 3 ether);
    }

    function test_ConstructorRejectsZeroRecovery() public {
        vm.expectRevert(Sweeper.ZeroRecovery.selector);
        new Sweeper(address(0));
    }
}
