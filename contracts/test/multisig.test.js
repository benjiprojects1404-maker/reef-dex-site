const { expect } = require("chai");
const { ethers } = require("hardhat");

// The live ReefAdminMultisig (0x4E24...60fc) owns NodalRouter and the Handshake escrow and holds
// Reef's feeToSetter. These tests cover the live contract and the proposed V2 fix side by side.
for (const name of ["ReefAdminMultisig", "ReefAdminMultisigV2"]) {
  describe(name, function () {
    let a, b, c, outsider, ms, MS, factory;

    beforeEach(async () => {
      [a, b, c, outsider] = await ethers.getSigners();
      ms = await (await ethers.getContractFactory(name)).deploy([a.address, b.address, c.address], 2);
      MS = await ms.getAddress();
      factory = await (await ethers.getContractFactory("ReefFactory")).deploy(MS);
    });

    const setFeeTo = (to) => factory.interface.encodeFunctionData("setFeeTo", [to]);
    const self = (fn, args) => ms.interface.encodeFunctionData(fn, args);

    it("needs the threshold before anything executes, then anyone can execute", async () => {
      await ms.connect(a).submitTransaction(await factory.getAddress(), 0, setFeeTo(outsider.address));
      await expect(ms.connect(outsider).executeTransaction(0)).to.be.revertedWith("not enough confirmations");
      await ms.connect(b).confirmTransaction(0);
      await ms.connect(outsider).executeTransaction(0);
      expect(await factory.feeTo()).to.equal(outsider.address);
      await expect(ms.executeTransaction(0)).to.be.revertedWith("already executed");
    });

    it("outsiders can't submit or confirm, and owners can't confirm twice", async () => {
      await expect(ms.connect(outsider).submitTransaction(MS, 0, "0x")).to.be.revertedWith("not an owner");
      await ms.connect(a).submitTransaction(MS, 0, "0x");
      await expect(ms.connect(outsider).confirmTransaction(0)).to.be.revertedWith("not an owner");
      await expect(ms.connect(a).confirmTransaction(0)).to.be.revertedWith("already confirmed");
    });

    it("owner changes only happen through a confirmed transaction to itself", async () => {
      await expect(ms.connect(a).addOwner(outsider.address)).to.be.revertedWith("only via multisig confirmation");
      await expect(ms.connect(a).changeRequirement(1)).to.be.revertedWith("only via multisig confirmation");
    });

    it("a failed inner call is not marked executed and can be retried", async () => {
      // removeOwner of a non-owner fails inside; the multisig itself doesn't revert
      await ms.connect(a).submitTransaction(MS, 0, self("removeOwner", [outsider.address]));
      await ms.connect(b).confirmTransaction(0);
      await expect(ms.executeTransaction(0)).to.emit(ms, "ExecutionFailed");
      expect((await ms.transactions(0)).executed).to.equal(false);
    });

    it("a removed owner's earlier approval: " + (name === "ReefAdminMultisig" ? "FINDING M-1, still counts" : "no longer counts (fixed)"), async () => {
      // c proposes something (1 approval, from c)
      await ms.connect(c).submitTransaction(await factory.getAddress(), 0, setFeeTo(c.address));
      // a and b remove c, e.g. because c's key was lost or stolen
      await ms.connect(a).submitTransaction(MS, 0, self("removeOwner", [c.address]));
      await ms.connect(b).confirmTransaction(1);
      await ms.executeTransaction(1);
      expect(await ms.isOwner(c.address)).to.equal(false);
      // now only ONE current owner (a) approves c's old proposal
      await ms.connect(a).confirmTransaction(0);
      if (name === "ReefAdminMultisig") {
        await ms.executeTransaction(0); // goes through with one current owner
        expect(await factory.feeTo()).to.equal(c.address);
      } else {
        await expect(ms.executeTransaction(0)).to.be.revertedWith("not enough confirmations");
        await ms.connect(b).confirmTransaction(0); // a second current owner is still required
        await ms.executeTransaction(0);
        expect(await factory.feeTo()).to.equal(c.address);
      }
    });
  });
}
