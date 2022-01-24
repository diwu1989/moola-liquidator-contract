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

        // my referral code
        uint16 referralCode = 1989;

        LENDING_POOL.flashLoan(
            receiverAddress,
            assets,
            amounts,
            modes,
            // mode is set to 0, no debt will be accrued
            address(this),
            params,
            referralCode
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
        return true;
    }
}
