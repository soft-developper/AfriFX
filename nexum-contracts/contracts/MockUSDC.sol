// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Simple ERC-20 mock that mimics Arc USDC (6 decimals)
// Used ONLY in local Hardhat tests — never deployed to Arc Testnet

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
