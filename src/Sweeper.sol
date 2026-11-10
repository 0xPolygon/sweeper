// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Lets anyone send this address's native balance to RECOVERY.
contract Sweeper {
    address public immutable RECOVERY;

    event Swept(uint256 amount);

    error ZeroRecovery();
    error SweepFailed();

    constructor(address recovery) {
        if (recovery == address(0)) revert ZeroRecovery();
        RECOVERY = recovery;
    }

    /// @notice Sends the full native balance to RECOVERY. No-op on zero balance.
    function sweep() external {
        uint256 amount = address(this).balance;
        if (amount == 0) return;
        (bool ok,) = RECOVERY.call{value: amount}("");
        if (!ok) revert SweepFailed();
        emit Swept(amount);
    }
}
