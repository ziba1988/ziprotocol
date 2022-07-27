// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import { Vm } from "forge-std/Vm.sol";
import { Test } from "forge-std/Test.sol";
import { MockERC20 } from "@rari-capital/solmate/src/test/utils/mocks/MockERC20.sol";
import { FixedPointMathLib } from "@rari-capital/solmate/src/utils/FixedPointMathLib.sol";
import { MockInterestRateModel } from "../../contracts/mocks/MockInterestRateModel.sol";
import { Auditor, ExactlyOracle, InsufficientLiquidity } from "../../contracts/Auditor.sol";
import {
  Market,
  ERC20,
  PoolLib,
  TooMuchSlippage,
  ZeroRepay,
  SmartPoolReserveExceeded,
  InsufficientProtocolLiquidity
} from "../../contracts/Market.sol";
import { InterestRateModel } from "../../contracts/InterestRateModel.sol";
import { MockOracle } from "../../contracts/mocks/MockOracle.sol";
import { TSUtils } from "../../contracts/utils/TSUtils.sol";

contract MarketTest is Test {
  using FixedPointMathLib for uint256;

  address internal constant BOB = address(0x69);
  address internal constant ALICE = address(0x420);

  Auditor internal auditor;
  MockOracle internal mockOracle;
  Market internal market;
  Market internal marketWETH;
  MockERC20 internal weth;
  MockInterestRateModel internal mockInterestRateModel;
  string[] private tokens = ["DAI", "USDC", "WETH", "WBTC"];

  event Transfer(address indexed from, address indexed to, uint256 amount);
  event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares);
  event Withdraw(address indexed caller, address indexed receiver, uint256 assets, uint256 shares);
  event DepositAtMaturity(
    uint256 indexed maturity,
    address indexed caller,
    address indexed owner,
    uint256 assets,
    uint256 fee
  );
  event WithdrawAtMaturity(
    uint256 indexed maturity,
    address caller,
    address indexed receiver,
    address indexed owner,
    uint256 assets,
    uint256 assetsDiscounted
  );
  event BorrowAtMaturity(
    uint256 indexed maturity,
    address caller,
    address indexed receiver,
    address indexed borrower,
    uint256 assets,
    uint256 fee
  );
  event Borrow(
    address indexed caller,
    address indexed receiver,
    address indexed borrower,
    uint256 assets,
    uint256 shares
  );
  event RepayAtMaturity(
    uint256 indexed maturity,
    address indexed caller,
    address indexed borrower,
    uint256 assets,
    uint256 debtCovered
  );
  event Repay(address indexed caller, address indexed borrower, uint256 assets, uint256 shares);
  event LiquidateBorrow(
    address indexed receiver,
    address indexed borrower,
    uint256 repaidAssets,
    uint256 lendersAssets,
    Market indexed collateralMarket,
    uint256 seizedAssets
  );

  function setUp() external {
    MockERC20 token = new MockERC20("DAI", "DAI", 18);
    mockOracle = new MockOracle();
    auditor = new Auditor(ExactlyOracle(address(mockOracle)), Auditor.LiquidationIncentive(0.09e18, 0.01e18));
    mockInterestRateModel = new MockInterestRateModel(0.1e18);

    market = new Market(
      token,
      3,
      1e18,
      auditor,
      InterestRateModel(address(mockInterestRateModel)),
      0.02e18 / uint256(1 days),
      1e17,
      0,
      Market.DampSpeed(0.0046e18, 0.42e18)
    );

    weth = new MockERC20("WETH", "WETH", 18);
    marketWETH = new Market(
      weth,
      12,
      1e18,
      auditor,
      InterestRateModel(address(mockInterestRateModel)),
      0.02e18 / uint256(1 days),
      1e17,
      0,
      Market.DampSpeed(0.0046e18, 0.42e18)
    );

    auditor.enableMarket(market, 0.8e18, 18);
    auditor.enableMarket(marketWETH, 0.9e18, 18);
    auditor.enterMarket(marketWETH);

    vm.label(BOB, "Bob");
    vm.label(ALICE, "Alice");
    token.mint(BOB, 50_000 ether);
    token.mint(ALICE, 50_000 ether);
    token.mint(address(this), 50_000 ether);
    weth.mint(address(this), 50_000 ether);

    weth.approve(address(marketWETH), 50_000 ether);
    token.approve(address(market), type(uint256).max);
    vm.prank(BOB);
    token.approve(address(market), type(uint256).max);
    vm.prank(ALICE);
    token.approve(address(market), type(uint256).max);
  }

  function testDepositToSmartPool() external {
    vm.expectEmit(true, true, true, true, address(market));
    emit Deposit(address(this), address(this), 1 ether, 1 ether);

    market.deposit(1 ether, address(this));
  }

  function testWithdrawFromSmartPool() external {
    market.deposit(1 ether, address(this));

    vm.expectEmit(true, true, true, true, address(market.asset()));
    emit Transfer(address(market), address(this), 1 ether);
    market.withdraw(1 ether, address(this), address(this));
  }

  function testDepositAtMaturity() external {
    vm.expectEmit(true, true, true, true, address(market));
    emit DepositAtMaturity(TSUtils.INTERVAL, address(this), address(this), 1 ether, 0);
    market.depositAtMaturity(TSUtils.INTERVAL, 1 ether, 1 ether, address(this));
  }

  function testWithdrawAtMaturity() external {
    market.depositAtMaturity(TSUtils.INTERVAL, 1 ether, 1 ether, address(this));

    vm.expectEmit(true, true, true, true, address(market));
    emit WithdrawAtMaturity(TSUtils.INTERVAL, address(this), address(this), address(this), 1 ether, 909090909090909090);
    market.withdrawAtMaturity(TSUtils.INTERVAL, 1 ether, 0.9 ether, address(this), address(this));
  }

  function testBorrowAtMaturity() external {
    market.deposit(12 ether, address(this));

    vm.expectEmit(true, true, true, true, address(market));
    emit BorrowAtMaturity(TSUtils.INTERVAL, address(this), address(this), address(this), 1 ether, 0.1 ether);
    market.borrowAtMaturity(TSUtils.INTERVAL, 1 ether, 2 ether, address(this), address(this));
  }

  function testSingleFloatingBorrow() external {
    market.deposit(12 ether, address(this));

    vm.expectEmit(true, true, true, true, address(market));
    emit Borrow(address(this), address(this), address(this), 1 ether, 1 ether);
    market.borrow(1 ether, address(this), address(this));
  }

  function testRepayAtMaturity() external {
    market.deposit(12 ether, address(this));
    market.borrowAtMaturity(TSUtils.INTERVAL, 1 ether, 1.1 ether, address(this), address(this));

    vm.expectEmit(true, true, true, true, address(market));
    emit RepayAtMaturity(TSUtils.INTERVAL, address(this), address(this), 1.01 ether, 1.1 ether);
    market.repayAtMaturity(TSUtils.INTERVAL, 1.5 ether, 1.5 ether, address(this));
  }

  function testSingleFloatingRepay() external {
    market.deposit(12 ether, address(this));
    market.borrow(1 ether, address(this), address(this));

    vm.expectEmit(true, true, true, true, address(market));
    emit Repay(address(this), address(this), 1 ether, 1 ether);
    market.repay(1 ether, address(this));
  }

  function testDepositTooMuchSlippage() external {
    vm.expectRevert(TooMuchSlippage.selector);
    market.depositAtMaturity(TSUtils.INTERVAL, 1 ether, 1.1 ether, address(this));
  }

  function testBorrowTooMuchSlippage() external {
    market.deposit(12 ether, address(this));
    vm.expectRevert(TooMuchSlippage.selector);
    market.borrowAtMaturity(TSUtils.INTERVAL, 1 ether, 1 ether, address(this), address(this));
  }

  function testRepayTooMuchSlippage() external {
    market.deposit(12 ether, address(this));
    market.borrowAtMaturity(TSUtils.INTERVAL, 1 ether, 1.1 ether, address(this), address(this));
    vm.expectRevert(TooMuchSlippage.selector);
    market.repayAtMaturity(TSUtils.INTERVAL, 1 ether, 0.9 ether, address(this));
  }

  function testMultipleFixedBorrowsRepays() external {
    uint256 total = 0;
    market.deposit(100 ether, address(this));
    for (uint256 i = 1; i < 3 + 1; i++) {
      total += market.borrowAtMaturity(i * TSUtils.INTERVAL, 1 ether, 1.1 ether, address(this), address(this));
    }

    assertEq(market.getDebt(address(this)), total);

    for (uint256 i = 1; i < 3 + 1; i++) {
      market.repayAtMaturity(
        i * TSUtils.INTERVAL,
        uint256(1 ether).mulWadDown(1e18 + (0.1e18 * i * TSUtils.INTERVAL) / 365 days),
        1.01 ether,
        address(this)
      );
    }
  }

  function testMultipleDepositsToSmartPool() external {
    market.deposit(1 ether, address(this));
    market.deposit(1 ether, address(this));
    market.deposit(1 ether, address(this));
    market.deposit(1 ether, address(this));
    market.deposit(1 ether, address(this));
    market.deposit(1 ether, address(this));
    market.deposit(1 ether, address(this));
  }

  function testSmartPoolEarningsDistribution() external {
    vm.prank(BOB);
    market.deposit(10_000 ether, BOB);

    vm.warp(TSUtils.INTERVAL);

    vm.prank(BOB);
    market.borrowAtMaturity(TSUtils.INTERVAL * 2, 1_000 ether, 1_100 ether, BOB, BOB);

    vm.warp(TSUtils.INTERVAL + TSUtils.INTERVAL / 2);
    market.deposit(10_000 ether, address(this));
    assertEq(market.balanceOf(BOB), 10_000 ether);
    assertEq(market.maxWithdraw(address(this)), 10_000 ether - 1);
    assertApproxEqRel(market.balanceOf(address(this)), 9950 ether, 2.6e13);

    vm.warp(TSUtils.INTERVAL + (TSUtils.INTERVAL / 3) * 2);
    market.deposit(1_000 ether, address(this));
    assertApproxEqRel(market.balanceOf(address(this)), 10944 ether, 5e13);
  }

  function testSmartPoolSharesDoNotAccountUnassignedEarningsFromMoreThanOneIntervalPastMaturities() external {
    uint256 maturity = TSUtils.INTERVAL * 2;
    market.deposit(10_000 ether, address(this));
    market.borrowAtMaturity(maturity, 1_000 ether, 1_100 ether, address(this), address(this));

    // we move to the last second before an interval goes by after the maturity passed
    vm.warp(TSUtils.INTERVAL * 2 + TSUtils.INTERVAL - 1 seconds);
    assertLt(market.previewDeposit(10_000 ether), market.balanceOf(address(this)));

    // we move to the instant where an interval went by after the maturity passed
    vm.warp(TSUtils.INTERVAL * 3);
    // the unassigned earnings of the maturity that the contract borrowed from are not accounted anymore
    assertEq(market.previewDeposit(10_000 ether), market.balanceOf(address(this)));
  }

  function testPreviewOperationsWithSmartPoolCorrectlyAccountingEarnings() external {
    uint256 assets = 10_000 ether;
    uint256 maturity = TSUtils.INTERVAL * 2;
    uint256 anotherMaturity = TSUtils.INTERVAL * 3;
    market.deposit(assets, address(this));

    vm.warp(TSUtils.INTERVAL);
    market.borrowAtMaturity(maturity, 1_000 ether, 1_100 ether, address(this), address(this));

    vm.prank(BOB);
    market.deposit(10_000 ether, BOB);
    vm.prank(BOB); // we have unassigned earnings
    market.borrowAtMaturity(anotherMaturity, 1_000 ether, 1_100 ether, BOB, BOB);

    vm.warp(maturity + 1 days); // and we have penalties -> delayed a day
    market.repayAtMaturity(maturity, 1_100 ether, 1_200 ether, address(this));

    assertEq(
      market.previewRedeem(market.balanceOf(address(this))),
      market.redeem(market.balanceOf(address(this)), address(this), address(this))
    );

    vm.warp(maturity + 2 days);
    market.deposit(assets, address(this));
    vm.warp(maturity + 2 weeks); // a more relevant portion of the accumulator is distributed after 2 weeks
    assertEq(market.previewWithdraw(assets), market.withdraw(assets, address(this), address(this)));

    vm.warp(maturity + 3 weeks);
    assertEq(market.previewDeposit(assets), market.deposit(assets, address(this)));
    vm.warp(maturity + 4 weeks);
    assertEq(market.previewMint(10_000 ether), market.mint(10_000 ether, address(this)));
  }

  function testFrontRunSmartPoolEarningsDistributionWithBigPenaltyRepayment() external {
    uint256 maturity = TSUtils.INTERVAL * 2;
    market.deposit(10_000 ether, address(this));

    vm.warp(TSUtils.INTERVAL);
    market.borrowAtMaturity(maturity, 1_000 ether, 1_100 ether, address(this), address(this));

    vm.warp(maturity);
    market.repayAtMaturity(maturity, 1, 1, address(this)); // we send tx to accrue earnings

    vm.warp(maturity + 7 days * 2 - 1 seconds);
    vm.prank(BOB);
    market.deposit(10_100 ether, BOB); // bob deposits more assets to have same shares as previous user
    assertEq(market.balanceOf(BOB), 10_000 ether);
    uint256 assetsBobBefore = market.convertToAssets(market.balanceOf(address(this)));
    assertEq(assetsBobBefore, market.convertToAssets(market.balanceOf(address(this))));

    vm.warp(maturity + 7 days * 2); // 2 weeks delayed (2% daily = 28% in penalties), 1100 * 1.28 = 1408
    market.repayAtMaturity(maturity, 1_408 ether, 1_408 ether, address(this));
    // no penalties are accrued (accumulator accounts them)

    // 1 second passed since bob's deposit -> he now has 21219132878712 more if he withdraws
    assertEq(market.convertToAssets(market.balanceOf(BOB)), assetsBobBefore + 21219132878712);
    assertApproxEqRel(market.smartPoolEarningsAccumulator(), 308 ether, 1e7);

    vm.warp(maturity + 7 days * 5);
    // then the accumulator will distribute 20% of the accumulated earnings
    // 308e18 * 0.20 = 616e17
    vm.prank(ALICE);
    market.deposit(10_100 ether, ALICE); // alice deposits same assets amount as previous users
    assertApproxEqRel(market.smartPoolEarningsAccumulator(), 308 ether - 616e17, 1e14);
    // bob earns half the earnings distributed
    assertApproxEqRel(market.convertToAssets(market.balanceOf(BOB)), assetsBobBefore + 616e17 / 2, 1e14);
  }

  function testDistributeMultipleAccumulatedEarnings() external {
    vm.warp(0);
    uint256 maturity = TSUtils.INTERVAL * 2;
    market.deposit(10_000 ether, address(this));
    market.depositAtMaturity(maturity, 1_000 ether, 1_000 ether, address(this));

    vm.warp(maturity - 1 weeks);
    market.borrowAtMaturity(maturity, 1_000 ether, 1_100 ether, address(this), address(this));

    vm.warp(maturity + 2 weeks); // 2 weeks delayed (2% daily = 28% in penalties), 1100 * 1.28 = 1408
    market.repayAtMaturity(maturity, 1_408 ether, 1_408 ether, address(this));
    // no penalties are accrued (accumulator accounts all of them since borrow uses mp deposits)
    assertApproxEqRel(market.smartPoolEarningsAccumulator(), 408 ether, 1e7);

    vm.warp(maturity + 3 weeks);
    vm.prank(BOB);
    market.deposit(10_000 ether, BOB);

    uint256 balanceBobAfterFirstDistribution = market.convertToAssets(market.balanceOf(BOB));
    uint256 balanceContractAfterFirstDistribution = market.convertToAssets(market.balanceOf(address(this)));
    uint256 accumulatedEarningsAfterFirstDistribution = market.smartPoolEarningsAccumulator();

    // 196 ether are distributed from the accumulator
    assertApproxEqRel(balanceContractAfterFirstDistribution, 10_196 ether, 1e14);
    assertApproxEqAbs(balanceBobAfterFirstDistribution, 10_000 ether, 1);
    assertApproxEqRel(accumulatedEarningsAfterFirstDistribution, 408 ether - 196 ether, 1e16);
    assertEq(market.lastAccumulatedEarningsAccrual(), maturity + 3 weeks);

    vm.warp(maturity * 2 + 1 weeks);
    market.deposit(1_000 ether, address(this));

    uint256 balanceBobAfterSecondDistribution = market.convertToAssets(market.balanceOf(BOB));
    uint256 balanceContractAfterSecondDistribution = market.convertToAssets(market.balanceOf(address(this)));
    uint256 accumulatedEarningsAfterSecondDistribution = market.smartPoolEarningsAccumulator();

    uint256 earningsDistributed = balanceBobAfterSecondDistribution -
      balanceBobAfterFirstDistribution +
      balanceContractAfterSecondDistribution -
      balanceContractAfterFirstDistribution -
      1_000 ether; // new deposited eth
    uint256 earningsToBob = 35135460980638083225;
    uint256 earningsToContract = 35821060758380935905;

    assertEq(
      accumulatedEarningsAfterFirstDistribution - accumulatedEarningsAfterSecondDistribution,
      earningsDistributed
    );
    assertEq(earningsToBob + earningsToContract, earningsDistributed);
    assertEq(balanceBobAfterSecondDistribution, balanceBobAfterFirstDistribution + earningsToBob);
    assertEq(
      balanceContractAfterSecondDistribution,
      balanceContractAfterFirstDistribution + earningsToContract + 1_000 ether
    );
    assertEq(market.lastAccumulatedEarningsAccrual(), maturity * 2 + 1 weeks);
  }

  function testUpdateAccumulatedEarningsFactorToZero() external {
    vm.warp(0);
    uint256 maturity = TSUtils.INTERVAL * 2;
    market.deposit(10_000 ether, address(this));

    vm.warp(TSUtils.INTERVAL / 2);
    market.borrowAtMaturity(maturity, 1_000 ether, 1_100 ether, address(this), address(this));

    // accumulator accounts 10% of the fees, smartPoolFeeRate -> 0.1
    market.depositAtMaturity(maturity, 1_000 ether, 1_000 ether, address(this));
    assertEq(market.smartPoolEarningsAccumulator(), 10 ether);

    vm.warp(TSUtils.INTERVAL);
    market.deposit(1_000 ether, address(this));
    // 25% was distributed
    assertEq(market.convertToAssets(market.balanceOf(address(this))), 11_002.5 ether);
    assertEq(market.smartPoolEarningsAccumulator(), 7.5 ether);

    // we set the factor to 0 and all is distributed in the following tx
    market.setAccumulatedEarningsSmoothFactor(0);
    vm.warp(TSUtils.INTERVAL + 1 seconds);
    market.deposit(1 ether, address(this));
    assertEq(market.convertToAssets(market.balanceOf(address(this))), 11_011 ether);
    assertEq(market.smartPoolEarningsAccumulator(), 0);

    // accumulator has 0 earnings so nothing is distributed
    vm.warp(TSUtils.INTERVAL * 2);
    market.deposit(1 ether, address(this));
    assertEq(market.convertToAssets(market.balanceOf(address(this))), 11_012 ether);
    assertEq(market.smartPoolEarningsAccumulator(), 0);
  }

  function testFailAnotherUserRedeemWhenOwnerHasShortfall() external {
    market.deposit(10_000 ether, address(this));
    market.borrowAtMaturity(TSUtils.INTERVAL, 1_000 ether, 1_100 ether, address(this), address(this));

    uint256 assets = market.previewWithdraw(10_000 ether);
    market.approve(BOB, assets);
    market.deposit(1_000 ether, address(this));
    vm.prank(BOB);
    market.redeem(assets, address(this), address(this));
  }

  function testFailAnotherUserWithdrawWhenOwnerHasShortfall() external {
    market.deposit(10_000 ether, address(this));
    market.borrowAtMaturity(TSUtils.INTERVAL, 1_000 ether, 1_100 ether, address(this), address(this));

    market.approve(BOB, 10_000 ether);
    market.deposit(1_000 ether, address(this));
    vm.prank(BOB);
    market.withdraw(10_000 ether, address(this), address(this));
  }

  function testFailRoundingUpAllowanceWhenBorrowingAtMaturity() external {
    uint256 maturity = TSUtils.INTERVAL * 2;

    market.deposit(10_000 ether, address(this));
    market.borrowAtMaturity(maturity, 1 ether, 1.1 ether, address(this), address(this));
    vm.warp(TSUtils.INTERVAL);
    // we accrue earnings with this tx so we break proportion of 1 to 1 assets and shares
    market.borrowAtMaturity(maturity, 1 ether, 1.1 ether, address(this), address(this));

    vm.warp(TSUtils.INTERVAL + 3 days);
    vm.prank(BOB);
    // we try to borrow 1 unit on behalf of this contract as bob being msg.sender without allowance
    // if it correctly rounds up, it should fail
    market.borrowAtMaturity(maturity, 1, 2, BOB, address(this));
  }

  function testFailRoundingUpAllowanceWhenWithdrawingAtMaturity() external {
    uint256 maturity = TSUtils.INTERVAL * 2;

    market.deposit(10_000 ether, address(this));
    market.depositAtMaturity(maturity, 1 ether, 1 ether, address(this));
    vm.warp(TSUtils.INTERVAL);
    // we accrue earnings with this tx so we break proportion of 1 to 1 assets and shares
    market.borrowAtMaturity(maturity, 1 ether, 1.1 ether, address(this), address(this));

    vm.warp(maturity);
    vm.prank(BOB);
    // we try to withdraw 1 unit on behalf of this contract as bob being msg.sender without allowance
    // if it correctly rounds up, it should fail
    market.withdrawAtMaturity(maturity, 1, 0, BOB, address(this));
  }

  function testFailRoundingUpAssetsToValidateShortfallWhenTransferringFrom() external {
    MockERC20 token = new MockERC20("DAI", "DAI", 18);

    // we deploy a harness market to be able to set different supply and smartPoolAssets
    MarketHarness marketHarness = new MarketHarness(
      token,
      12,
      1e18,
      auditor,
      InterestRateModel(address(mockInterestRateModel)),
      0.02e18 / uint256(1 days),
      1e17,
      0,
      Market.DampSpeed(0.0046e18, 0.42e18)
    );
    uint256 maturity = TSUtils.INTERVAL * 2;
    token.mint(address(this), 50_000 ether);
    token.approve(address(marketHarness), 50_000 ether);
    marketHarness.approve(BOB, 50_000 ether);
    auditor.enableMarket(marketHarness, 0.8e18, 18);

    marketHarness.setSmartPoolAssets(500 ether);
    marketHarness.setSupply(2000 ether);

    marketHarness.deposit(1000 ether, address(this));
    mockInterestRateModel.setBorrowRate(0);
    marketHarness.borrowAtMaturity(maturity, 800 ether, 800 ether, address(this), address(this));

    // we try to transfer 5 shares, if it correctly rounds up to 2 withdraw amount then it should fail
    // if it rounds down to 1, it will pass
    vm.prank(BOB);
    marketHarness.transferFrom(address(this), BOB, 5);
  }

  function testFailRoundingUpAssetsToValidateShortfallWhenTransferring() external {
    MockERC20 token = new MockERC20("DAI", "DAI", 18);

    // we deploy a harness market to be able to set different supply and smartPoolAssets
    MarketHarness marketHarness = new MarketHarness(
      token,
      12,
      1e18,
      auditor,
      InterestRateModel(address(mockInterestRateModel)),
      0.02e18 / uint256(1 days),
      1e17,
      0,
      Market.DampSpeed(0.0046e18, 0.42e18)
    );
    uint256 maturity = TSUtils.INTERVAL * 2;
    token.mint(address(this), 50_000 ether);
    token.approve(address(marketHarness), 50_000 ether);
    auditor.enableMarket(marketHarness, 0.8e18, 18);

    marketHarness.setSmartPoolAssets(500 ether);
    marketHarness.setSupply(2000 ether);

    marketHarness.deposit(1000 ether, address(this));
    mockInterestRateModel.setBorrowRate(0);
    marketHarness.borrowAtMaturity(maturity, 800 ether, 800 ether, address(this), address(this));

    // we try to transfer 5 shares, if it correctly rounds up to 2 withdraw amount then it should fail
    // if it rounds down to 1, it will pass
    marketHarness.transfer(BOB, 5);
  }

  function testAccountLiquidityAdjustedDebt() external {
    // we deposit 1000 as collateral
    market.deposit(1_000 ether, address(this));

    mockInterestRateModel.setBorrowRate(0);
    // we borrow 100 as debt
    market.borrowAtMaturity(TSUtils.INTERVAL, 100 ether, 100 ether, address(this), address(this));

    (uint256 collateral, uint256 debt) = auditor.accountLiquidity(address(this), Market(address(0)), 0);
    (uint256 adjustFactor, , , ) = auditor.markets(market);

    assertEq(collateral, uint256(1_000 ether).mulDivDown(1e18, 10**18).mulWadDown(adjustFactor));
    assertEq(collateral, 800 ether);
    assertEq(debt, uint256(100 ether).mulDivUp(1e18, 10**18).divWadUp(adjustFactor));
    assertEq(debt, 125 ether);
  }

  function testCrossMaturityLiquidation() external {
    mockInterestRateModel.setBorrowRate(0);
    marketWETH.deposit(1.15 ether, address(this));
    market.deposit(50_000 ether, ALICE);
    market.setMaxFuturePools(12);
    market.setPenaltyRate(2e11);

    mockOracle.setPrice(marketWETH, 5_000e18);
    for (uint256 i = 1; i <= 4; i++) {
      market.borrowAtMaturity(TSUtils.INTERVAL * i, 1_000 ether, 1_000 ether, address(this), address(this));
    }

    mockOracle.setPrice(marketWETH, 10e18);
    vm.warp(2 * TSUtils.INTERVAL + 1);

    vm.prank(BOB);
    vm.expectEmit(true, true, true, true, address(market));
    emit LiquidateBorrow(BOB, address(this), 10454545454545454545, 104545454545454545, marketWETH, 1.15 ether);
    market.liquidate(address(this), type(uint256).max, marketWETH);
    (uint256 remainingCollateral, uint256 remainingDebt) = auditor.accountLiquidity(
      address(this),
      Market(address(0)),
      0
    );
    assertEq(remainingCollateral, 0);
    assertEq(remainingDebt, 0);
    assertEq(marketWETH.balanceOf(address(this)), 0);
    assertEq(weth.balanceOf(address(BOB)), 1.15 ether);
  }

  function testMultipleLiquidationSameUser() external {
    mockInterestRateModel.setBorrowRate(0);
    marketWETH.deposit(1.15 ether, address(this));
    market.deposit(5_000 ether, ALICE);
    market.setPenaltyRate(2e11);
    mockOracle.setPrice(marketWETH, 5_000e18);
    auditor.setLiquidationIncentive(Auditor.LiquidationIncentive(0.1e18, 0));

    market.borrowAtMaturity(TSUtils.INTERVAL, 4_000 ether, 4_000 ether, address(this), address(this));
    mockOracle.setPrice(marketWETH, 1_000e18);

    vm.warp(TSUtils.INTERVAL * 2 + 1);
    vm.prank(BOB);
    market.liquidate(address(this), 500 ether, marketWETH);
    (uint256 remainingCollateral, uint256 remainingDebt) = auditor.accountLiquidity(
      address(this),
      Market(address(0)),
      0
    );
    assertEq(remainingCollateral, 540 ether);
    assertEq(remainingDebt, 6794.201 ether);
    assertEq(marketWETH.balanceOf(address(this)), 0.6 ether);
    assertEq(weth.balanceOf(address(BOB)), 0.55 ether);

    vm.prank(BOB);
    market.liquidate(address(this), 100 ether, marketWETH);
    (remainingCollateral, remainingDebt) = auditor.accountLiquidity(address(this), Market(address(0)), 0);
    assertEq(remainingCollateral, 441 ether);
    assertEq(remainingDebt, 6669.201 ether);
    assertEq(marketWETH.balanceOf(address(this)), 0.49 ether);
    assertEq(weth.balanceOf(address(BOB)), 0.66 ether);

    vm.prank(BOB);
    market.liquidate(address(this), 500 ether, marketWETH);
    (remainingCollateral, remainingDebt) = auditor.accountLiquidity(address(this), Market(address(0)), 0);
    assertEq(remainingCollateral, 0);
    assertEq(remainingDebt, 0);
    assertEq(marketWETH.balanceOf(address(this)), 0);
    assertEq(weth.balanceOf(address(BOB)), 1.15 ether);
  }

  function testLiquidateWithZeroAsMaxAssets() external {
    mockInterestRateModel.setBorrowRate(0);
    marketWETH.deposit(1.15 ether, address(this));
    market.deposit(5_000 ether, ALICE);
    market.setPenaltyRate(2e11);
    mockOracle.setPrice(marketWETH, 5_000e18);

    market.borrowAtMaturity(TSUtils.INTERVAL, 4_000 ether, 4_000 ether, address(this), address(this));
    mockOracle.setPrice(marketWETH, 100e18);

    vm.expectRevert(ZeroRepay.selector);
    vm.prank(BOB);
    market.liquidate(address(this), 0, market);
  }

  function testLiquidateAndSeizeFromEmptyCollateral() external {
    mockInterestRateModel.setBorrowRate(0);
    marketWETH.deposit(1.15 ether, address(this));
    market.deposit(5_000 ether, ALICE);
    market.setPenaltyRate(2e11);
    mockOracle.setPrice(marketWETH, 5_000e18);

    market.borrowAtMaturity(TSUtils.INTERVAL, 1_000 ether, 1_000 ether, address(this), address(this));
    mockOracle.setPrice(marketWETH, 100e18);

    vm.expectRevert(ZeroRepay.selector);
    vm.prank(BOB);
    market.liquidate(address(this), 3000 ether, market);
  }

  function testLiquidateLeavingDustAsCollateral() external {
    mockInterestRateModel.setBorrowRate(0);
    marketWETH.deposit(1.15 ether, address(this));
    market.deposit(5_000 ether, ALICE);
    market.setPenaltyRate(2e11);
    mockOracle.setPrice(marketWETH, 5_000e18);
    auditor.setLiquidationIncentive(Auditor.LiquidationIncentive(0.1e18, 0));

    for (uint256 i = 1; i <= 3; i++) {
      market.borrowAtMaturity(TSUtils.INTERVAL, 1_000 ether, 1_000 ether, address(this), address(this));
    }
    mockOracle.setPrice(marketWETH, 99e18);

    vm.warp(TSUtils.INTERVAL * 3 + 182 days + 123 minutes + 10 seconds);

    vm.prank(BOB);
    market.liquidate(address(this), 103499999999999999800, marketWETH);
    assertEq(marketWETH.maxWithdraw(address(this)), 1);

    vm.prank(BOB);
    market.liquidate(address(this), type(uint256).max, marketWETH);
    (uint256 remainingCollateral, uint256 remainingDebt) = auditor.accountLiquidity(
      address(this),
      Market(address(0)),
      0
    );

    assertEq(marketWETH.maxWithdraw(address(this)), 0);
    assertEq(remainingCollateral, 0);
    assertEq(remainingDebt, 0);
  }

  function testLiquidateAndSeizeExactAmountWithDustAsCollateral() external {
    mockInterestRateModel.setBorrowRate(0);
    marketWETH.deposit(1.15 ether + 5, address(this));
    market.deposit(5_000 ether, ALICE);
    market.setPenaltyRate(2e11);
    mockOracle.setPrice(marketWETH, 5_000e18);
    auditor.setLiquidationIncentive(Auditor.LiquidationIncentive(0.1e18, 0));

    for (uint256 i = 1; i <= 3; i++) {
      market.borrowAtMaturity(TSUtils.INTERVAL, 1_000 ether + 100, 1_000 ether + 100, address(this), address(this));
    }
    mockOracle.setPrice(marketWETH, 100e18);

    vm.warp(TSUtils.INTERVAL * 3 + 182 days + 123 minutes + 10 seconds);

    vm.prank(BOB);
    market.liquidate(address(this), type(uint256).max, marketWETH);
    (uint256 remainingCollateral, uint256 remainingDebt) = auditor.accountLiquidity(
      address(this),
      Market(address(0)),
      0
    );
    assertEq(remainingCollateral, 0);
    assertEq(remainingDebt, 0);
  }

  function testLiquidateWithTwoUnitsAsMaxAssets() external {
    mockInterestRateModel.setBorrowRate(0);
    marketWETH.deposit(1.15 ether, address(this));
    market.deposit(5_000 ether, ALICE);
    market.setPenaltyRate(2e11);
    mockOracle.setPrice(marketWETH, 5_000e18);

    market.borrowAtMaturity(TSUtils.INTERVAL, 1_000 ether, 1_000 ether, address(this), address(this));
    market.borrowAtMaturity(TSUtils.INTERVAL * 2, 1_000 ether, 1_000 ether, address(this), address(this));
    mockOracle.setPrice(marketWETH, 100e18);

    vm.prank(BOB);
    market.liquidate(address(this), 2, marketWETH);

    (uint256 remainingCollateral, uint256 remainingDebt) = auditor.accountLiquidity(
      address(this),
      Market(address(0)),
      0
    );
    assertGt(remainingCollateral, 0);
    assertGt(remainingDebt, 0);
  }

  function testLiquidateFlexibleBorrow() external {
    marketWETH.deposit(1.15 ether, address(this));
    market.deposit(50_000 ether, ALICE);

    mockOracle.setPrice(marketWETH, 5_000e18);
    market.borrow(4_000 ether, address(this), address(this));
    mockOracle.setPrice(marketWETH, 4_000e18);

    assertEq(market.flexibleBorrowPositions(address(this)), 4_000 ether);

    // partial liquidation
    vm.prank(BOB);
    market.liquidate(address(this), type(uint256).max, marketWETH);
    uint256 assetsRepaid = 3685589519650655024000;

    (, uint256 remainingDebt) = market.getAccountSnapshot(address(this));
    (uint256 remainingCollateral, ) = marketWETH.getAccountSnapshot(address(this));
    assertEq(weth.balanceOf(address(BOB)), assetsRepaid.divWadDown(4_000 ether).mulWadUp(1.1e18));
    assertEq(remainingCollateral, 1.15 ether - assetsRepaid.divWadDown(4_000 ether).mulWadUp(1.1e18));
    assertEq(market.flexibleBorrowPositions(address(this)), 4_000 ether - assetsRepaid);
    assertEq(market.flexibleBorrowPositions(address(this)), remainingDebt);

    (uint256 usdCollateral, uint256 usdDebt) = auditor.accountLiquidity(address(this), Market(address(0)), 0);
    assertEq(usdCollateral, remainingCollateral.mulWadDown(4_000 ether).mulWadDown(0.9e18));
    assertEq(usdDebt, remainingDebt.divWadUp(0.8e18));

    mockOracle.setPrice(marketWETH, 1_000e18);
    // full liquidation
    vm.prank(BOB);
    market.liquidate(address(this), type(uint256).max, marketWETH);

    (, remainingDebt) = market.getAccountSnapshot(address(this));
    (remainingCollateral, ) = marketWETH.getAccountSnapshot(address(this));
    (usdCollateral, usdDebt) = auditor.accountLiquidity(address(this), Market(address(0)), 0);
    assertEq(remainingCollateral, 0);
    assertEq(remainingDebt, 0);
    assertEq(usdCollateral, 0);
    assertEq(usdDebt, 0);
    assertEq(market.flexibleBorrowPositions(address(this)), 0);
    assertEq(weth.balanceOf(address(BOB)), 1.15 ether);
  }

  function testLiquidateFlexibleBorrowChargeLendersAssetsToLiquidator() external {
    marketWETH.deposit(1.15 ether, address(this));
    market.deposit(50_000 ether, ALICE);

    mockOracle.setPrice(marketWETH, 5_000e18);
    market.borrow(4_000 ether, address(this), address(this));
    mockOracle.setPrice(marketWETH, 3_000e18);

    uint256 bobDAIBalanceBefore = ERC20(market.asset()).balanceOf(BOB);
    vm.prank(BOB);
    market.liquidate(address(this), 100 ether, marketWETH);
    uint256 assetsRepaid = uint256(100 ether).divWadDown(1.01e18);
    uint256 lendersIncentiveRepaid = assetsRepaid.mulWadDown(0.01e18);
    uint256 assetsSeized = assetsRepaid.mulDivUp(10**18, 3_000 ether).mulWadUp(1.1e18);
    assertEq(ERC20(market.asset()).balanceOf(BOB), bobDAIBalanceBefore - assetsRepaid - lendersIncentiveRepaid);
    assertEq(weth.balanceOf(address(BOB)), assetsSeized);
  }

  function testLiquidateFlexibleAndFixedBorrowPositionsInSingleCall() external {
    mockInterestRateModel.setBorrowRate(0);
    marketWETH.deposit(1.15 ether, address(this));
    mockOracle.setPrice(marketWETH, 5_000e18);
    market.deposit(50_000 ether, ALICE);

    for (uint256 i = 1; i <= 2; i++) {
      market.borrowAtMaturity(TSUtils.INTERVAL * i, 1_000 ether, 1_000 ether, address(this), address(this));
    }

    market.borrow(2_000 ether, address(this), address(this));
    mockOracle.setPrice(marketWETH, 4_000e18);

    vm.prank(BOB);
    market.liquidate(address(this), 1000 ether, marketWETH);
    uint256 assetsRepaid = uint256(1000 ether).divWadDown(1.01e18);
    // only repaid in the first maturity
    (uint256 principal, uint256 fee) = market.fixedBorrowPositions(TSUtils.INTERVAL, address(this));
    assertEq(principal + fee, 1_000 ether - assetsRepaid);
    (principal, fee) = market.fixedBorrowPositions(TSUtils.INTERVAL * 2, address(this));
    assertEq(principal + fee, 1_000 ether);
    assertEq(market.flexibleBorrowPositions(address(this)), 2_000 ether);

    vm.prank(BOB);
    market.liquidate(address(this), 1500 ether, marketWETH);
    assetsRepaid += uint256(1500 ether).divWadDown(1.01e18);
    (principal, fee) = market.fixedBorrowPositions(TSUtils.INTERVAL, address(this));
    assertEq(principal + fee, 0);
    (principal, fee) = market.fixedBorrowPositions(TSUtils.INTERVAL * 2, address(this));
    assertEq(principal + fee, 0);
    assertEq(market.flexibleBorrowPositions(address(this)), 2_000 ether - (assetsRepaid - 2_000 ether));

    vm.prank(BOB);
    market.liquidate(address(this), 1500 ether, marketWETH);
  }

  function testLiquidateAndChargeIncentiveForLenders() external {
    mockInterestRateModel.setBorrowRate(0);
    marketWETH.deposit(1.15 ether, address(this));
    market.deposit(50_000 ether, ALICE);
    market.setMaxFuturePools(12);

    mockOracle.setPrice(marketWETH, 5_000e18);
    for (uint256 i = 1; i <= 4; i++) {
      market.borrowAtMaturity(TSUtils.INTERVAL * i, 1_000 ether, 1_000 ether, address(this), address(this));
    }
    mockOracle.setPrice(marketWETH, 3_000e18);

    uint256 bobDAIBalanceBefore = ERC20(market.asset()).balanceOf(BOB);
    vm.prank(BOB);
    market.liquidate(address(this), type(uint256).max, marketWETH);
    uint256 bobDAIBalanceAfter = ERC20(market.asset()).balanceOf(BOB);
    // if 110% is 1.15 ether then 100% is 1.0454545455 ether * 3_000 (eth price) = 3136363636363636363637
    // bob will repay 1% of that amount
    uint256 totalBobRepayment = uint256(3136363636363636363637).mulWadDown(1.01e18);

    // BOB STILL SEIZES ALL USER COLLATERAL
    assertEq(weth.balanceOf(address(BOB)), 1.15 ether);
    assertEq(bobDAIBalanceBefore - bobDAIBalanceAfter, totalBobRepayment);
  }

  function testLiquidateFlexibleBorrowConsideringDebtOverTime() external {
    vm.warp(0);
    marketWETH.deposit(1.15 ether, address(this));
    market.deposit(50_000 ether, ALICE);

    mockOracle.setPrice(marketWETH, 5_000e18);
    market.borrow(4_000 ether, address(this), address(this));

    // 10% yearly interest
    vm.warp(365 days);
    assertEq(market.getDebt(address(this)), 4_000 ether + 400 ether);

    // bob is allowed to repay 2970
    vm.prank(BOB);
    market.liquidate(address(this), type(uint256).max, marketWETH);

    assertApproxEqRel(market.getDebt(address(this)), 1_430 ether, 1e18);
    assertApproxEqRel(market.smartPoolFlexibleBorrows(), 1_430 ether, 1e18);
    assertEq(market.smartPoolAssets(), 50_400 ether);
    assertEq(market.lastUpdatedSmartPoolRate(), 365 days);
  }

  function testLiquidateAndDistributeLosses() external {
    mockInterestRateModel.setBorrowRate(0);
    marketWETH.deposit(1.15 ether, address(this));
    market.deposit(50_000 ether, ALICE);
    market.setMaxFuturePools(12);

    mockOracle.setPrice(marketWETH, 5_000e18);
    for (uint256 i = 1; i <= 4; i++) {
      market.borrowAtMaturity(TSUtils.INTERVAL * i, 1_000 ether, 1_000 ether, address(this), address(this));
    }
    mockOracle.setPrice(marketWETH, 3_000e18);

    uint256 bobDAIBalanceBefore = ERC20(market.asset()).balanceOf(BOB);
    uint256 smartPoolAssetsBefore = market.smartPoolAssets();
    vm.prank(BOB);
    market.liquidate(address(this), type(uint256).max, marketWETH);
    uint256 bobDAIBalanceAfter = ERC20(market.asset()).balanceOf(BOB);
    uint256 smartPoolAssetsAfter = market.smartPoolAssets();
    uint256 totalUsdDebt = 1_000 ether * 4;
    // if 110% is 1.15 ether then 100% is 1.0454545455 ether * 3_000 (eth price) = 3136363636363636363637
    uint256 totalBobRepayment = 3136363636363636363637;
    uint256 lendersIncentive = uint256(3136363636363636363637).mulWadDown(0.01e18);

    // BOB SEIZES ALL USER COLLATERAL
    assertEq(weth.balanceOf(address(BOB)), 1.15 ether);
    assertEq(bobDAIBalanceBefore - bobDAIBalanceAfter, totalBobRepayment + lendersIncentive);
    assertEq(smartPoolAssetsBefore - smartPoolAssetsAfter, totalUsdDebt - totalBobRepayment);
    assertEq(market.fixedBorrows(address(this)), 0);
    for (uint256 i = 1; i <= 4; i++) {
      (uint256 principal, uint256 fee) = market.fixedBorrowPositions(TSUtils.INTERVAL * i, address(this));
      assertEq(principal + fee, 0);
    }
  }

  function testLiquidateAndSubtractLossesFromAccumulator() external {
    mockInterestRateModel.setBorrowRate(0.1e18);
    market.setSmartPoolFeeRate(0);
    marketWETH.deposit(1.3 ether, address(this));
    market.deposit(50_000 ether, ALICE);
    market.setMaxFuturePools(12);
    market.setPenaltyRate(2e11);

    mockOracle.setPrice(marketWETH, 5_000e18);
    for (uint256 i = 3; i <= 6; i++) {
      market.borrowAtMaturity(TSUtils.INTERVAL * i, 1_000 ether, 1_100 ether, address(this), address(this));
    }
    vm.prank(ALICE);
    market.borrowAtMaturity(TSUtils.INTERVAL, 5_000 ether, 5_500 ether, address(ALICE), address(ALICE));
    mockOracle.setPrice(marketWETH, 100e18);

    vm.warp(TSUtils.INTERVAL * 2);

    (uint256 principal, uint256 fee) = market.fixedBorrowPositions(TSUtils.INTERVAL, ALICE);
    (, uint256 debt) = market.getAccountSnapshot(ALICE);
    vm.prank(ALICE);
    market.repayAtMaturity(TSUtils.INTERVAL, principal + fee, debt, address(ALICE));
    uint256 smartPoolEarningsAccumulator = market.smartPoolEarningsAccumulator();
    uint256 smartPoolAssets = market.smartPoolAssets();

    assertEq(smartPoolEarningsAccumulator, debt - principal - fee);

    vm.prank(BOB);
    market.liquidate(address(this), type(uint256).max, marketWETH);

    uint256 badDebt = 981818181818181818181 + 1100000000000000000000 + 1100000000000000000000 + 1100000000000000000000;
    uint256 earningsSPDistributedInRepayment = 66666662073779496497;

    assertEq(market.smartPoolEarningsAccumulator(), 0);
    assertEq(
      badDebt,
      smartPoolEarningsAccumulator + smartPoolAssets - market.smartPoolAssets() + earningsSPDistributedInRepayment
    );
    assertEq(market.fixedBorrows(address(this)), 0);
  }

  function testDistributionOfLossesShouldReduceFromSmartPoolFixedBorrowsAccordingly() external {
    mockInterestRateModel.setBorrowRate(0);
    marketWETH.deposit(1.15 ether, address(this));
    market.deposit(50_000 ether, ALICE);
    market.setMaxFuturePools(12);

    mockOracle.setPrice(marketWETH, 5_000e18);
    for (uint256 i = 1; i <= 4; i++) {
      market.borrowAtMaturity(TSUtils.INTERVAL * i, 1_000 ether, 1_000 ether, address(this), address(this));

      // we deposit so smartPoolFixedBorrows is 0
      market.depositAtMaturity(TSUtils.INTERVAL * i, 1_000 ether, 1_000 ether, address(this));
    }
    mockOracle.setPrice(marketWETH, 3_000e18);

    assertEq(market.smartPoolFixedBorrows(), 0);
    vm.prank(BOB);
    // distribution of losses should not reduce more of smartPoolFixedBorrows
    market.liquidate(address(this), type(uint256).max, marketWETH);
    assertEq(market.smartPoolFixedBorrows(), 0);

    marketWETH.deposit(1.15 ether, address(this));
    mockOracle.setPrice(marketWETH, 5_000e18);
    for (uint256 i = 1; i <= 4; i++) {
      market.borrowAtMaturity(TSUtils.INTERVAL * i, 1_000 ether, 1_000 ether, address(this), address(this));

      // we withdraw 500 so smartPoolFixedBorrows is half
      market.withdrawAtMaturity(TSUtils.INTERVAL * i, 500 ether, 500 ether, address(this), address(this));
    }
    mockOracle.setPrice(marketWETH, 3_000e18);

    assertEq(market.smartPoolFixedBorrows(), (1_000 ether * 4) / 2);
    vm.prank(BOB);
    // distribution of losses should reduce the remaining from smartPoolFixedBorrows
    market.liquidate(address(this), type(uint256).max, marketWETH);
    assertEq(market.smartPoolFixedBorrows(), 0);
  }

  function testCappedLiquidation() external {
    mockInterestRateModel.setBorrowRate(0);
    mockOracle.setPrice(marketWETH, 2_000e18);

    market.deposit(50_000 ether, ALICE);
    marketWETH.deposit(1 ether, address(this));
    market.borrowAtMaturity(TSUtils.INTERVAL, 1_000 ether, 1_000 ether, address(this), address(this));

    mockOracle.setPrice(marketWETH, 900e18);

    vm.prank(BOB);
    // vm.expectEmit(true, true, true, true, address(market));
    // emit LiquidateBorrow(BOB, address(this), 818181818181818181819, 8181818181818181818, marketWETH, 1 ether);
    // we expect the liquidation to cap the max amount of possible assets to repay
    market.liquidate(address(this), type(uint256).max, marketWETH);
    (uint256 remainingCollateral, ) = auditor.accountLiquidity(address(this), Market(address(0)), 0);
    assertEq(remainingCollateral, 0);
  }

  function testLiquidationResultingInZeroCollateralAndZeroDebt() external {
    mockInterestRateModel.setBorrowRate(0);
    mockOracle.setPrice(marketWETH, 2_000e18);

    market.deposit(50_000 ether, ALICE);
    marketWETH.deposit(1 ether, address(this));
    market.borrowAtMaturity(TSUtils.INTERVAL, 1_000 ether, 1_000 ether, address(this), address(this));

    mockOracle.setPrice(marketWETH, 900e18);

    vm.prank(BOB);
    vm.expectEmit(true, true, true, true, address(market));
    emit LiquidateBorrow(BOB, address(this), 818181818181818181819, 8181818181818181818, marketWETH, 1 ether);
    market.liquidate(address(this), 1_000 ether, marketWETH);
    (uint256 remainingCollateral, uint256 remainingDebt) = auditor.accountLiquidity(
      address(this),
      Market(address(0)),
      0
    );
    assertEq(remainingCollateral, 0);
    assertEq(remainingDebt, 0);
  }

  function testUpdateSmartPoolAssetsAverageWithDampSpeedUp() external {
    vm.warp(0);
    market.deposit(100 ether, address(this));

    vm.warp(217);
    market.borrowAtMaturity(TSUtils.INTERVAL, 1, 1, address(this), address(this));
    assertLt(market.smartPoolAssetsAverage(), market.smartPoolAssets());

    vm.warp(435);
    market.borrowAtMaturity(TSUtils.INTERVAL, 1, 1, address(this), address(this));
    assertLt(market.smartPoolAssetsAverage(), market.smartPoolAssets());

    // with a damp speed up of 0.0046, the smartPoolAssetsAverage is equal to the smartPoolAssets
    // when 9011 seconds went by
    vm.warp(9446);
    market.borrowAtMaturity(TSUtils.INTERVAL, 1, 1, address(this), address(this));
    assertEq(market.smartPoolAssetsAverage(), market.smartPoolAssets());

    vm.warp(300000);
    market.borrowAtMaturity(TSUtils.INTERVAL, 1, 1, address(this), address(this));
    assertEq(market.smartPoolAssetsAverage(), market.smartPoolAssets());
  }

  function testUpdateSmartPoolAssetsAverageWithDampSpeedDown() external {
    vm.warp(0);
    market.deposit(100 ether, address(this));

    vm.warp(218);
    market.withdraw(50 ether, address(this), address(this));

    vm.warp(220);
    market.borrowAtMaturity(TSUtils.INTERVAL, 1, 1, address(this), address(this));
    assertLt(market.smartPoolAssets(), market.smartPoolAssetsAverage());

    vm.warp(300);
    market.borrowAtMaturity(TSUtils.INTERVAL, 1, 1, address(this), address(this));
    assertApproxEqRel(market.smartPoolAssetsAverage(), market.smartPoolAssets(), 1e6);

    // with a damp speed down of 0.42, the smartPoolAssetsAverage is equal to the smartPoolAssets
    // when 23 seconds went by
    vm.warp(323);
    market.borrowAtMaturity(TSUtils.INTERVAL, 1, 1, address(this), address(this));
    assertEq(market.smartPoolAssetsAverage(), market.smartPoolAssets());
  }

  function testUpdateSmartPoolAssetsAverageWhenDepositingRightBeforeEarlyWithdraw() external {
    uint256 initialBalance = 10 ether;
    uint256 amount = 1 ether;

    vm.warp(0);
    market.deposit(initialBalance, address(this));
    market.depositAtMaturity(TSUtils.INTERVAL, amount, amount, address(this));

    vm.warp(2000);
    market.deposit(100 ether, address(this));
    market.withdrawAtMaturity(TSUtils.INTERVAL, amount, 0.9 ether, address(this), address(this));
    assertApproxEqRel(market.smartPoolAssetsAverage(), initialBalance, 1e15);
    assertEq(market.smartPoolAssets(), 100 ether + initialBalance);
  }

  function testUpdateSmartPoolAssetsAverageWhenDepositingRightBeforeBorrow() external {
    uint256 initialBalance = 10 ether;
    vm.warp(0);
    market.deposit(initialBalance, address(this));

    vm.warp(2000);
    market.deposit(100 ether, address(this));
    market.borrowAtMaturity(TSUtils.INTERVAL, 1, 1, address(this), address(this));
    assertApproxEqRel(market.smartPoolAssetsAverage(), initialBalance, 1e15);
    assertEq(market.smartPoolAssets(), 100 ether + initialBalance);
  }

  function testUpdateSmartPoolAssetsAverageWhenDepositingSomeSecondsBeforeBorrow() external {
    vm.warp(0);
    market.deposit(10 ether, address(this));

    vm.warp(218);
    market.deposit(100 ether, address(this));
    uint256 lastSmartPoolAssetsAverage = market.smartPoolAssetsAverage();

    vm.warp(250);
    market.borrowAtMaturity(TSUtils.INTERVAL, 1, 1, address(this), address(this));
    uint256 supplyAverageFactor = uint256(1e18 - FixedPointMathLib.expWad(-int256(market.dampSpeedUp() * (250 - 218))));
    assertEq(
      market.smartPoolAssetsAverage(),
      lastSmartPoolAssetsAverage.mulWadDown(1e18 - supplyAverageFactor) +
        supplyAverageFactor.mulWadDown(market.smartPoolAssets())
    );
    assertEq(market.smartPoolAssetsAverage(), 20.521498717652997528 ether);

    vm.warp(9541);
    market.borrowAtMaturity(TSUtils.INTERVAL, 1, 1, address(this), address(this));
    assertEq(market.smartPoolAssetsAverage(), market.smartPoolAssets());
  }

  function testUpdateSmartPoolAssetsAverageWhenDepositingAndBorrowingContinuously() external {
    vm.warp(0);
    market.deposit(10 ether, address(this));

    vm.warp(218);
    market.deposit(100 ether, address(this));

    vm.warp(219);
    market.borrowAtMaturity(TSUtils.INTERVAL, 1, 1, address(this), address(this));
    assertEq(market.smartPoolAssetsAverage(), 6.807271809941046233 ether);

    vm.warp(220);
    market.borrowAtMaturity(TSUtils.INTERVAL, 1, 1, address(this), address(this));
    assertEq(market.smartPoolAssetsAverage(), 7.280868252688897889 ether);

    vm.warp(221);
    market.borrowAtMaturity(TSUtils.INTERVAL, 1, 1, address(this), address(this));
    assertEq(market.smartPoolAssetsAverage(), 7.752291154776303799 ether);

    vm.warp(222);
    market.borrowAtMaturity(TSUtils.INTERVAL, 1, 1, address(this), address(this));
    assertEq(market.smartPoolAssetsAverage(), 8.221550491529461938 ether);
  }

  function testUpdateSmartPoolAssetsAverageWhenDepositingAndWithdrawingEarlyContinuously() external {
    vm.warp(0);
    market.deposit(10 ether, address(this));
    market.depositAtMaturity(TSUtils.INTERVAL, 1 ether, 1 ether, address(this));

    vm.warp(218);
    market.deposit(100 ether, address(this));

    vm.warp(219);
    market.withdrawAtMaturity(TSUtils.INTERVAL, 1, 0, address(this), address(this));
    assertEq(market.smartPoolAssetsAverage(), 6.807271809941046233 ether);

    vm.warp(220);
    market.withdrawAtMaturity(TSUtils.INTERVAL, 1, 0, address(this), address(this));
    assertEq(market.smartPoolAssetsAverage(), 7.280868252688897889 ether);

    vm.warp(221);
    market.withdrawAtMaturity(TSUtils.INTERVAL, 1, 0, address(this), address(this));
    assertEq(market.smartPoolAssetsAverage(), 7.752291154776303799 ether);

    vm.warp(222);
    market.withdrawAtMaturity(TSUtils.INTERVAL, 1, 0, address(this), address(this));
    assertEq(market.smartPoolAssetsAverage(), 8.221550491529461938 ether);
  }

  function testUpdateSmartPoolAssetsAverageWhenWithdrawingRightBeforeBorrow() external {
    uint256 initialBalance = 10 ether;
    vm.warp(0);
    market.deposit(initialBalance, address(this));

    vm.warp(2000);
    market.withdraw(5 ether, address(this), address(this));
    market.borrowAtMaturity(TSUtils.INTERVAL, 1, 1, address(this), address(this));
    assertApproxEqRel(market.smartPoolAssetsAverage(), initialBalance, 1e15);
    assertEq(market.smartPoolAssets(), initialBalance - 5 ether);
  }

  function testUpdateSmartPoolAssetsAverageWhenWithdrawingRightBeforeEarlyWithdraw() external {
    uint256 initialBalance = 10 ether;
    uint256 amount = 1 ether;
    vm.warp(0);
    market.deposit(initialBalance, address(this));
    market.depositAtMaturity(TSUtils.INTERVAL, amount, amount, address(this));

    vm.warp(2000);
    market.withdraw(5 ether, address(this), address(this));
    market.withdrawAtMaturity(TSUtils.INTERVAL, amount, 0.9 ether, address(this), address(this));
    assertApproxEqRel(market.smartPoolAssetsAverage(), initialBalance, 1e15);
    assertEq(market.smartPoolAssets(), initialBalance - 5 ether);
  }

  function testUpdateSmartPoolAssetsAverageWhenWithdrawingSomeSecondsBeforeBorrow() external {
    vm.warp(0);
    market.deposit(10 ether, address(this));

    vm.warp(218);
    market.withdraw(5 ether, address(this), address(this));
    uint256 lastSmartPoolAssetsAverage = market.smartPoolAssetsAverage();

    vm.warp(219);
    market.borrowAtMaturity(TSUtils.INTERVAL, 1, 1, address(this), address(this));
    uint256 supplyAverageFactor = uint256(
      1e18 - FixedPointMathLib.expWad(-int256(market.dampSpeedDown() * (219 - 218)))
    );
    assertEq(
      market.smartPoolAssetsAverage(),
      uint256(lastSmartPoolAssetsAverage).mulWadDown(1e18 - supplyAverageFactor) +
        supplyAverageFactor.mulWadDown(market.smartPoolAssets())
    );
    assertEq(market.smartPoolAssetsAverage(), 5.874852456225897297 ether);

    vm.warp(221);
    market.borrowAtMaturity(TSUtils.INTERVAL, 1, 1, address(this), address(this));
    supplyAverageFactor = uint256(1e18 - FixedPointMathLib.expWad(-int256(market.dampSpeedDown() * (221 - 219))));
    assertEq(
      market.smartPoolAssetsAverage(),
      uint256(5.874852456225897297 ether).mulWadDown(1e18 - supplyAverageFactor) +
        supplyAverageFactor.mulWadDown(market.smartPoolAssets())
    );
    assertEq(market.smartPoolAssetsAverage(), 5.377683011800498150 ether);

    vm.warp(444);
    market.borrowAtMaturity(TSUtils.INTERVAL, 1, 1, address(this), address(this));
    assertEq(market.smartPoolAssetsAverage(), market.smartPoolAssets());
  }

  function testUpdateSmartPoolAssetsAverageWhenWithdrawingSomeSecondsBeforeEarlyWithdraw() external {
    vm.warp(0);
    market.depositAtMaturity(TSUtils.INTERVAL, 1 ether, 1 ether, address(this));
    market.deposit(10 ether, address(this));

    vm.warp(218);
    market.withdraw(5 ether, address(this), address(this));
    uint256 lastSmartPoolAssetsAverage = market.smartPoolAssetsAverage();

    vm.warp(219);
    market.withdrawAtMaturity(TSUtils.INTERVAL, 1, 0, address(this), address(this));
    uint256 supplyAverageFactor = uint256(
      1e18 - FixedPointMathLib.expWad(-int256(market.dampSpeedDown() * (219 - 218)))
    );
    assertEq(
      market.smartPoolAssetsAverage(),
      lastSmartPoolAssetsAverage.mulWadDown(1e18 - supplyAverageFactor) +
        supplyAverageFactor.mulWadDown(market.smartPoolAssets())
    );
    assertEq(market.smartPoolAssetsAverage(), 5.874852456225897297 ether);

    vm.warp(221);
    market.withdrawAtMaturity(TSUtils.INTERVAL, 1, 0, address(this), address(this));
    supplyAverageFactor = uint256(1e18 - FixedPointMathLib.expWad(-int256(market.dampSpeedDown() * (221 - 219))));
    assertEq(
      market.smartPoolAssetsAverage(),
      uint256(5.874852456225897297 ether).mulWadDown(1e18 - supplyAverageFactor) +
        supplyAverageFactor.mulWadDown(market.smartPoolAssets())
    );
    assertEq(market.smartPoolAssetsAverage(), 5.377683011800498150 ether);

    vm.warp(226);
    market.withdrawAtMaturity(TSUtils.INTERVAL, 1, 0, address(this), address(this));
    assertApproxEqRel(market.smartPoolAssetsAverage(), market.smartPoolAssets(), 1e17);
  }

  function testUpdateSmartPoolAssetsAverageWhenWithdrawingBeforeEarlyWithdrawsAndBorrows() external {
    vm.warp(0);
    market.depositAtMaturity(TSUtils.INTERVAL, 1 ether, 1 ether, address(this));
    market.deposit(10 ether, address(this));

    vm.warp(218);
    market.withdraw(5 ether, address(this), address(this));
    uint256 lastSmartPoolAssetsAverage = market.smartPoolAssetsAverage();

    vm.warp(219);
    market.withdrawAtMaturity(TSUtils.INTERVAL, 1, 0, address(this), address(this));
    uint256 supplyAverageFactor = uint256(
      1e18 - FixedPointMathLib.expWad(-int256(market.dampSpeedDown() * (219 - 218)))
    );
    assertEq(
      market.smartPoolAssetsAverage(),
      uint256(lastSmartPoolAssetsAverage).mulWadDown(1e18 - supplyAverageFactor) +
        supplyAverageFactor.mulWadDown(market.smartPoolAssets())
    );
    assertEq(market.smartPoolAssetsAverage(), 5.874852456225897297 ether);

    vm.warp(221);
    market.borrowAtMaturity(TSUtils.INTERVAL, 1, 1, address(this), address(this));
    supplyAverageFactor = uint256(1e18 - FixedPointMathLib.expWad(-int256(market.dampSpeedDown() * (221 - 219))));
    assertEq(
      market.smartPoolAssetsAverage(),
      uint256(5.874852456225897297 ether).mulWadDown(1e18 - supplyAverageFactor) +
        supplyAverageFactor.mulWadDown(market.smartPoolAssets())
    );
    assertEq(market.smartPoolAssetsAverage(), 5.377683011800498150 ether);

    vm.warp(223);
    market.withdrawAtMaturity(TSUtils.INTERVAL, 1, 0, address(this), address(this));
    supplyAverageFactor = uint256(1e18 - FixedPointMathLib.expWad(-int256(market.dampSpeedDown() * (223 - 221))));
    assertEq(
      market.smartPoolAssetsAverage(),
      uint256(5.377683011800498150 ether).mulWadDown(1e18 - supplyAverageFactor) +
        supplyAverageFactor.mulWadDown(market.smartPoolAssets())
    );
    assertEq(market.smartPoolAssetsAverage(), 5.163049730714664338 ether);

    vm.warp(226);
    market.withdrawAtMaturity(TSUtils.INTERVAL, 1, 0, address(this), address(this));
    assertApproxEqRel(market.smartPoolAssetsAverage(), market.smartPoolAssets(), 1e16);

    vm.warp(500);
    market.withdrawAtMaturity(TSUtils.INTERVAL, 1, 0, address(this), address(this));
    assertEq(market.smartPoolAssetsAverage(), market.smartPoolAssets());
  }

  function testFixedBorrowFailingWhenFlexibleBorrowAccruesDebt() external {
    market.deposit(100 ether, address(this));

    market.borrow(50 ether, address(this), address(this));

    vm.warp(365 days);
    vm.expectRevert(InsufficientLiquidity.selector);
    market.borrowAtMaturity(TSUtils.INTERVAL * 14, 10 ether, 15 ether, address(this), address(this));

    vm.expectRevert(InsufficientLiquidity.selector);
    market.transfer(address(BOB), 15 ether);

    vm.expectRevert(InsufficientLiquidity.selector);
    market.withdraw(15 ether, address(this), address(this));

    vm.expectRevert(InsufficientLiquidity.selector);
    market.withdraw(15 ether, address(this), address(this));

    market.approve(address(BOB), 15 ether);

    vm.prank(BOB);
    vm.expectRevert(InsufficientLiquidity.selector);
    market.transferFrom(address(this), address(BOB), 15 ether);
  }

  function testDepositShouldUpdateFlexibleBorrowVariables() external {
    vm.warp(0);
    market.deposit(100 ether, address(this));
    market.borrow(10 ether, address(this), address(this));
    uint256 spPreviousUtilization = market.spPreviousUtilization();

    vm.warp(365 days);
    market.deposit(1, address(this));

    assertEq(market.smartPoolFlexibleBorrows(), 11 ether);
    assertEq(market.smartPoolAssets(), 101 ether + 1);
    assertEq(market.lastUpdatedSmartPoolRate(), 365 days);
    assertGt(market.spPreviousUtilization(), spPreviousUtilization);
    spPreviousUtilization = market.spPreviousUtilization();

    vm.warp(730 days);
    market.mint(1, address(this));
    assertEq(market.smartPoolFlexibleBorrows(), 12.1 ether);
    assertEq(market.smartPoolAssets(), 102.1 ether + 3);
    assertEq(market.lastUpdatedSmartPoolRate(), 730 days);
    assertGt(market.spPreviousUtilization(), spPreviousUtilization);
  }

  function testWithdrawShouldUpdateFlexibleBorrowVariables() external {
    vm.warp(0);
    market.deposit(100 ether, address(this));
    market.borrow(10 ether, address(this), address(this));
    uint256 spPreviousUtilization = market.spPreviousUtilization();

    vm.warp(365 days);
    market.withdraw(1, address(this), address(this));

    assertEq(market.smartPoolFlexibleBorrows(), 11 ether);
    assertEq(market.smartPoolAssets(), 101 ether - 1);
    assertEq(market.lastUpdatedSmartPoolRate(), 365 days);
    assertGt(market.spPreviousUtilization(), spPreviousUtilization);
    spPreviousUtilization = market.spPreviousUtilization();

    vm.warp(730 days);
    market.redeem(1, address(this), address(this));

    assertEq(market.smartPoolFlexibleBorrows(), 12.1 ether);
    assertEq(market.smartPoolAssets(), 102.1 ether - 2);
    assertEq(market.lastUpdatedSmartPoolRate(), 730 days);
    assertGt(market.spPreviousUtilization(), spPreviousUtilization);
  }

  function testChargeTreasuryToFixedBorrows() external {
    market.setTreasury(address(BOB), 0.1e18);
    assertEq(market.treasury(), address(BOB));
    assertEq(market.treasuryFee(), 0.1e18);

    market.deposit(10 ether, address(this));
    market.borrowAtMaturity(TSUtils.INTERVAL, 1 ether, 2 ether, address(this), address(this));
    // treasury earns 10% of the 10% that is charged to the borrower
    assertEq(market.balanceOf(address(BOB)), 0.01 ether);
    // the treasury earnings are instantly added to the smart pool assets
    assertEq(market.smartPoolAssets(), 10 ether + 0.01 ether);

    (, , uint256 earningsUnassigned, ) = market.fixedPools(TSUtils.INTERVAL);
    // rest of it goes to earningsUnassigned of the fixed pool
    assertEq(earningsUnassigned, 0.09 ether);

    // when no fees are charged, the treasury logic should not revert
    mockInterestRateModel.setBorrowRate(0);
    market.borrowAtMaturity(TSUtils.INTERVAL, 1 ether, 1 ether, address(this), address(this));

    assertEq(market.balanceOf(address(BOB)), 0.01 ether);
    assertEq(market.smartPoolAssets(), 10 ether + 0.01 ether);

    vm.warp(TSUtils.INTERVAL / 2);

    vm.prank(ALICE);
    market.deposit(5 ether, address(this));
    mockInterestRateModel.setBorrowRate(0.1e18);
    market.borrowAtMaturity(TSUtils.INTERVAL, 1 ether, 2 ether, address(this), address(this));
    // treasury even ends up accruing more earnings
    assertLt(market.balanceOf(address(BOB)), 0.02 ether);
    assertGt(market.maxWithdraw(address(BOB)), 0.02 ether);
  }

  function testCollectTreasuryFreeLunchToFixedBorrows() external {
    market.setTreasury(address(BOB), 0.1e18);
    market.deposit(10 ether, address(this));
    market.depositAtMaturity(TSUtils.INTERVAL, 1 ether, 1 ether, address(this));
    market.borrowAtMaturity(TSUtils.INTERVAL, 1 ether, 2 ether, address(this), address(this));
    // treasury should earn all inefficient earnings charged to the borrower
    assertEq(market.balanceOf(address(BOB)), 0.1 ether);
    // the treasury earnings are instantly added to the smart pool assets
    assertEq(market.smartPoolAssets(), 10 ether + 0.1 ether);

    (, , uint256 earningsUnassigned, ) = market.fixedPools(TSUtils.INTERVAL);
    // earningsUnassigned and accumulator should not receive anything
    assertEq(earningsUnassigned, 0);
    assertEq(market.smartPoolEarningsAccumulator(), 0);

    market.depositAtMaturity(TSUtils.INTERVAL, 1 ether, 1 ether, address(this));
    market.borrowAtMaturity(TSUtils.INTERVAL, 2 ether, 3 ether, address(this), address(this));

    // treasury should earn 10% of 0.2 = 0.02
    // and HALF of inefficient earnings charged to the borrower = (0.2 - 0.02) / 2 = 0.09
    assertEq(market.balanceOf(address(BOB)), 0.1 ether + 0.02 ether + 0.09 ether);
    // the treasury earnings are instantly added to the smart pool assets
    assertEq(market.smartPoolAssets(), 10 ether + 0.1 ether + 0.02 ether + 0.09 ether);

    (, , earningsUnassigned, ) = market.fixedPools(TSUtils.INTERVAL);
    // earningsUnassigned should receive the other half
    assertEq(earningsUnassigned, 0.09 ether);
    assertEq(market.smartPoolEarningsAccumulator(), 0);

    // now when treasury fee is 0 again, all inefficient fees charged go to accumulator
    market.depositAtMaturity(TSUtils.INTERVAL, 2 ether, 1 ether, address(this));
    market.setTreasury(address(BOB), 0);
    market.borrowAtMaturity(TSUtils.INTERVAL, 1 ether, 2 ether, address(this), address(this));
    assertGt(market.smartPoolEarningsAccumulator(), 0.1 ether);
    assertEq(market.balanceOf(address(BOB)), 0.1 ether + 0.02 ether + 0.09 ether);
  }

  function testCollectTreasuryFreeLunchToFixedBorrowsWithZeroFees() external {
    market.setTreasury(address(BOB), 0.1e18);
    market.deposit(10 ether, address(this));
    market.depositAtMaturity(TSUtils.INTERVAL, 1 ether, 1 ether, address(this));
    // when no fees are charged, the treasury logic should not revert
    mockInterestRateModel.setBorrowRate(0);
    market.borrowAtMaturity(TSUtils.INTERVAL, 1 ether, 2 ether, address(this), address(this));
    // treasury shouldn't earn earnings
    assertEq(market.balanceOf(address(BOB)), 0);
    assertEq(market.smartPoolAssets(), 10 ether);

    (, , uint256 earningsUnassigned, ) = market.fixedPools(TSUtils.INTERVAL);
    // earningsUnassigned and accumulator should not receive anything either
    assertEq(earningsUnassigned, 0);
    assertEq(market.smartPoolEarningsAccumulator(), 0);
  }

  function testChargeTreasuryToEarlyWithdraws() external {
    market.deposit(10 ether, address(this));
    market.depositAtMaturity(TSUtils.INTERVAL, 2 ether, 2 ether, address(this));
    market.borrowAtMaturity(TSUtils.INTERVAL, 2 ether, 3 ether, address(this), address(this));

    market.setTreasury(address(BOB), 0.1e18);
    market.withdrawAtMaturity(TSUtils.INTERVAL, 1 ether, 0.9 ether, address(this), address(this));
    // treasury earns 10% of the 10% that is charged to the borrower
    assertEq(market.balanceOf(address(BOB)), 0.009090909090909091 ether);
    // the treasury earnings are instantly added to the smart pool assets
    assertEq(market.smartPoolAssets(), 10 ether + 0.009090909090909091 ether);

    (, , uint256 earningsUnassigned, ) = market.fixedPools(TSUtils.INTERVAL);
    // rest of it goes to earningsUnassigned of the fixed pool
    assertEq(earningsUnassigned, 1 ether - 0.909090909090909090 ether - 0.009090909090909091 ether);

    // when no fees are charged, the treasury logic should not revert
    mockInterestRateModel.setBorrowRate(0);
    market.withdrawAtMaturity(TSUtils.INTERVAL, 0.5 ether, 0.4 ether, address(this), address(this));

    assertEq(market.balanceOf(address(BOB)), 0.009090909090909091 ether);
    assertEq(market.smartPoolAssets(), 10 ether + 0.009090909090909091 ether);

    vm.warp(TSUtils.INTERVAL / 2);

    market.withdrawAtMaturity(TSUtils.INTERVAL, 0.5 ether, 0.4 ether, address(this), address(this));
    // treasury even ends up accruing more earnings
    assertGt(market.maxWithdraw(address(BOB)), market.balanceOf(address(BOB)));
  }

  function testCollectTreasuryFreeLunchToEarlyWithdraws() external {
    market.setTreasury(address(BOB), 0.1e18);
    market.deposit(10 ether, address(this));
    market.depositAtMaturity(TSUtils.INTERVAL, 1 ether, 1 ether, address(this));
    market.withdrawAtMaturity(TSUtils.INTERVAL, 1 ether, 0.9 ether, address(this), address(this));
    // treasury should earn all inefficient earnings charged to the borrower
    assertEq(market.balanceOf(address(BOB)), 0.090909090909090910 ether);
    // the treasury earnings are instantly added to the smart pool assets
    assertEq(market.smartPoolAssets(), 10 ether + 0.090909090909090910 ether);

    (, , uint256 earningsUnassigned, ) = market.fixedPools(TSUtils.INTERVAL);
    // earningsUnassigned and accumulator should not receive anything
    assertEq(earningsUnassigned, 0);
    assertEq(market.smartPoolEarningsAccumulator(), 0);

    market.depositAtMaturity(TSUtils.INTERVAL, 1 ether, 1 ether, address(this));
    mockInterestRateModel.setBorrowRate(0);
    market.borrowAtMaturity(TSUtils.INTERVAL, 0.5 ether, 1 ether, address(this), address(this));
    mockInterestRateModel.setBorrowRate(0.1e18);
    market.withdrawAtMaturity(TSUtils.INTERVAL, 1 ether, 0.9 ether, address(this), address(this));

    // treasury and earningsUnassigned should earn earnings
    assertEq(market.balanceOf(address(BOB)), 0.136818181818181819 ether);
    // the treasury earnings are instantly added to the smart pool assets
    assertEq(market.smartPoolAssets(), 10 ether + 0.136818181818181819 ether);

    (, , earningsUnassigned, ) = market.fixedPools(TSUtils.INTERVAL);
    // earningsUnassigned should receive the other part
    assertEq(earningsUnassigned, 0.045000000000000001 ether);
    assertEq(market.smartPoolEarningsAccumulator(), 0);

    // now when treasury fee is 0 again, all inefficient fees charged go to accumulator
    market.depositAtMaturity(TSUtils.INTERVAL, 1 ether, 1 ether, address(this));
    market.setTreasury(address(BOB), 0);
    market.borrowAtMaturity(TSUtils.INTERVAL, 1 ether, 2 ether, address(this), address(this));
    assertEq(market.smartPoolEarningsAccumulator(), 0.0545 ether);
    assertEq(market.balanceOf(address(BOB)), 0.136818181818181819 ether);
  }

  function testCollectTreasuryFreeLunchToEarlyWithdrawsWithZeroFees() external {
    market.setTreasury(address(BOB), 0.1e18);
    market.deposit(10 ether, address(this));
    market.depositAtMaturity(TSUtils.INTERVAL, 1 ether, 1 ether, address(this));
    // when no fees are charged, the treasury logic should not revert
    mockInterestRateModel.setBorrowRate(0);
    market.withdrawAtMaturity(TSUtils.INTERVAL, 1 ether, 0.9 ether, address(this), address(this));
    // treasury shouldn't earn earnings charged to the borrower
    assertEq(market.balanceOf(address(BOB)), 0);
    assertEq(market.smartPoolAssets(), 10 ether);

    (, , uint256 earningsUnassigned, ) = market.fixedPools(TSUtils.INTERVAL);
    // earningsUnassigned and accumulator should not receive anything either
    assertEq(earningsUnassigned, 0);
    assertEq(market.smartPoolEarningsAccumulator(), 0);
  }

  function testFlexibleBorrow() external {
    market.deposit(10 ether, address(this));
    uint256 balanceBefore = market.asset().balanceOf(address(this));
    market.borrow(1 ether, address(this), address(this));
    uint256 balanceAfter = market.asset().balanceOf(address(this));
    uint256 borrowedShares = market.flexibleBorrowPositions(address(this));

    assertEq(borrowedShares, 1 ether);
    assertEq(balanceAfter, balanceBefore + 1 ether);
  }

  function testFlexibleBorrowChargingDebtToTreasury() external {
    vm.warp(0);
    market.setTreasury(address(BOB), 0.1e18);

    market.deposit(10 ether, address(this));
    market.borrow(1 ether, address(this), address(this));

    vm.warp(365 days);
    // we can dynamically calculate borrow debt
    assertEq(market.getDebt(address(this)), 1.1 ether);
    // we distribute borrow debt with another borrow
    market.borrow(1, address(this), address(this));

    // treasury earns 10% of the 10% that is charged to the borrower
    assertEq(market.balanceOf(address(BOB)), 0.01 ether);
    // the treasury earnings + debt accrued are instantly added to the smart pool assets
    assertEq(market.smartPoolAssets(), 10 ether + 0.1 ether);
  }

  function testFlexibleBorrowFromAnotherUserWithAllowance() external {
    vm.prank(BOB);
    market.deposit(10 ether, address(BOB));
    vm.prank(BOB);
    market.approve(address(this), type(uint256).max);
    market.borrow(1 ether, address(this), address(BOB));
  }

  function testFlexibleBorrowFromAnotherUserSubtractsAllowance() external {
    vm.prank(BOB);
    market.deposit(10 ether, address(BOB));
    vm.prank(BOB);
    market.approve(address(this), 2 ether);
    market.borrow(1 ether, address(this), address(BOB));

    assertEq(market.allowance(address(BOB), address(this)), 2 ether - 1 ether);
  }

  function testFailFlexibleBorrowFromAnotherUserWithoutAllowance() external {
    market.deposit(10 ether, address(this));
    market.borrow(1 ether, address(this), address(BOB));
  }

  function testFlexibleBorrowAccountingDebt() external {
    vm.warp(0);
    market.deposit(10 ether, address(this));
    market.borrow(1 ether, address(this), address(this));
    assertEq(market.smartPoolFlexibleBorrows(), 1 ether);
    assertEq(market.totalFlexibleBorrowsShares(), market.flexibleBorrowPositions(address(this)));

    // after 1 year 10% is the accumulated debt (using a mock interest rate model)
    vm.warp(365 days);
    assertEq(market.getDebt(address(this)), 1.1 ether);
    market.repay(0.5 ether, address(this));
    assertEq(market.smartPoolFlexibleBorrows(), 0.55 ether);
    assertEq(market.totalFlexibleBorrowsShares(), market.flexibleBorrowPositions(address(this)));

    assertEq(market.flexibleBorrowPositions(address(this)), 0.5 ether);
    market.repay(0.5 ether, address(this));
    assertEq(market.flexibleBorrowPositions(address(this)), 0);
  }

  function testFlexibleBorrowAccountingDebtMultipleAccounts() internal {
    // TODO refactor
    vm.warp(0);

    mockOracle.setPrice(marketWETH, 1_000e18);
    weth.mint(BOB, 1 ether);
    vm.prank(BOB);
    weth.approve(address(marketWETH), 1 ether);
    vm.prank(BOB);
    marketWETH.deposit(1 ether, BOB);
    vm.prank(BOB);
    auditor.enterMarket(marketWETH);

    weth.mint(ALICE, 1 ether);
    vm.prank(ALICE);
    weth.approve(address(marketWETH), 1 ether);
    vm.prank(ALICE);
    marketWETH.deposit(1 ether, ALICE);
    vm.prank(ALICE);
    auditor.enterMarket(marketWETH);

    market.deposit(10 ether, address(this));
    market.borrow(1 ether, address(this), address(this));

    mockInterestRateModel.setBorrowRate(0.05e18);
    // after 1/2 year 2.5% is the accumulated debt (using a mock interest rate model)
    vm.warp(182.5 days);
    assertEq(market.previewRepay(1 ether), 1.025 ether);
    assertEq(market.getDebt(address(this)), 1.025 ether);

    vm.prank(BOB);
    market.borrow(1 ether, address(BOB), address(BOB));
    assertEq(market.previewRepay(1 ether), market.getDebt(address(BOB)));
    assertEq(market.previewRepay(1.025 ether), market.flexibleBorrowPositions(address(this)));

    // after 1/4 year 1.25% is the accumulated debt
    // contract now owes 1.025 * 1.0125 = 1.0378125 ether
    // bob now owes      1 * 1.0125     = 1.0125 ether
    vm.warp(273.75 days);
    vm.prank(ALICE);
    market.borrow(1 ether, address(ALICE), address(ALICE));
    // TODO: check rounding
    assertEq(market.previewRepay(1 ether), market.flexibleBorrowPositions(address(ALICE)) + 1);
    assertEq(market.previewRepay(1.0125 ether), market.flexibleBorrowPositions(address(BOB)));
    assertEq(market.previewRepay(1.0378125 ether), market.flexibleBorrowPositions(address(this)));

    // after another 1/4 year 1.25% is the accumulated debt
    // contract now owes 1.0378125 * 1.0125 = 1.0507851525 ether
    // bob now owes      1.0125 * 1.0125    = 1.02515625 ether
    // alice now owes    1 * 1.0125         = 1.0125 ether
    vm.warp(365 days);
    vm.prank(ALICE);
    market.repay(1.05078515625 ether, address(this));
    vm.prank(BOB);
    market.repay(1.02515625 ether, address(BOB));
    vm.prank(ALICE);
    market.repay(1.0125 ether, address(ALICE));

    assertEq(market.flexibleBorrowPositions(address(this)), 0);
    assertEq(market.flexibleBorrowPositions(address(BOB)), 0);
    assertEq(market.flexibleBorrowPositions(address(ALICE)), 0);

    uint256 flexibleDebtAccrued = 0.05078515625 ether + 0.02515625 ether + 0.0125 ether;
    assertEq(market.smartPoolAssets(), 10 ether + flexibleDebtAccrued);
  }

  function testFlexibleBorrowExceedingSmartPoolReserve() external {
    marketWETH.deposit(1 ether, address(this));
    mockOracle.setPrice(marketWETH, 1_000e18);

    market.deposit(10 ether, address(this));
    market.setSmartPoolReserveFactor(0.1e18);

    market.borrow(9 ether, address(this), address(this));
    market.repay(9 ether, address(this));

    vm.expectRevert(SmartPoolReserveExceeded.selector);
    market.borrow(9.01 ether, address(this), address(this));
  }

  function testFlexibleBorrowExceedingSmartPoolReserveIncludingFixedBorrow() external {
    marketWETH.deposit(1 ether, address(this));
    mockOracle.setPrice(marketWETH, 1_000e18);

    market.deposit(10 ether, address(this));
    market.setSmartPoolReserveFactor(0.1e18);

    market.borrowAtMaturity(TSUtils.INTERVAL, 1 ether, 2 ether, address(this), address(this));

    market.borrow(8 ether, address(this), address(this));
    market.repay(8 ether, address(this));

    vm.expectRevert(SmartPoolReserveExceeded.selector);
    market.borrow(8.01 ether, address(this), address(this));
  }

  function testFlexibleBorrowExceedingSmartPoolReserveWithNewDebt() external {
    marketWETH.deposit(1 ether, address(this));
    mockOracle.setPrice(marketWETH, 1_000e18);

    market.deposit(10 ether, address(this));
    market.setSmartPoolReserveFactor(0.1e18);
    market.borrow(8.8 ether, address(this), address(this));
    vm.warp(365 days);

    // it doesn't revert because the flexible debt also increases the smart pool assets
    market.borrow(0.1 ether, address(this), address(this));
  }

  function testOperationsShouldUpdateSmartPoolAssetsAverage() external {
    market.deposit(100 ether, address(this));
    uint256 currentSmartPoolAssets = market.smartPoolAssetsAverage();
    assertEq(market.smartPoolAssetsAverage(), 0);
    uint256 previousSmartPoolAssets = currentSmartPoolAssets;

    // SMART POOL WITHDRAW
    vm.warp(1000);
    market.withdraw(1, address(this), address(this));
    currentSmartPoolAssets = market.smartPoolAssetsAverage();
    assertGt(currentSmartPoolAssets, previousSmartPoolAssets);
    previousSmartPoolAssets = currentSmartPoolAssets;

    vm.warp(2000);
    // SMART POOL DEPOSIT (LIQUIDATE SHOULD ALSO UPDATE SP ASSETS AVERAGE)
    market.deposit(1, address(this));
    currentSmartPoolAssets = market.smartPoolAssetsAverage();
    assertGt(currentSmartPoolAssets, previousSmartPoolAssets);
    previousSmartPoolAssets = currentSmartPoolAssets;

    vm.warp(3000);
    // FIXED BORROW
    market.borrowAtMaturity(TSUtils.INTERVAL, 1, 2, address(this), address(this));
    currentSmartPoolAssets = market.smartPoolAssetsAverage();
    assertGt(currentSmartPoolAssets, previousSmartPoolAssets);
    previousSmartPoolAssets = currentSmartPoolAssets;

    vm.warp(4000);
    // EARLY WITHDRAW
    market.depositAtMaturity(TSUtils.INTERVAL, 10, 1, address(this));
    market.withdrawAtMaturity(TSUtils.INTERVAL, 1, 0, address(this), address(this));
    currentSmartPoolAssets = market.smartPoolAssetsAverage();
    assertGt(currentSmartPoolAssets, previousSmartPoolAssets);
    previousSmartPoolAssets = currentSmartPoolAssets;

    vm.warp(5000);
    // FLEXIBLE BORROW DOESN'T UPDATE
    market.borrow(1 ether, address(this), address(this));
    currentSmartPoolAssets = market.smartPoolAssetsAverage();
    assertEq(currentSmartPoolAssets, previousSmartPoolAssets);
    previousSmartPoolAssets = currentSmartPoolAssets;

    vm.warp(6000);
    // FLEXIBLE REPAY DOESN'T UPDATE
    market.repay(1 ether, address(this));
    currentSmartPoolAssets = market.smartPoolAssetsAverage();
    assertEq(currentSmartPoolAssets, previousSmartPoolAssets);
  }

  function testInsufficientProtocolLiquidity() external {
    mockOracle.setPrice(marketWETH, 1_000e18);

    marketWETH.deposit(50 ether, address(this));
    // SMART POOL ASSETS = 100
    market.deposit(100 ether, address(this));
    vm.warp(2);

    // FIXED BORROWS = 51
    market.borrowAtMaturity(TSUtils.INTERVAL, 51 ether, 60 ether, address(this), address(this));

    // WITHDRAWING 50 SHOULD REVERT (LIQUIDITY = 49)
    vm.expectRevert(InsufficientProtocolLiquidity.selector);
    market.withdraw(50 ether, address(this), address(this));

    // SMART POOL ASSETS = 151 & FIXED BORROWS = 51 (LIQUIDITY = 100)
    market.deposit(51 ether, address(this));

    // FLEXIBLE BORROWS = 51 ETHER
    market.borrow(51 ether, address(this), address(this));

    // WITHDRAWING 50 SHOULD REVERT (LIQUIDITY = 49)
    vm.expectRevert(InsufficientProtocolLiquidity.selector);
    market.withdraw(50 ether, address(this), address(this));

    // WITHDRAWING 49 SHOULD NOT REVERT
    market.withdraw(49 ether, address(this), address(this));
  }

  function testMultipleBorrowsForMultipleAssets() external {
    mockInterestRateModel.setBorrowRate(0);
    vm.warp(0);
    Market[4] memory markets;
    for (uint256 i = 0; i < tokens.length; i++) {
      MockERC20 token = new MockERC20(tokens[i], tokens[i], 18);
      markets[i] = new Market(
        token,
        3,
        1e18,
        auditor,
        InterestRateModel(address(mockInterestRateModel)),
        0.02e18 / uint256(1 days),
        1e17,
        0,
        Market.DampSpeed(0.0046e18, 0.42e18)
      );

      auditor.enableMarket(markets[i], 0.8e18, 18);
      token.mint(BOB, 50_000 ether);
      token.mint(address(this), 50_000 ether);
      vm.prank(BOB);
      token.approve(address(markets[i]), type(uint256).max);
      token.approve(address(markets[i]), type(uint256).max);
      markets[i].deposit(30_000 ether, address(this));
    }

    // since 224 is the max amount of consecutive maturities where a user can borrow
    // 221 is the last valid cycle (the last maturity where it borrows is 224)
    for (uint256 m = 0; m < 221; m += 3) {
      vm.warp(TSUtils.INTERVAL * m);
      for (uint256 i = 0; i < markets.length; ++i) {
        for (uint256 j = m + 1; j <= m + 3; ++j) {
          markets[i].borrowAtMaturity(TSUtils.INTERVAL * j, 1 ether, 1.2 ether, address(this), address(this));
        }
      }
    }

    // repay does not increase in cost
    markets[0].repayAtMaturity(TSUtils.INTERVAL, 1 ether, 1000 ether, address(this));
    // withdraw DOES increase in cost
    markets[0].withdraw(1 ether, address(this), address(this));

    // normal operations of another user are not impacted
    vm.prank(BOB);
    markets[0].deposit(100 ether, address(BOB));
    vm.prank(BOB);
    markets[0].withdraw(1 ether, address(BOB), address(BOB));
    vm.prank(BOB);
    vm.warp(TSUtils.INTERVAL * 400);
    markets[0].borrowAtMaturity(TSUtils.INTERVAL * 401, 1 ether, 1.2 ether, address(BOB), address(BOB));

    // liquidate function to user's borrows DOES increase in cost
    vm.prank(BOB);
    markets[0].liquidate(address(this), 1_000 ether, markets[0]);
  }
}

contract MarketHarness is Market {
  constructor(
    ERC20 asset_,
    uint8 maxFuturePools_,
    uint128 accumulatedEarningsSmoothFactor_,
    Auditor auditor_,
    InterestRateModel interestRateModel_,
    uint256 penaltyRate_,
    uint256 smartPoolFeeRate_,
    uint128 smartPoolReserveFactor_,
    DampSpeed memory dampSpeed_
  )
    Market(
      asset_,
      maxFuturePools_,
      accumulatedEarningsSmoothFactor_,
      auditor_,
      interestRateModel_,
      penaltyRate_,
      smartPoolFeeRate_,
      smartPoolReserveFactor_,
      dampSpeed_
    )
  {}

  function setSupply(uint256 supply) external {
    totalSupply = supply;
  }

  function setSmartPoolAssets(uint256 balance) external {
    smartPoolAssets = balance;
  }
}