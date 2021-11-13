import { expect } from "chai";
import { ethers } from "hardhat";
import { parseUnits } from "@ethersproject/units";
import { Contract } from "ethers";
import {
  ProtocolError,
  ExactlyEnv,
  ExaTime,
  errorGeneric,
  DefaultEnv,
} from "./exactlyUtils";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";

describe("Liquidity computations", function () {
  let auditor: Contract;
  let exactlyEnv: DefaultEnv;
  let nextPoolID = new ExaTime().nextPoolID();

  let bob: SignerWithAddress;
  let laura: SignerWithAddress;

  let exafinDAI: Contract;
  let dai: Contract;
  let exafinUSDC: Contract;
  let usdc: Contract;
  let exafinWBTC: Contract;
  let wbtc: Contract;

  let mockedTokens = new Map([
    [
      "DAI",
      {
        decimals: 18,
        collateralRate: parseUnits("0.8", 18),
        usdPrice: parseUnits("1"),
      },
    ],
    [
      "USDC",
      {
        decimals: 6,
        collateralRate: parseUnits("0.8", 18),
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

  let snapshot: any;
  beforeEach(async () => {
    snapshot = await ethers.provider.send("evm_snapshot", []);
  });

  beforeEach(async () => {
    // the owner deploys the contracts
    // bob the borrower
    // laura the lender
    [bob, laura] = await ethers.getSigners();

    exactlyEnv = await ExactlyEnv.create(mockedTokens);
    auditor = exactlyEnv.auditor;

    exafinDAI = exactlyEnv.getExafin("DAI");
    dai = exactlyEnv.getUnderlying("DAI");
    exafinUSDC = exactlyEnv.getExafin("USDC");
    usdc = exactlyEnv.getUnderlying("USDC");
    exafinWBTC = exactlyEnv.getExafin("WBTC");
    wbtc = exactlyEnv.getUnderlying("WBTC");

    // TODO: perhaps pass the addresses to ExactlyEnv.create and do all the
    // transfers in the same place?
    // wbtc laura will provide liquidity on
    await wbtc.transfer(laura.address, parseUnits("100000", 8));
    await dai.transfer(laura.address, parseUnits("100000"));
    // dai & usdc bob will use as collateral
    await dai.transfer(bob.address, parseUnits("100000"));
    await usdc.transfer(bob.address, parseUnits("100000", 6));
    // we make DAI & USDC count as collateral
    await auditor.enterMarkets(
      [exafinDAI.address, exafinUSDC.address],
      nextPoolID
    );
    await auditor
      .connect(laura)
      .enterMarkets([exafinDAI.address, exafinUSDC.address], nextPoolID);
  });

  describe("positions arent immediately liquidateable", () => {
    describe("GIVEN laura supplies 1kdai", () => {
      beforeEach(async () => {
        const amount = parseUnits("1000");
        await dai.connect(laura).approve(exafinDAI.address, amount);
        await exafinDAI
          .connect(laura)
          .supply(laura.address, amount, nextPoolID);
      });
      it("THEN lauras liquidity is collateralRate*collateral -  0.8*1000 == 800, AND she has no shortfall", async () => {
        const [liquidity, shortfall] = await auditor.getAccountLiquidity(
          laura.address,
          nextPoolID
        );
        expect(liquidity).to.be.eq(parseUnits("800"));
        expect(shortfall).to.be.eq(parseUnits("0"));
      });
      // TODO: a test where the supply interest is != 0, see if there's an error like the one described in this commit
      it("AND she has zero debt and is owed 1000DAI", async () => {
        const [supplied, owed] = await exafinDAI.getAccountSnapshot(
          laura.address,
          nextPoolID
        );
        expect(supplied).to.be.eq(parseUnits("1000"));
        expect(owed).to.be.eq(parseUnits("0"));
      });
      it("AND WHEN laura asks for a 800 DAI loan, THEN it reverts because the interests make the owed amount larger than liquidity", async () => {
        await expect(
          exafinDAI.connect(laura).borrow(parseUnits("800"), nextPoolID)
        ).to.be.revertedWith(
          errorGeneric(ProtocolError.INSUFFICIENT_LIQUIDITY)
        );
      });

      describe("AND WHEN laura asks for a 799 DAI loan (1 DAI buffer for interest)", () => {
        beforeEach(async () => {
          await exafinDAI.connect(laura).borrow(parseUnits("799"), nextPoolID);
        });
        it("THEN lauras liquidity is zero, AND she has no shortfall", async () => {
          const [liquidity, shortfall] = await auditor.getAccountLiquidity(
            laura.address,
            nextPoolID
          );
          expect(liquidity).to.be.lt(parseUnits("1"));
          expect(shortfall).to.be.lt(parseUnits("1"));
        });
        it("AND she has 799+interest debt and is owed 1000DAI", async () => {
          const [supplied, borrowed] = await exafinDAI.getAccountSnapshot(
            laura.address,
            nextPoolID
          );
          expect(supplied).to.be.eq(parseUnits("1000"));
          expect(borrowed).to.be.gt(parseUnits("799"));
          expect(borrowed).to.be.lt(parseUnits("800"));
        });
      });
    });
  });

  describe("support for tokens with different decimals", () => {
    describe("GIVEN theres liquidity on the btc exafin", () => {
      beforeEach(async () => {
        // laura supplies wbtc to the protocol to have lendable money in the pool
        const amount = parseUnits("3", 8);
        await wbtc.connect(laura).approve(exafinWBTC.address, amount);
        await exafinWBTC
          .connect(laura)
          .supply(laura.address, amount, nextPoolID);
      });

      describe("AND GIVEN Bob provides 60kdai (18 decimals) as collateral", () => {
        beforeEach(async () => {
          await dai
            .connect(bob)
            .approve(exafinDAI.address, parseUnits("60000"));
          await exafinDAI
            .connect(bob)
            .supply(bob.address, parseUnits("60000"), nextPoolID);
        });
        // Here I'm trying to make sure we use the borrowed token's decimals
        // properly to compute liquidity
        // if we asume (wrongly) that all tokens have 18 decimals, then computing
        // the simulated liquidity for a token  with less than 18 decimals will
        // enable the creation of an undercolalteralized loan, since the
        // simulated liquidity would be orders of magnitude lower than the real
        // one
        it("WHEN he tries to take a 1btc (8 decimals) loan (100% collateralization), THEN it reverts", async () => {
          // We expect liquidity to be equal to zero
          await expect(
            exafinWBTC.connect(bob).borrow(parseUnits("1", 8), nextPoolID)
          ).to.be.revertedWith(
            errorGeneric(ProtocolError.INSUFFICIENT_LIQUIDITY)
          );
        });
      });

      describe("AND GIVEN Bob provides 20kdai (18 decimals) and 40kusdc (6 decimals) as collateral", () => {
        beforeEach(async () => {
          await dai
            .connect(bob)
            .approve(exafinDAI.address, parseUnits("20000"));
          await exafinDAI
            .connect(bob)
            .supply(bob.address, parseUnits("20000"), nextPoolID);
          await usdc
            .connect(bob)
            .approve(exafinUSDC.address, parseUnits("40000", 6));
          await exafinUSDC
            .connect(bob)
            .supply(bob.address, parseUnits("40000", 6), nextPoolID);
        });
        describe("AND GIVEN Bob takes a 0.5wbtc loan (200% collateralization)", () => {
          beforeEach(async () => {
            await exafinWBTC
              .connect(bob)
              .borrow(parseUnits("0.5", 8), nextPoolID);
          });
          describe("AND GIVEN the pool matures", () => {
            beforeEach(async () => {
              // Move in time to maturity
              await ethers.provider.send("evm_setNextBlockTimestamp", [
                nextPoolID,
              ]);
              await ethers.provider.send("evm_mine", []);
            });
            // this is similar to the previous test case, but instead of
            // computing the simulated liquidity with a supplyAmount of zero and
            // the to-be-loaned amount as the borrowAmount, the amount of
            // collateral to withdraw is passed as the supplyAmount
            it("WHEN he tries to redeem the usdc (8 decimals) collateral, THEN it reverts ()", async () => {
              // We expect liquidity to be equal to zero
              await expect(
                exafinUSDC
                  .connect(bob)
                  .redeem(bob.address, parseUnits("40000", 6), nextPoolID)
              ).to.be.revertedWith(
                errorGeneric(ProtocolError.INSUFFICIENT_LIQUIDITY)
              );
            });
          });
        });
      });
    });
  });

  afterEach(async () => {
    await ethers.provider.send("evm_revert", [snapshot]);
    await ethers.provider.send("evm_mine", []);
  });
});