// SPDX-License-Identifier: agpl-3.0
pragma solidity >=0.6.12;

import "./Ownable.sol";
import "./Ubeswap.sol";
import { FlashLoanReceiverBase } from "./FlashLoanReceiverBase.sol";
import { ILendingPool, ILendingPoolAddressesProvider, IERC20 } from "./Interfaces.sol";
import { SafeMath } from "./Libraries.sol";

/*
* A contract that liquidates an aave loan using a flash loan:
*
*   call executeFlashLoans() to begin the liquidation
*
*/
contract LiquidateLoan is FlashLoanReceiverBase, Ownable {

    IUniswapV2Router02 immutable ubeswapV2Router;
    using SafeMath for uint256;

    event ErrorHandled(string stringFailure);

    // intantiate lending pool addresses provider and get lending pool address
    constructor(
        ILendingPoolAddressesProvider _addressProvider, 
        IUniswapV2Router02 _ubeswapV2Router
    ) FlashLoanReceiverBase(_addressProvider) public {
        // instantiate ubeswap router to handle exchange
        ubeswapV2Router = IUniswapV2Router02(address(_ubeswapV2Router));
    }

    /**
        This function is called after your contract has received the flash loaned amount
     */
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
        // collateral  the address of the token that we will be compensated in
        // userToLiquidate - id of the user to liquidate
        (address collateral, address userToLiquidate) = abi.decode(params, (address, address));

        // liquidate unhealthy loan
        uint256 loanAmount = amounts[0];
        address loanAsset = assets[0];
        uint256 flashloanFee = premiums[0];
        uint256 flashLoanRepayment = loanAmount.add(flashloanFee);

        liquidateLoan(collateral, loanAsset, userToLiquidate, loanAmount, false);

        // swap collateral from collateral back to loan asset from flashloan to pay it off
        // require at least the flash loan repayment amount out as a safety
        swapCollateral(collateral, loanAsset, flashLoanRepayment);

        uint256 balance = IERC20(loanAsset).balanceOf(address(this));
        uint256 profit = balance.sub(loanAmount.add(flashloanFee));

        // Pay to owner the profits
        require(profit > 0 , "No profit");
        IERC20(loanAsset).transfer(owner(), profit);

        // Approve the LendingPool contract to *pull* the owed amount + premiums
        IERC20(loanAsset).approve(address(LENDING_POOL), flashLoanRepayment);

        return true;
    }

    function liquidateLoan(address _collateral, address _liquidate_asset, address _userToLiquidate, uint256 _amount, bool _receiveaToken) private {
        require(IERC20(_liquidate_asset).approve(address(LENDING_POOL), _amount), "Approval error");
        LENDING_POOL.liquidationCall(_collateral,_liquidate_asset, _userToLiquidate, _amount, _receiveaToken);
    }


    // assumes the balance of the token is on the contract
    function swapCollateral(address asset_from, address asset_to, uint amountOutMin) private {
        IERC20 asset_fromToken = IERC20(asset_from);
        uint256 amountToTrade;
        uint deadline;

        // Set a small time limit
        deadline = block.timestamp + 10;
        amountToTrade = asset_fromToken.balanceOf(address(this));

        // grant ubeswap access to your token
        asset_fromToken.approve(address(ubeswapV2Router), amountToTrade);

        // use direct swap path for simplicity
        address[] memory swapPath = new address[](2);
        swapPath[0] = asset_from;
        swapPath[1] = asset_to;
        
        // Trade 1: Execute swap from asset_from into designated ERC20 token on ubeswap
        try ubeswapV2Router.swapExactTokensForTokens(
            amountToTrade,
            amountOutMin,
            swapPath,
            address(this),
            deadline
        ){
        }
        catch Error(string memory reason)
        {
            // for debugging, swallow the error
            emit ErrorHandled(reason);
        }
        catch
        {

        }

    }

    /*
    * This function is manually called to commence the flash loans sequence
    * to make executing a liquidation  flexible calculations are done outside of the contract and sent via parameters here
    * _assetToLiquidate - the token address of the asset that will be liquidated
    * _flashAmt - flash loan amount (number of tokens) which is exactly the amount that will be liquidated
    * _collateral - the token address of the collateral. This is the token that will be received after liquidating loans
    * _userToLiquidate - user ID of the loan that will be liquidated
    */
    function executeFlashLoans(address _assetToLiquidate, uint256 _flashAmt, address _collateral, address _userToLiquidate) public onlyOwner {
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

        // mode is set to 0, no debt will be accrued
        address onBehalfOf = address(this);

        // passing these params to executeOperation so that they can be used to liquidate the loan and perform the swap
        bytes memory params = abi.encode(_collateral, _userToLiquidate);
        uint16 referralCode = 0;

        LENDING_POOL.flashLoan(
            receiverAddress,
            assets,
            amounts,
            modes,
            onBehalfOf,
            params,
            referralCode
        );
    }

}
