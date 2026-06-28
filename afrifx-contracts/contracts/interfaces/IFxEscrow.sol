// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Arc StableFX FxEscrow interface
// Contract: 0x867650F5eAe8df91445971f14d89fd84F0C9a9f8
// Source: docs.arc.io/arc/references/contract-addresses

interface IFxEscrow {
    struct Order {
        address maker;        // liquidity provider
        address taker;        // user (filler)
        address inputToken;   // USDC: 0x3600000000000000000000000000000000000000
        address outputToken;  // EURC or other stablecoin
        uint256 inputAmount;
        uint256 outputAmount;
        uint256 deadline;     // unix timestamp
        bytes32 salt;         // unique per order
    }

    /// @notice Fill an order signed by the maker
    /// @dev Requires Permit2 approval from taker before calling
    function fill(Order calldata order, bytes calldata makerSig) external;

    /// @notice Cancel a pending order (maker only)
    function cancel(Order calldata order, bytes calldata makerSig) external;

    /// @notice Check if an order has been filled
    function filled(bytes32 orderHash) external view returns (bool);
}
