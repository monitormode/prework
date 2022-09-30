const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");
const { anyValue } = require("@nomicfoundation/hardhat-chai-matchers/withArgs");
const { expect } = require("chai");

describe("Escrow contract", function () {
  // We define a fixture to reuse the same setup in every test.
  // We use loadFixture to run this setup once, snapshot that state,
  // and reset Hardhat Network to that snapshot in every test.
  async function deployEscrowFixture() {
    const MyEscrow = await ethers.getContractFactory("MyEscrow");

    const [
      owner,
      sender1,
      sender2,
      sender3,
      sender4,
      sender5,
      sender6,
      receiver1,
      receiver2,
      receiver3,
      receiver4,
      receiver5,
      receiver6,
    ] = await ethers.getSigners();

    const myEscrow = await MyEscrow.deploy();

    await myEscrow.deployed();

    const senders = [sender1.address, sender2.address, sender3.address];

    const senders2 = [sender4.address, sender5.address, sender6.address];

    const receivers = [receiver1.address, receiver2.address, receiver3.address];

    const receivers2 = [
      receiver4.address,
      receiver5.address,
      receiver6.address,
    ];

    const totalSh1 = ["25", "30", "45"];

    const totalSh2 = ["10", "20", "70"];

    const totalShares = [totalSh1, totalSh2];

    //adding two contracts
    const esc = await myEscrow
      .connect(sender1)
      .createEscrow(senders, receivers, totalShares[0]);

    const esc2 = await myEscrow
      .connect(sender3)
      .createEscrow(senders2, receivers2, totalShares[1]);

    return {
      MyEscrow,
      myEscrow,
      owner,
      sender1,
      sender2,
      sender3,
      sender4,
      sender5,
      sender6,
      receiver1,
      receiver2,
      receiver3,
      receiver4,
      receiver5,
      receiver6,
      senders,
      receivers,
      totalShares,
      esc,
      esc2,
    };
  }

  describe("Deployment", function () {
    it("Should set the right owner", async function () {
      // We use loadFixture to setup our environment, and then assert that
      // things went well
      const { myEscrow, owner } = await loadFixture(deployEscrowFixture);

      // This test expects the owner variable stored in the contract to be
      // equal to our Signer's owner.
      expect(await myEscrow.goon()).to.equal(owner.address);
    });
  });

  describe("Escrow operations", function () {
    it("Should create a new escrow from sender 1", async function () {
      const { sender1, myEscrow, senders, receivers, totalShares } =
        await loadFixture(deployEscrowFixture);

      const esc = await myEscrow
        .connect(sender1)
        .createEscrow(senders, receivers, totalShares[0]);
      const my = await myEscrow.totalEscrows();

      console.log("Total escrows: " + my.toString());

      expect((await esc.value) == my.value);
    });

    it("Should create another escrow from sender 2", async function () {
      const { sender2, myEscrow, senders, receivers, totalShares } =
        await loadFixture(deployEscrowFixture);

      const esc = await myEscrow
        .connect(sender2)
        .createEscrow(senders, receivers, totalShares[1]);
      const my = await myEscrow.totalEscrows();

      console.log("Total escrows: " + my.toString());
      //as esc creates a new escrow id = 0, and "my" reads from totalEscrows that is 1 already
      expect((await esc.value) == my.value - 1);
    });

    it("Should check escrowList length after 2 escrows created ¬¬", async function () {
      const { myEscrow } = await loadFixture(deployEscrowFixture);

      const my = await myEscrow.totalEscrows();

      console.log(my.toString());
      // expect (my.toString().to.equal(2));
    });
  });
});
