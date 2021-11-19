import { expect } from "chai";
import { ethers } from "hardhat";
import { Contract } from "ethers";
import { parseUnits } from "ethers/lib/utils";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { DefaultEnv, ExactlyEnv } from "./exactlyUtils";

describe("Smart Pool", function () {
  let exactlyEnv: DefaultEnv;

  let underlyingTokenDAI: Contract;
  let fixedLenderDAI: Contract;
  let eDAI: Contract;
  let underlyingTokenWBTC: Contract;
  let fixedLenderWBTC: Contract;
  let eWBTC: Contract;
  let bob: SignerWithAddress;
  let john: SignerWithAddress;

  const mockedTokens = new Map([
    [
      "DAI",
      {
        decimals: 18,
        collateralRate: parseUnits("0.8"),
        usdPrice: parseUnits("1"),
      },
    ],
    [
      "WBTC",
      {
        decimals: 8,
        collateralRate: parseUnits("0.6", 18),
        usdPrice: parseUnits("60000"),
      },
    ],
  ]);

  beforeEach(async () => {
    [bob, john] = await ethers.getSigners();

    exactlyEnv = await ExactlyEnv.create(mockedTokens);
    eDAI = exactlyEnv.getEToken("DAI");
    underlyingTokenDAI = exactlyEnv.getUnderlying("DAI");
    fixedLenderDAI = exactlyEnv.getFixedLender("DAI");
    await eDAI.setFixedLender(fixedLenderDAI.address);

    eWBTC = exactlyEnv.getEToken("WBTC");
    underlyingTokenWBTC = exactlyEnv.getUnderlying("WBTC");
    fixedLenderWBTC = exactlyEnv.getFixedLender("WBTC");
    await eWBTC.setFixedLender(fixedLenderWBTC.address);

    // From Owner to User
    await underlyingTokenDAI.transfer(bob.address, parseUnits("2000"));
    await underlyingTokenWBTC.transfer(bob.address, parseUnits("1", 8));
    await underlyingTokenDAI.transfer(john.address, parseUnits("2000"));
  });

  describe("GIVEN bob and jhon have 2000DAI in balance, AND deposit 1000DAI each", () => {
    beforeEach(async () => {
      let bobBalance = parseUnits("2000");
      let johnBalance = parseUnits("2000");
      await underlyingTokenDAI.approve(fixedLenderDAI.address, bobBalance);
      await underlyingTokenDAI
        .connect(john)
        .approve(fixedLenderDAI.address, johnBalance);

      await fixedLenderDAI.connect(john).depositToSmartPool(parseUnits("1000"));
      await fixedLenderDAI.depositToSmartPool(parseUnits("1000"));
    });
    it("THEN balance of DAI in contract is 2000", async () => {
      let balanceOfAssetInContract = await underlyingTokenDAI.balanceOf(
        fixedLenderDAI.address
      );

      expect(balanceOfAssetInContract).to.equal(parseUnits("2000"));
    });
    it("THEN balance of eDAI in BOB's address is 1000", async () => {
      let balanceOfETokenInUserAddress = await eDAI.balanceOf(bob.address);

      expect(balanceOfETokenInUserAddress).to.equal(parseUnits("1000"));
    });
    it("AND WHEN bob deposits 100DAI more, THEN event DepositToSmartPool is emitted", async () => {
      await expect(
        fixedLenderDAI.depositToSmartPool(parseUnits("100"))
      ).to.emit(fixedLenderDAI, "DepositToSmartPool");
    });
    describe("AND bob withdraws 500DAI", () => {
      beforeEach(async () => {
        let amountToWithdraw = parseUnits("500");
        await fixedLenderDAI.withdrawFromSmartPool(amountToWithdraw);
      });
      it("THEN balance of DAI in contract is 1500", async () => {
        let balanceOfAssetInContract = await underlyingTokenDAI.balanceOf(
          fixedLenderDAI.address
        );

        expect(balanceOfAssetInContract).to.equal(parseUnits("1500"));
      });
      it("THEN balance of eDAI in BOB's address is 500", async () => {
        let balanceOfETokenInUserAddress = await eDAI.balanceOf(bob.address);

        expect(balanceOfETokenInUserAddress).to.equal(parseUnits("500"));
      });
      it("AND WHEN bob withdraws 100DAI more, THEN event WithdrawFromSmartPool is emitted", async () => {
        await expect(
          fixedLenderDAI.withdrawFromSmartPool(parseUnits("100"))
        ).to.emit(fixedLenderDAI, "WithdrawFromSmartPool");
      });
      it("AND WHEN bob wants to withdraw 600DAI more, THEN it reverts because his eDAI balance is not enough", async () => {
        await expect(
          fixedLenderDAI.withdrawFromSmartPool(parseUnits("600"))
        ).to.be.revertedWith("ERC20: burn amount exceeds balance");
      });
    });
  });
  describe("GIVEN bob has 1WBTC in balance, AND deposit 1WBTC", () => {
    beforeEach(async () => {
      let bobBalance = parseUnits("1", 8);
      await underlyingTokenWBTC.approve(fixedLenderWBTC.address, bobBalance);

      await fixedLenderWBTC.depositToSmartPool(parseUnits("1", 8));
    });
    it("THEN balance of WBTC in contract is 1", async () => {
      let balanceOfAssetInContract = await underlyingTokenWBTC.balanceOf(
        fixedLenderWBTC.address
      );

      expect(balanceOfAssetInContract).to.equal(parseUnits("1", 8));
    });
    it("THEN balance of eWBTC in BOB's address is 1", async () => {
      let balanceOfETokenInUserAddress = await eWBTC.balanceOf(bob.address);

      expect(balanceOfETokenInUserAddress).to.equal(parseUnits("1", 8));
    });
  });
});