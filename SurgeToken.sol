//SPDX-License-Identifier: MIT
pragma solidity 0.8.0;

import "./Context.sol";
import "./Ownable.sol";
import "./SafeMath.sol";
import "./Address.sol";
import "./IUniswapV2Router02.sol";
import "./ReentrantGuard.sol";
import "./IERC20.sol";

/**
 * Contract: Surge Token
 * Developed By: Markymark (aka DeFi Mark)
 *
 * Liquidity-less Token, DEX built into Contract
 * Send BNB to contract and it mints Surge Token to your receive Address
 * Sell this token by interacting with contract directly
 * Price is calculated as a ratio between Total Supply and underlying asset in Contract
 *
 */
contract SurgeToken is IERC20, Context, Ownable, ReentrancyGuard {
    
    using SafeMath for uint256;
    using SafeMath for uint8;
    using Address for address;

    // token data
    string public _name = "SurgeToken";
    string public _symbol = "S_Ticker";
    uint8 public _decimals = 0;
    
    // 1 Billion Total Supply
    uint256 _totalSupply = 1 * 10**9;
    
    // balances
    mapping (address => uint256) _balances;
    mapping (address => mapping (address => uint256)) _allowances;

    // Fees
    uint256 public sellFee;
    uint256 public buyFee;
    uint256 public transferFee;
    
    // Emergency Mode Only
    bool public emergencyModeEnabled = false;
    
    // Pegged Asset
    address public _token;
    
    // PCS Router
    IUniswapV2Router02 public router; 

    // Surge Fund Data
    bool public allowFunding = true;
    uint256 public fundingBuySellDenominator = 100;
    uint256 public fundingTransferDenominator = 5;
    address public surgeFund = 0x1e9c841A822D1D1c5764261ab5e26d4067Ca49D9;
    
    // Garbage Collector
    uint256 garbageCollectorThreshold = 10**10;

    // initialize some stuff
    constructor ( address peggedToken, string memory tokenName, string memory tokenSymbol, uint8 tokenDecimals, uint256 _buyFee, uint256 _sellFee, uint256 _transferFee
    ) {
        _token = peggedToken;
        _name = tokenName;
        _symbol = tokenSymbol;
        _decimals = tokenDecimals;
        buyFee = _buyFee;
        sellFee = _sellFee;
        transferFee = _transferFee;
        _balances[address(this)] = _totalSupply;
        router = IUniswapV2Router02(0x10ED43C718714eb63d5aA57B78B54704E256024E);
        emit Transfer(address(0), address(this), _totalSupply);
    }

    function totalSupply() external view override returns (uint256) { return _totalSupply; }
    function balanceOf(address account) public view override returns (uint256) { return _balances[account]; }
    function allowance(address holder, address spender) external view override returns (uint256) { return _allowances[holder][spender]; }
    
    function name() public view returns (string memory) {
        return _name;
    }

    function symbol() public view returns (string memory) {
        return _symbol;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }
  
    /** Transfer Function */
    function transfer(address recipient, uint256 amount) external override returns (bool) {
        return _transferFrom(msg.sender, recipient, amount);
    }

    /** Transfer Function */
    function transferFrom(address sender, address recipient, uint256 amount) external override returns (bool) {
        require(sender == msg.sender);
        return _transferFrom(sender, recipient, amount);
    }
    
    /** Internal Transfer */
    function _transferFrom(address sender, address recipient, uint256 amount) internal returns (bool) {
        // make standard checks
        require(recipient != address(0), "BEP20: transfer to the zero address");
        require(amount > 0, "Transfer amount must be greater than zero");
        // subtract form sender, give to receiver, burn the fee
        uint256 tAmount = amount.mul(transferFee).div(10**2);
        uint256 tax = amount.sub(tAmount);
        // subtract from sender
        _balances[sender] = _balances[sender].sub(amount, "Insufficient Balance");
        // give reduced amount to receiver
        _balances[recipient] = _balances[recipient].add(tAmount);
        // track price change
        uint256 oldPrice = calculatePrice();
        
        if (allowFunding && sender != surgeFund && recipient != surgeFund) {
            // allocate 20% of the tax for Surge Fund
            uint256 allocation = tax.div(fundingTransferDenominator);
            // how much are we removing from total supply
            tax = tax.sub(allocation);
            // allocate funding to Surge Fund
            _balances[surgeFund] = _balances[surgeFund].add(allocation);
            // Emit Donation To Surge Fund
            emit Transfer(sender, surgeFund, allocation);
        }
        // burn the tax
        _totalSupply = _totalSupply.sub(tax);
        // Price difference
        uint256 currentPrice = calculatePrice();
        // Require Current Price >= Last Price
        require(currentPrice >= oldPrice, 'Price Must Rise For Transaction To Conclude');
        // Transfer Event
        emit Transfer(sender, recipient, tAmount);
        // Emit The Price Change
        emit PriceChange(oldPrice, currentPrice);
        return true;
    }
    
    /** Purchases SURGE Tokens and Deposits Them in Sender's Address*/
    function purchase() private nonReentrant returns (bool) {
        // make sure emergency mode is disabled
        require(!emergencyModeEnabled, 'EMERGENCY MODE ENABLED');
        // previous amount of Tokens before we received any
        uint256 prevTokenAmount = IERC20(_token).balanceOf(address(this));
        // buy Tokens with the BNB received
        buyToken(msg.value);
        // balance of tokens after swap
        uint256 currentTokenAmount = IERC20(_token).balanceOf(address(this));
        // number of Tokens we have purchased
        uint256 difference = currentTokenAmount.sub(prevTokenAmount);
        // if this is the first purchase, use new amount
        prevTokenAmount = prevTokenAmount == 0 ? currentTokenAmount : prevTokenAmount;
        // make sure total supply is greater than zero
        uint256 calculatedTotalSupply = _totalSupply == 0 ? _totalSupply.add(1) : _totalSupply;
        // find the number of tokens we should mint to keep up with the current price
        uint256 nShouldPurchase = calculatedTotalSupply.mul(difference).div(prevTokenAmount);
        // apply our spread to tokens to inflate price relative to total supply
        uint256 tokensToSend = nShouldPurchase.mul(buyFee).div(10**2);
        // revert if under 1
        require(tokensToSend > 0, 'Must Purchase At Least One Surge');
        // calculate price change
        uint256 oldPrice = calculatePrice();

        if (allowFunding && msg.sender != surgeFund) {
            // allocate tokens to go to the Surge Fund
            uint256 allocation = tokensToSend.div(fundingBuySellDenominator);
            // the rest go to purchaser
            tokensToSend = tokensToSend.sub(allocation);
            // mint to Fund
            mint(surgeFund, allocation);
            // Tell Blockchain
            emit Transfer(address(this), surgeFund, allocation);
        }
        
        // mint to Buyer
        mint(msg.sender, tokensToSend);
        // Calculate Price After Transaction
        uint256 currentPrice = calculatePrice();
        // Require Current Price >= Last Price
        require(currentPrice >= oldPrice, 'Price Must Rise For Transaction To Conclude');
        // Emit Transfer
        emit Transfer(address(this), msg.sender, tokensToSend);
        // Emit The Price Change
        emit PriceChange(oldPrice, currentPrice);
        return true;
    }
    
    /** Sells SURGE Tokens And Deposits the BNB into Seller's Address */
    function sell(uint256 tokenAmount) public nonReentrant returns (bool) {
        
        // make sure seller has this balance
        require(_balances[msg.sender] >= tokenAmount, 'cannot sell above token amount');
        // calculate the sell fee from this transaction
        uint256 tokensToSwap = tokenAmount.mul(sellFee).div(10**2);
        // subtract full amount from sender
        _balances[msg.sender] = _balances[msg.sender].sub(tokenAmount, 'sender does not have this amount to sell');
        // calculate price change
        uint256 oldPrice = calculatePrice();
        // transaction success
        bool successful;
        // number of underlying asset tokens to claim
        uint256 amountToken;

        if (allowFunding && msg.sender != surgeFund) {
            // allocate percentage to Surge Fund
            uint256 allocation = tokensToSwap.div(fundingBuySellDenominator);
            // subtract allocation from tokensToSwap
            tokensToSwap = tokensToSwap.sub(allocation);
            // burn tokenAmount - allocation
            tokenAmount = tokenAmount.sub(allocation);
            // Allocate Tokens To Surge Fund
            _balances[surgeFund] = _balances[surgeFund].add(allocation);
            // Remove tokens from supply
            _totalSupply = _totalSupply.sub(tokenAmount);
            // Tell Blockchain
            emit Transfer(msg.sender, surgeFund, allocation);
        } else {
            // reduce full amount from supply
            _totalSupply = _totalSupply.sub(tokenAmount);
        }
        
        // how many Tokens are these tokens worth?
        amountToken = tokensToSwap.mul(calculatePrice());
        // send Tokens to Seller
        successful = IERC20(_token).transfer(msg.sender, amountToken);
        // ensure Tokens were delivered
        require(successful, 'Unable to Complete Transfer of Tokens');
        // get current price
        uint256 currentPrice = calculatePrice();
        // Require Current Price >= Last Price
        require(currentPrice >= oldPrice, 'Price Must Rise For Transaction To Conclude');
        // Emit Transfer
        emit Transfer(msg.sender, address(this), tokenAmount);
        // Emit The Price Change
        emit PriceChange(oldPrice, currentPrice);
        return true;
    }
    
    /**
     * Buys Token with BNB, storing in the contract
     */
    function buyToken(uint256 amount) private {
        address[] memory path = new address[](2);
        path[0] = router.WETH();
        path[1] = _token;

        try router.swapExactETHForTokens{value: amount}(
            0,
            path,
            address(this),
            block.timestamp.add(30)
        ) {} catch {revert();}

    }

    /** Returns the Current Price of the Token */
    function calculatePrice() public view returns (uint256) {
        uint256 tokenBalance = IERC20(_token).balanceOf(address(this));
        return tokenBalance.div(_totalSupply);
    }

    /** Calculates the price of this token in relation to its underlying asset */
    function calculatePriceInUnderlyingAsset() public view returns(uint256) {
        return calculatePrice();
    }

    /** Returns the value of your holdings before the sell fee */
    function getValueOfHoldings(address holder) public view returns(uint256) {
        return _balances[holder].mul(calculatePrice());
    }

    /** Returns the value of your holdings after the sell fee */
    function getValueOfHoldingsAfterTax(address holder) public view returns(uint256) {
        uint256 holdings = _balances[holder].mul(calculatePrice());
        return holdings.mul(sellFee).div(10**2);
    }
    
    /** List all fees */
    function getFees() public view returns(uint256, uint256, uint256) {
        return (buyFee,sellFee,transferFee);
    }
    
    /** Allows A User To Erase Their Holdings From Supply */
    function eraseHoldings() external {
        // get balance of caller
        uint256 bal = _balances[msg.sender];
        // require balance is greater than zero
        require(bal > 0, 'cannot erase zero holdings');
        // Track Change In Price
        uint256 oldPrice = calculatePrice();
        // remove tokens from sender
        _balances[msg.sender] = 0;
        // remove tokens from supply
        _totalSupply = _totalSupply.sub(bal, 'total supply cannot be negative');
        // Emit Price Difference
        emit PriceChange(oldPrice, calculatePrice());
        // Emit Call
        emit ErasedHoldings(msg.sender, bal);
    }
    
    /** Fail Safe Incase Withdrawal is Absolutely Necessary, Allowing Users To Withdraw 100% of their asset -- IRREVERSABLE */
    function enableEmergencyMode() external onlyOwner {
        require(!emergencyModeEnabled, 'Emergency Mode Already Enabled');
        // disable fees
        sellFee = 0;
        transferFee = 0;
        buyFee = 0;
        // disable purchases
        emergencyModeEnabled = true;
        // Let Everyone Know
        emit EmergencyModeEnabled();
    }
    
    /** Incase Pancakeswap Upgrades To V3 */
    function changePancakeswapRouterAddress(address newPCSAddress) external onlyOwner {
        router = IUniswapV2Router02(newPCSAddress);
        emit PancakeswapRouterUpdated(newPCSAddress);
    }

    /** Disables The Surge Relief Funds - only to be called once the damages have been repaid */
    function disableFunding() external onlyOwner {
        require(allowFunding, 'Funding already disabled');
        allowFunding = false;
        emit FundingDisabled();
    }
    
    /** Disables The Surge Relief Funds - only to be called once the damages have been repaid */
    function enableFunding() external onlyOwner {
        require(!allowFunding, 'Funding already enabled');
        allowFunding = true;
        emit FundingEnabled();
    }
    
    /** Changes The Fees Associated With Funding */
    function changeFundingValues(uint256 newBuySellDenominator, uint256 newTransferDenominator) external onlyOwner {
        require(newBuySellDenominator >= 80, 'BuySell Tax Too High!!');
        require(newTransferDenominator >= 3, 'Transfer Tax Too High!!');
        fundingBuySellDenominator = newBuySellDenominator;
        fundingTransferDenominator = newTransferDenominator;
        emit FundingValuesChanged(newBuySellDenominator, newTransferDenominator);
    }

    /** Change The Address For The Charity or Fund That Surge Allocates Funding Tax To */
    function swapFundAddress(address newFundReceiver) external onlyOwner {
        surgeFund = newFundReceiver;
        emit SwappedFundReceiver(newFundReceiver);
    }
    
    /** Updates The Threshold To Trigger The Garbage Collector */
    function changeGarbageCollectorThreshold(uint256 garbageThreshold) external onlyOwner {
        require(garbageThreshold > 0 && garbageThreshold <= 10**12, 'invalid threshold');
        garbageCollectorThreshold = garbageThreshold;
        emit UpdatedGarbageCollectorThreshold(garbageThreshold);
    }
    
    /** Mints Tokens to the Receivers Address */
    function mint(address receiver, uint amount) private {
        _balances[receiver] = _balances[receiver].add(amount);
        _totalSupply = _totalSupply.add(amount);
    }

    /** Make Sure there's no Native Tokens in contract */
    function checkGarbageCollector() internal {
        uint256 bal = _balances[address(this)];
        if (bal >= garbageCollectorThreshold) {
            // Track Change In Price
            uint256 oldPrice = calculatePrice();
            // destroy token balance inside contract
            _balances[address(this)] = 0;
            // remove tokens from supply
            _totalSupply = _totalSupply.sub(bal, 'total supply cannot be negative');
            // Emit Call
            emit GarbageCollected(bal);
            // Emit Price Difference
            emit PriceChange(oldPrice, calculatePrice());
        }
    }
    
    /** Mint Tokens to Buyer */
    receive() external payable {
        checkGarbageCollector();
        purchase();
    }
    
    // EVENTS
    event PriceChange(uint256 previousPrice, uint256 currentPrice);
    event SwappedFundReceiver(address newFundReceiver);
    event PancakeswapRouterUpdated(address newRouter);
    event ErasedHoldings(address who, uint256 amountTokensErased);
    event GarbageCollected(uint256 amountTokensErased);
    event FundingEnabled();
    event FundingDisabled();
    event FundingValuesChanged(uint256 buySellDenominator, uint256 transferDenominator);
    event UpdatedGarbageCollectorThreshold(uint256 newThreshold);
    event EmergencyModeEnabled();
}
