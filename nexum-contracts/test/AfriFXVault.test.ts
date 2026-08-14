import { expect } from 'chai'
import { ethers } from 'hardhat'
import { loadFixture } from '@nomicfoundation/hardhat-toolbox/network-helpers'

describe('AfriFXVault', function () {
  async function deployFixture() {
    const [owner, user, treasury] = await ethers.getSigners()

    // Deploy a mock USDC (ERC-20 with 6 decimals) for testing
    const MockUSDC = await ethers.getContractFactory('MockUSDC')
    const usdc = await MockUSDC.deploy()

    const Vault = await ethers.getContractFactory('AfriFXVault')
    const vault = await Vault.deploy(await usdc.getAddress())

    // Mint 10,000 USDC to user (6 decimals)
    await usdc.mint(user.address, 10_000n * 10n ** 6n)

    return { vault, usdc, owner, user, treasury }
  }

  it('should deploy with correct USDC address', async () => {
    const { vault, usdc } = await loadFixture(deployFixture)
    expect(await vault.usdc()).to.equal(await usdc.getAddress())
  })

  it('should accept USDC conversion request', async () => {
    const { vault, usdc, user } = await loadFixture(deployFixture)
    const amount = 1000n * 10n ** 6n // 1,000 USDC

    await usdc.connect(user).approve(await vault.getAddress(), amount)
    await expect(vault.connect(user).requestConversion(amount, 'NGN'))
      .to.emit(vault, 'ConversionRequested')
      .withArgs(user.address, amount, 'NGN', await getTimestamp())

    expect(await vault.pendingConversion(user.address)).to.equal(amount)
  })

  it('should calculate spread correctly', async () => {
    const { vault } = await loadFixture(deployFixture)
    const amount = 1000n * 10n ** 6n // 1,000 USDC
    const spread = await vault.calcSpread(amount)
    // 0.5% of 1000 USDC = 5 USDC
    expect(spread).to.equal(5n * 10n ** 6n)
  })

  it('should allow owner to update spread', async () => {
    const { vault, owner } = await loadFixture(deployFixture)
    await vault.connect(owner).setSpreadBps(100) // 1%
    expect(await vault.spreadBps()).to.equal(100)
  })

  it('should reject spread above 2%', async () => {
    const { vault, owner } = await loadFixture(deployFixture)
    await expect(vault.connect(owner).setSpreadBps(201))
      .to.be.revertedWith('AfriFXVault: spread too high')
  })

  it('should allow owner to withdraw', async () => {
    const { vault, usdc, user, owner, treasury } = await loadFixture(deployFixture)
    const amount = 500n * 10n ** 6n

    await usdc.connect(user).approve(await vault.getAddress(), amount)
    await vault.connect(user).requestConversion(amount, 'NGN')
    await vault.connect(owner).withdraw(treasury.address, amount)

    expect(await usdc.balanceOf(treasury.address)).to.equal(amount)
  })
})

async function getTimestamp() {
  const block = await ethers.provider.getBlock('latest')
  return block!.timestamp
}
