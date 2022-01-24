// SPDX-License-Identifier: MIT
pragma solidity >=0.6.8;
pragma experimental ABIEncoderV2;

import { ISwappaRouterV1 } from "./ISwappaRouterV1.sol";
import { Ownable } from "./Ownable.sol";
import { ILendingPool, ILendingPoolAddressesProvider, IERC20 } from "./Interfaces.sol";
import { SafeERC20, SafeMath } from "./Libraries.sol";
import { FlashLoanReceiverBase } from "./FlashLoanReceiverBase.sol";

contract LiquidateLoanV2 is FlashLoanReceiverBase, Ownable {

    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    ISwappaRouterV1 public immutable swappa;

    constructor(
        ILendingPoolAddressesProvider _addressProvider,
        ISwappaRouterV1 _swappa
    ) FlashLoanReceiverBase(_addressProvider) public {
        swappa = ISwappaRouterV1(_swappa);
    }

    /**
    Given an asset to liquidate, and the collateral to collect on, and a swap path
    compatible with the given swap router:
    1. initiate a flash swap to receive flash amount of the asset to liquidate
    2. inside flash swap, repay the lending pool, and receive the collateral as Atoken
    3. unwrap Atoken to the first token in the swap path as needed
    4. use the swap path to complete the flash swap
    5. transfer the remainder to the owner
     */
    function liquidate(
        address _assetToLiquidate,
        uint256 _flashAmt,
        address _collateral,
        address _userToLiquidate,
        address[] calldata _swappaPath,
        address[] calldata _swappaPairs,
        bytes[] calldata _swappaExtras
    ) external onlyOwner {
        // sanity check the swappa path
        require(
            _swappaPath.length == 0 ||
            _swappaPath[_swappaPath.length - 1] == _assetToLiquidate,
            "Swappa path does not match the asset to liquidate");

        address receiverAddress = address(this);

        // the various assets to be flashed
        address[] memory assets = new address[](1);
        assets[0] = _assetToLiquidate;

        // the amount to be flashed for each asset
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = _flashAmt;

        // 0 = no debt, 1 = stable, 2 = variable
        uint256[] memory modes = new uint256[](1);
        modes[0] = 0;

        // passing these params to executeOperation so that they can be used to liquidate the loan and perform the swap
        bytes memory params = abi.encode(
            _collateral,
            _userToLiquidate,
            _swappaPath,
            _swappaPairs,
            _swappaExtras);

        LENDING_POOL.flashLoan(
            receiverAddress,
            assets,
            amounts,
            modes,
            // mode is set to 0, no debt will be accrued
            address(this),
            params,
            1989 // my referral code
        );
    }

    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address /* initiator */,
        bytes calldata params
    )
        external
        override
        returns (bool)
    {
        (
            address collateral,
            address userToLiquidate,
            address[] memory swappaPath,
            , // address[] swappaPairs
            // bytes[] swappaExtras
        ) = abi.decode(params, (address, address, address[], address[], bytes[]));

        // liquidate unhealthy loan
        uint256 loanAmount = amounts[0];
        address loanAsset = assets[0];
        uint256 flashloanFee = premiums[0];
        uint256 flashLoanRepayment = loanAmount.add(flashloanFee);

        {
            bool receiveAToken = swappaPath.length != 0 && swappaPath[0] != collateral;
            liquidateLoan(collateral, loanAsset, userToLiquidate, loanAmount, receiveAToken);
        }

        // swap collateral from collateral back to loan asset from flashloan to pay it off
        if (collateral != loanAsset) {
            // require at least the flash loan repayment amount out as a safety
            swapCollateral(flashLoanRepayment, params);
        }

        // Pay to owner the profits
        uint256 profit = IERC20(loanAsset).balanceOf(address(this)).sub(flashLoanRepayment);
        require(IERC20(loanAsset).transfer(owner(), profit), "profit transfer error");

        // Approve the LendingPool contract to *pull* the owed amount + premiums
        require(IERC20(loanAsset).approve(address(LENDING_POOL), flashLoanRepayment), "flash loan repayment error");
        return true;
    }

    function liquidateLoan(address _collateral, address _reserve, address _user, uint256 _amount, bool _receiveAToken) private {
        require(IERC20(_reserve).approve(address(LENDING_POOL), _amount), "liquidate loan approval error");
        LENDING_POOL.liquidationCall(_collateral, _reserve, _user, _amount, _receiveAToken);
    }

    // assumes the balance of the token is on the contract
    function swapCollateral(uint amountOutMin, bytes memory params) private {
        (
            , // address collateral
            , // address userToLiquidate
            address[] memory swappaPath,
            address[] memory swappaPairs,
            bytes[] memory swappaExtras
        ) = abi.decode(params, (address, address, address[], address[], bytes[]));
        IERC20 collateralToken = IERC20(swappaPath[0]);
        uint256 amountToTrade = collateralToken.balanceOf(address(this));

        // grant swap access to your token, swap ALL of the collateral over to the debt asset
        require(collateralToken.approve(address(swappa), amountToTrade), "swap approval error");

        swappa.swapExactInputForOutputWithPrecheck(
            swappaPath,
            swappaPairs,
            swappaExtras,
            amountToTrade,
            amountOutMin,
            address(this),
            block.timestamp + 10
        );
    }
}
