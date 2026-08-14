// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IFxEscrow.sol";
import "./interfaces/IUSDC.sol";

/**
 * @title AfriFXExchange
 * @notice Wraps Arc's native StableFX FxEscrow for USDC ↔ EURC swaps.
 *         Used in Phase 2+ when we add EURC and cross-stablecoin FX.
 *
 * Arc Testnet addresses:
 *   FxEscrow: 0x867650F5eAe8df91445971f14d89fd84F0C9a9f8
 *   Permit2:  0x000000000022D473030F116dDEE9F6B43aC78BA3
 *   USDC:     0x3600000000000000000000000000000000000000
 *   EURC:     0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a
 *
 * Flow:
 *   1. Taker approves Permit2 for USDC
 *   2. Market maker creates & signs an Order off-chain
 *   3. AfriFX backend passes order + sig to executeSwap()
 *   4. FxEscrow settles atomically on Arc (<1s)
 */
contract AfriFXExchange is Ownable, ReentrancyGuard {

    IFxEscrow public immutable fxEscrow;
    IUSDC     public immutable usdc;
    address   public immutable eurc;

    event SwapExecuted(
        address indexed taker,
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 outputAmount
    );

    constructor() Ownable(msg.sender) {
        // Arc Testnet — all addresses from docs.arc.io
        fxEscrow = IFxEscrow(0x867650F5eAe8df91445971f14d89fd84F0C9a9f8);
        usdc     = IUSDC(0x3600000000000000000000000000000000000000);
        eurc     =       0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a;
    }

    /**
     * @notice Execute a StableFX order (USDC ↔ EURC)
     * @dev Taker must have signed a Permit2 approval before calling this.
     *      Arc settles the swap atomically in under 1 second.
     * @param order    The FxEscrow.Order struct from the market maker
     * @param makerSig EIP-712 signature from the maker
     */
    function executeSwap(
        IFxEscrow.Order calldata order,
        bytes calldata makerSig
    ) external nonReentrant {
        require(order.taker == msg.sender, "AfriFXExchange: not the taker");
        require(block.timestamp < order.deadline, "AfriFXExchange: order expired");

        fxEscrow.fill(order, makerSig);

        emit SwapExecuted(
            msg.sender,
            order.inputToken,
            order.outputToken,
            order.inputAmount,
            order.outputAmount
        );
    }

    /**
     * @notice Check if an order has already been filled on FxEscrow
     */
    function isOrderFilled(bytes32 orderHash) external view returns (bool) {
        return fxEscrow.filled(orderHash);
    }
}
