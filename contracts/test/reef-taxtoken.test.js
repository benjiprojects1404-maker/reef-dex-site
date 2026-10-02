const { expect } = require("chai");
const { ethers } = require("hardhat");
const E = (n) => ethers.parseEther(String(n));

describe("Reef with a transfer-tax token (FINDING: no fee-on-transfer swap functions)", function () {
  it("buying a tax token works; selling it through the router always reverts", async () => {
    const [owner, user] = await ethers.getSigners();
    const wbdag = await (await ethers.getContractFactory("contracts/reef/WBDAG.sol:WBDAG")).deploy();
    const factory = await (await ethers.getContractFactory("ReefFactory")).deploy(owner.address);
    const reef = await (await ethers.getContractFactory("ReefRouter")).deploy(await factory.getAddress(), await wbdag.getAddress());
    const tax = await (await ethers.getContractFactory("HsToken")).deploy("Tax", "TAX");
    const R = await reef.getAddress(), T = await tax.getAddress(), W = await wbdag.getAddress();
    const deadline = (await ethers.provider.getBlock("latest")).timestamp + 3600;
    await tax.mint(owner.address, E(1_000_000)); await tax.approve(R, ethers.MaxUint256);
    await reef.addLiquidityBDAG(T, E(1_000_000), 0, 0, owner.address, deadline, { value: E(1000) });
    await tax.setFee(500); // 5% tax from now on

    // Buy: works, the buyer just receives 5% less than quoted
    await reef.connect(user).swapExactBDAGForTokens(0, [W, T], user.address, deadline, { value: E(1) });
    const got = await tax.balanceOf(user.address);
    expect(got).to.be.gt(0n);

    // Sell: the pair receives 5% less than the router told it to expect, so the K check fails
    await tax.connect(user).approve(R, ethers.MaxUint256);
    await expect(reef.connect(user).swapExactTokensForBDAG(got / 2n, 0, [T, W], user.address, deadline)).to.be.revertedWith("Reef: K");
  });
});
