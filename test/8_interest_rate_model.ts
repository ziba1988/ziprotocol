import { expect } from "chai";
import { parseUnits } from "@ethersproject/units";
import { Contract } from "ethers";
import { ExaTime, ProtocolError, errorGeneric } from "./exactlyUtils";
import { DefaultEnv } from "./defaultEnv";

describe("InterestRateModel", () => {
  let exactlyEnv: DefaultEnv;
  const exaTime = new ExaTime();
  const nextPoolID = exaTime.poolIDByNumberOfWeek(1);

  let interestRateModel: Contract;
  let snapshot: any;

  beforeEach(async () => {
    exactlyEnv = await DefaultEnv.create({
      useRealInterestRateModel: true,
    });

    interestRateModel = exactlyEnv.interestRateModel;
    // This helps with tests that use evm_setNextBlockTimestamp
    snapshot = await exactlyEnv.takeSnapshot();
  });

  afterEach(async () => {
    await exactlyEnv.revertSnapshot(snapshot);
  });

  it("should change parameters", async () => {
    const A = parseUnits("0.037125"); // A parameter for the curve
    const B = parseUnits("0.01625"); // B parameter for the curve
    const maxUtilizationRate = parseUnits("1.2"); // Maximum utilization rate
    const penaltyRate = parseUnits("0.025"); // Penalty rate

    await interestRateModel.setParameters(
      A,
      B,
      maxUtilizationRate,
      penaltyRate
    );
    expect(await interestRateModel.curveParameterA()).to.be.equal(A);
    expect(await interestRateModel.curveParameterB()).to.be.equal(B);
    expect(await interestRateModel.maxUtilizationRate()).to.be.equal(
      maxUtilizationRate
    );
    expect(await interestRateModel.penaltyRate()).to.be.equal(penaltyRate);
  });

  describe("GIVEN curve parameters yielding Ub=0.8, Umax=1.1, R0=0.02 and Rb=0.14", () => {
    beforeEach(async () => {
      // A = ((Umax*(Umax-Ub))/Ub)*(Rb-R0)
      // A = ((1.1*(1.1-0.8))/0.8)*(0.14-0.02)
      // A = 0.04950000000000000000

      // B = ((Umax/Ub)*R0) + (1-(Umax/Ub))*Rb
      // B = ((1.1/0.8)*0.02) + (1-(1.1/0.8))*0.14
      // B = -.02500000000000000000

      const A = parseUnits("0.0495"); // A parameter for the curve
      const B = parseUnits("-0.025"); // B parameter for the curve
      const maxUtilizationRate = parseUnits("1.1"); // Maximum utilization rate
      const penaltyRate = parseUnits("0.025"); // Penalty rate
      await interestRateModel.setParameters(
        A,
        B,
        maxUtilizationRate,
        penaltyRate
      );
    });
    describe("GIVEN a token with 6 decimals instead of 18", () => {
      it("WHEN asking for the interest at 0% utilization rate THEN it returns R0=0.02", async () => {
        const rate = await interestRateModel.getRateToBorrow(
          nextPoolID,
          nextPoolID - 365 * exaTime.ONE_DAY, // force yearly calculation
          parseUnits("0", 6), // 0 borrows, this is what makes U=0
          parseUnits("0", 6), // no MP supply
          parseUnits("100", 6) // 100 available from SP
        );
        expect(rate).to.eq(parseUnits("0.02"));
      });
      it("AND WHEN asking for the interest at 80% (Ub)utilization rate THEN it returns Rb=0.14", async () => {
        const rate = await interestRateModel.getRateToBorrow(
          nextPoolID,
          nextPoolID - 365 * exaTime.ONE_DAY, // force yearly calculation
          parseUnits("80", 6), // 80 borrowed, this is what makes U=0.8
          parseUnits("0"), // no MP supply
          parseUnits("100", 6) // 100 available from SP
        );
        expect(rate).to.eq(parseUnits("0.14"));
      });
    });
    describe("distinctions on where the liquidity comes from", () => {
      it("WHEN asking for the interest with a liquidity of zero THEN it reverts", async () => {
        const tx = interestRateModel.getRateToBorrow(
          nextPoolID,
          nextPoolID - exaTime.ONE_DAY,
          parseUnits("80"), // 80 borrowed, this is what makes U=0.8
          parseUnits("0"), // no MP supply
          parseUnits("0") // nothing available from SP
        );

        await expect(tx).to.be.revertedWith(
          errorGeneric(ProtocolError.INSUFFICIENT_PROTOCOL_LIQUIDITY)
        );
      });
      it("WHEN asking for the interest with 80 tokens borrowed and 100 supplied to the MP, THEN it returns Rb=0.14 because U=Ub", async () => {
        const rate = await interestRateModel.getRateToBorrow(
          nextPoolID,
          nextPoolID - 365 * exaTime.ONE_DAY, // force yearly calculation
          parseUnits("80"), // 80 borrowed, this is what makes U=0.8
          parseUnits("100"), // 100 supplied to MP
          parseUnits("0") // nothing available from SP
        );
        expect(rate).to.eq(parseUnits("0.14"));
      });
      it("WHEN asking for the interest with 80 tokens borrowed and 100 supplied to the MP AND 100 available from the SP, THEN it returns Rb=0.14 because U=Ub", async () => {
        const rate = await interestRateModel.getRateToBorrow(
          nextPoolID,
          nextPoolID - 365 * exaTime.ONE_DAY, // force yearly calculation
          parseUnits("80"), // 80 borrowed, this is what makes U=0.8
          parseUnits("100"), // 100 supplied to MP
          parseUnits("100") // 100 available from SP
        );
        expect(rate).to.eq(parseUnits("0.14"));
      });
      it("WHEN asking for the interest with 80 tokens borrowed and 150 supplied to the MP AND 100 available from the SP, THEN it returns a lower rate because U<Ub", async () => {
        const rate = await interestRateModel.getRateToBorrow(
          nextPoolID,
          nextPoolID - 365 * exaTime.ONE_DAY, // force yearly calculation
          parseUnits("80"), // 80 borrowed, this is what makes U=0.8
          parseUnits("150"), // 150 supplied to MP
          parseUnits("100") // 100 available from SP
        );
        // 0.0495/(1.1-(80/150))-0.025
        expect(rate).to.be.closeTo(parseUnits(".06235294117647058"), 100);
      });

      it("WHEN asking for the interest with 80 tokens borrowed and 150 supplied to the MP AND 100 available from the SP, THEN it returns a lower rate because U<Ub", async () => {
        const rate = await interestRateModel.getRateToBorrow(
          nextPoolID,
          nextPoolID - 365 * exaTime.ONE_DAY, // force yearly calculation
          parseUnits("80"), // 80 borrowed, this is what makes U=0.8
          parseUnits("100"), // 100 supplied to MP
          parseUnits("150") // 100 available from SP
        );
        // 0.0495/(1.1-(80/150))-0.025
        expect(rate).to.be.closeTo(parseUnits(".06235294117647058"), 100);
      });
    });

    it("WHEN asking for the interest at 0% utilization rate THEN it returns R0=0.02", async () => {
      const rate = await interestRateModel.getRateToBorrow(
        nextPoolID,
        nextPoolID - 365 * exaTime.ONE_DAY, // force yearly calculation
        parseUnits("0"), // 0 borrows, this is what makes U=0
        parseUnits("0"), // no MP supply
        parseUnits("100") // 100 available from SP
      );
      expect(rate).to.eq(parseUnits("0.02"));
    });
    it("AND WHEN asking for the interest at 80% (Ub)utilization rate THEN it returns Rb=0.14", async () => {
      const rate = await interestRateModel.getRateToBorrow(
        nextPoolID,
        nextPoolID - 365 * exaTime.ONE_DAY, // force yearly calculation
        parseUnits("80"), // 80 borrowed, this is what makes U=0.8
        parseUnits("0"), // no MP supply
        parseUnits("100") // 100 available from SP
      );
      expect(rate).to.eq(parseUnits("0.14"));
    });
    describe("high utilization rates", () => {
      it("AND WHEN asking for the interest at 90% (>Ub)utilization rate THEN it returns R=0.22 (price hike)", async () => {
        let rate = await interestRateModel.getRateToBorrow(
          nextPoolID,
          nextPoolID - 365 * exaTime.ONE_DAY, // force yearly calculation
          parseUnits("90"), // 90 borrowed, this is what makes U=0.9
          parseUnits("0"), // no MP supply
          parseUnits("100") // 100 available from SP
        );
        expect(rate).to.eq(parseUnits("0.2225"));

        rate = await interestRateModel.getRateToBorrow(
          nextPoolID,
          nextPoolID - 365 * exaTime.ONE_DAY, // force yearly calculation
          parseUnits("90"), // 90 borrowed, this is what makes U=0.9
          parseUnits("100"), // MP supply
          parseUnits("0") // nothing available from SP
        );
        expect(rate).to.eq(parseUnits("0.2225"));
      });
      it("AND WHEN asking for the interest at 100% (>Ub)utilization rate THEN it returns R=0.47 (price hike)", async () => {
        const rate = await interestRateModel.getRateToBorrow(
          nextPoolID,
          nextPoolID - 365 * exaTime.ONE_DAY,
          parseUnits("100"),
          parseUnits("100"),
          parseUnits("100")
        );
        expect(rate).to.eq(parseUnits("0.47"));
      });
      it("AND WHEN asking for the interest at 105% (close to Umax)utilization rate THEN it returns R=0.965 (price hike)", async () => {
        const rate = await interestRateModel.getRateToBorrow(
          nextPoolID,
          nextPoolID - 365 * exaTime.ONE_DAY,
          parseUnits("105"),
          parseUnits("100"),
          parseUnits("100")
        );
        expect(rate).to.eq(parseUnits("0.965"));
      });
      it("AND WHEN asking for the interest at 105% AND liquidity isnt enough, THEN it reverts", async () => {
        const tx = interestRateModel.getRateToBorrow(
          nextPoolID,
          nextPoolID - 365 * exaTime.ONE_DAY,
          parseUnits("105"),
          parseUnits("100"),
          parseUnits("0")
        );

        await expect(tx).to.be.revertedWith(
          errorGeneric(ProtocolError.INSUFFICIENT_PROTOCOL_LIQUIDITY)
        );
      });
      it("AND WHEN asking for the interest at Umax, THEN it reverts", async () => {
        const tx = interestRateModel.getRateToBorrow(
          nextPoolID,
          nextPoolID - 365 * exaTime.ONE_DAY,
          parseUnits("110"),
          parseUnits("100"),
          parseUnits("100")
        );

        await expect(tx).to.be.revertedWith(
          errorGeneric(ProtocolError.INSUFFICIENT_PROTOCOL_LIQUIDITY)
        );
      });
      it("AND WHEN asking for the interest at U>Umax, THEN it reverts", async () => {
        const tx = interestRateModel.getRateToBorrow(
          nextPoolID,
          nextPoolID - 365 * exaTime.ONE_DAY,
          parseUnits("115"),
          parseUnits("100"),
          parseUnits("100")
        );

        await expect(tx).to.be.revertedWith(
          errorGeneric(ProtocolError.INSUFFICIENT_PROTOCOL_LIQUIDITY)
        );
      });
    });
    describe("interest for durations other than a full year", () => {
      it("WHEN asking for the interest for negative time difference, THEN it reverts", async () => {
        const tx = interestRateModel.getRateToBorrow(
          nextPoolID,
          nextPoolID + exaTime.ONE_DAY,
          parseUnits("80"), // 80 borrowed, this is what makes U=0.8
          parseUnits("0"), // no MP supply
          parseUnits("100") // 100 available from SP
        );

        await expect(tx).to.be.revertedWith(
          errorGeneric(ProtocolError.INVALID_TIME_DIFFERENCE)
        );
      });
      it("WHEN asking for the interest for a time difference of zero, THEN it reverts", async () => {
        const tx = interestRateModel.getRateToBorrow(
          nextPoolID,
          nextPoolID,
          parseUnits("80"), // 80 borrowed, this is what makes U=0.8
          parseUnits("0"), // no MP supply
          parseUnits("100") // 100 available from SP
        );

        await expect(tx).to.be.revertedWith(
          errorGeneric(ProtocolError.INVALID_TIME_DIFFERENCE)
        );
      });
      it("WHEN asking for the interest for a 5-day period at Ub, THEN it returns Rb*(5/365)", async () => {
        const rate = await interestRateModel.getRateToBorrow(
          nextPoolID,
          nextPoolID - 5 * exaTime.ONE_DAY,
          parseUnits("80"), // 80 borrowed, this is what makes U=0.8
          parseUnits("0"), // no MP supply
          parseUnits("100") // 100 available from SP
        );

        // 0.14*5/365
        expect(rate).to.closeTo(parseUnits(".00191780821917808"), 100);
      });
      it("WHEN asking for the interest for a two-week period at Ub, THEN it returns Rb*(14/365)", async () => {
        const rate = await interestRateModel.getRateToBorrow(
          nextPoolID,
          nextPoolID - 14 * exaTime.ONE_DAY,
          parseUnits("80"), // 80 borrowed, this is what makes U=0.8
          parseUnits("0"), // no MP supply
          parseUnits("100") // 100 available from SP
        );

        // 0.14*14/365
        expect(rate).to.be.closeTo(parseUnits(".00536986301369863"), 100);
      });
      it("WHEN asking for the interest for a one-day period at U0, THEN it returns R0*(1/365)", async () => {
        const rate = await interestRateModel.getRateToBorrow(
          nextPoolID,
          nextPoolID - exaTime.ONE_DAY,
          parseUnits("0"), // 0 borrowed, this is what makes U=0
          parseUnits("0"), // no MP supply
          parseUnits("100") // 100 available from SP
        );

        // 0.02*1/365
        // .00005479452054794520
        expect(rate).to.be.closeTo(parseUnits(".00005479452054794"), 100);
      });

      it("WHEN asking for the interest for a five-second period at U0, THEN it returns R0*(5/(365*24*60*60))", async () => {
        const rate = await interestRateModel.getRateToBorrow(
          nextPoolID,
          nextPoolID - 5,
          parseUnits("0"), // 0 borrowed, this is what makes U=0
          parseUnits("0"), // no MP supply
          parseUnits("100") // 100 available from SP
        );

        // 0.02*5/(365*24*60*60)
        expect(rate).to.be.closeTo(parseUnits(".00000000317097919"), 100);
      });
    });
  });
});
