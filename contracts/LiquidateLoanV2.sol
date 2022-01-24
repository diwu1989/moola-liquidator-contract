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

    /*
    * This function is manually called to commence the flash loans sequence
    * to make executing a liquidation  flexible calculations are done outside of the contract and sent via parameters here
    * _assetToLiquidate - the token address of the asset that will be liquidated
    * _flashAmt - flash loan amount (number of tokens) which is exactly the amount that will be liquidated
    * _collateral - the token address of the collateral. This is the token that will be received after liquidating loans
    * _userToLiquidate - user ID of the loan that will be liquidated
    * _swappaPath / _swappaPairs / _swappaExtras - the path that swappa will use to swap tokens back to original tokens
    */
    function flashLiquidateWithSwappa(
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

    // LendingPool calls into this in the middle of flashloan
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
        // liquidate unhealthy loan
        uint256 loanAmount = amounts[0];
        address loanAsset = assets[0];
        uint256 flashLoanRepayment = loanAmount.add(premiums[0]);

        (
            address collateral,
            address userToLiquidate,
            address[] memory swappaPath,
            , // address[] swappaPairs
                // bytes[] swappaExtras
        ) = abi.decode(params, (address, address, address[], address[], bytes[]));


        {
            // only receive Atoken if we have been provided a swap path from the Atoken to the debt
            // if no swap path is received, then it means collateral == debt, and we don't want Atoken
            bool receiveAToken = swappaPath.length > 0 && swappaPath[0] != collateral;
            liquidateLoan(collateral, loanAsset, userToLiquidate, loanAmount, receiveAToken);
        }

        // swap collateral to loan asset from flashloan to pay it off, we may have received Atoken
        if (swappaPath.length > 0) {
            // require at least the flash loan repayment amount out as a safety
            swapCollateral(flashLoanRepayment, params);
        } else {
            // the only type of liquidation where we do not need to involve swappa is:
            // - collateral == loan asset
            // - receiveAToken == false
        }

        // Pay to owner the profits
        {
            uint256 profit = IERC20(loanAsset).balanceOf(address(this)).sub(flashLoanRepayment);
            IERC20(loanAsset).safeTransfer(owner(), profit);
        }

        // Approve the LendingPool contract to *pull* the owed amount + premiums
        IERC20(loanAsset).safeApprove(address(LENDING_POOL), flashLoanRepayment);
        return true;
    }

    function liquidateLoan(address _collateral, address _loanAsset, address _user, uint256 _amount, bool _receiveAToken) private {
        // approve the flash loaned loan asset to the lending pool for repayment
        IERC20(_loanAsset).safeApprove(address(LENDING_POOL), _amount);
        LENDING_POOL.liquidationCall(_collateral, _loanAsset, _user, _amount, _receiveAToken);
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
        // read the balance from the first token in the swap path, which may be AToken
        IERC20 collateralOrAToken = IERC20(swappaPath[0]);
        uint256 amountToTrade = collateralOrAToken.balanceOf(address(this));

        // grant swap access to your token, swap ALL of the collateral over to the debt asset
        collateralOrAToken.safeApprove(address(swappa), amountToTrade);

        swappa.swapExactInputForOutputWithPrecheck(
            swappaPath,
            swappaPairs,
            swappaExtras,
            amountToTrade,
            amountOutMin,
            address(this),
            block.timestamp + 1
        );
    }
}
