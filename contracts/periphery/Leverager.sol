// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { ERC20 } from "solmate/src/tokens/ERC20.sol";
import { SafeTransferLib } from "solmate/src/utils/SafeTransferLib.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { Auditor, MarketNotListed } from "../Auditor.sol";
import { Market, ERC4626 } from "../Market.sol";

/// @title Leverager
/// @notice Contract that leverages and deleverages the floating position of accounts interacting with Exactly Protocol.
contract Leverager {
  using FixedPointMathLib for uint256;
  using SafeTransferLib for ERC20;

  /// @notice Balancer's vault contract that is used to take flash loans.
  IBalancerVault public immutable balancerVault;
  /// @notice Auditor contract that lists the markets that can be leveraged.
  Auditor public immutable auditor;

  constructor(Auditor auditor_, IBalancerVault balancerVault_) {
    auditor = auditor_;
    balancerVault = balancerVault_;
    Market[] memory markets = auditor_.allMarkets();
    for (uint256 i = 0; i < markets.length; i++) {
      markets[i].asset().safeApprove(address(markets[i]), type(uint256).max);
    }
  }

  /// @notice Leverages the floating position of `msg.sender` to match `targetHealthFactor` by taking a flash loan
  /// from Balancer's vault.
  /// @param market The Market to leverage the position in.
  /// @param principal The amount of assets to deposit or deposited.
  /// @param targetHealthFactor The desired target health factor that the account will be leveraged to.
  /// @param deposit True if the principal is being deposited, false if the principal is already deposited.
  function leverage(Market market, uint256 principal, uint256 targetHealthFactor, bool deposit) external {
    ERC20 asset = market.asset();
    if (deposit) asset.safeTransferFrom(msg.sender, address(this), principal);

    (uint256 adjustFactor, , , , ) = auditor.markets(market);
    uint256 factor = adjustFactor.mulWadDown(adjustFactor).divWadDown(targetHealthFactor);

    ERC20[] memory tokens = new ERC20[](1);
    tokens[0] = asset;
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = principal.mulWadDown(factor).divWadDown(1e18 - factor);
    bytes[] memory calls = new bytes[](2);
    calls[0] = abi.encodeCall(ERC4626.deposit, (amounts[0] + (deposit ? principal : 0), msg.sender));
    calls[1] = abi.encodeCall(Market.borrow, (amounts[0], address(balancerVault), msg.sender));

    balancerVault.flashLoan(address(this), tokens, amounts, abi.encode(market, calls));
  }

  /// @notice Deleverages the floating position of `msg.sender` a certain `percentage` by taking a flash loan
  /// from Balancer's vault to repay the borrow.
  /// @param market The Market to deleverage the position out.
  /// @param percentage The percentage of the borrow that will be repaid, represented with 18 decimals.
  function deleverage(Market market, uint256 percentage) external {
    (, , uint256 floatingBorrowShares) = market.accounts(msg.sender);

    ERC20[] memory tokens = new ERC20[](1);
    tokens[0] = market.asset();
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = market.previewRefund(floatingBorrowShares.mulWadDown(percentage));
    bytes[] memory calls = new bytes[](2);
    calls[0] = abi.encodeCall(Market.repay, (amounts[0], msg.sender));
    calls[1] = abi.encodeCall(Market.withdraw, (amounts[0], address(balancerVault), msg.sender));

    balancerVault.flashLoan(address(this), tokens, amounts, abi.encode(market, calls));
  }

  /// @notice Callback function called by the Balancer Vault contract when a flash loan is initiated.
  /// @dev Only the Balancer Vault contract is allowed to call this function.
  /// @param userData Additional data provided by the borrower for the flash loan.
  function receiveFlashLoan(ERC20[] memory, uint256[] memory, uint256[] memory, bytes memory userData) external {
    assert(msg.sender == address(balancerVault));

    (Market market, bytes[] memory calls) = abi.decode(userData, (Market, bytes[]));
    for (uint256 i = 0; i < calls.length; ) {
      (bool success, bytes memory data) = address(market).call(calls[i]);
      if (!success) revert CallError(i, data);
      unchecked {
        ++i;
      }
    }
  }

  /// @notice Returns Balancer Vault's available liquidity of each enabled underlying asset.
  function availableLiquidity() external view returns (AvailableAsset[] memory availableAssets) {
    uint256 marketsCount = auditor.allMarkets().length;
    availableAssets = new AvailableAsset[](marketsCount);

    for (uint256 i = 0; i < marketsCount; i++) {
      ERC20 asset = auditor.marketList(i).asset();
      availableAssets[i] = AvailableAsset({ asset: asset, liquidity: asset.balanceOf(address(balancerVault)) });
    }
  }

  /// @notice Approves the Market to spend the contract's balance of the underlying asset.
  /// @dev The Market must be listed by the Auditor in order to be valid for approval.
  /// @param market The Market to spend the contract's balance.
  function approve(Market market) external {
    (, , , bool isListed, ) = auditor.markets(market);
    if (!isListed) revert MarketNotListed();

    market.asset().safeApprove(address(market), type(uint256).max);
  }

  struct AvailableAsset {
    ERC20 asset;
    uint256 liquidity;
  }
}

error CallError(uint256 callIndex, bytes revertData);

interface IBalancerVault {
  function flashLoan(
    address recipient,
    ERC20[] memory tokens,
    uint256[] memory amounts,
    bytes memory userData
  ) external;
}
