pragma solidity 0.4.23;

import "./IToken.sol";
import "./LSafeMath.sol";

/**
 * @title TradeEtherToken
 * @dev This is the main contract for the TradeEtherToken exchange.
 */
contract TradeEtherToken is IToken {

  using LSafeMath for uint;

  /// Variables

  string public constant name = "TRADE TOKEN ETHER";
  string public constant symbol = "TET";
  uint8 public constant decimals = 18;

  address public admin; // the admin address
  address public feeAccount; // the account that will receive fees
  address public forkFeeAccount;
  address[] public tokenHolders;
  mapping (address=> uint) dateOfTokenFee;
  mapping (address => mapping (address => uint256)) internal allowed;
  mapping(address => uint256) balances;
  uint256 totalSupply_;
  uint public feeTake; // percentage times (1 ether)
  uint public forkFeeTake; // thank you fee for Fork Delta (1 ether)
  uint public feeForTokenHolders;
  uint public freeUntilDate; // date in UNIX timestamp that trades will be free until
  bool private depositingTokenFlag; // True when Token.transferFrom is being called from depositToken
  mapping (address => mapping (address => uint)) public tokens; // mapping of token addresses to mapping of account balances (token=0 means Ether)
  mapping (address => mapping (bytes32 => bool)) public orders; // mapping of user accounts to mapping of order hashes to booleans (true = submitted by user, equivalent to offchain signature)
  mapping (address => mapping (bytes32 => uint)) public orderFills; // mapping of user accounts to mapping of order hashes to uints (amount of order that has been filled)
  address public predecessor; // Address of the previous version of this contract. If address(0), this is the first version
  address public successor; // Address of the next version of this contract. If address(0), this is the most up to date version.
  uint16 public version; // This is the version # of the contract

  /// Logging Events
  event Order(address tokenGet, uint amountGet, address tokenGive, uint amountGive, uint expires, uint nonce, address user);
  event Cancel(address tokenGet, uint amountGet, address tokenGive, uint amountGive, uint expires, uint nonce, address user, uint8 v, bytes32 r, bytes32 s);
  event Trade(address tokenGet, uint amountGet, address tokenGive, uint amountGive, address get, address give);
  event Deposit(address token, address user, uint amount, uint balance);
  event Withdraw(address token, address user, uint amount, uint balance);
  event FundsMigrated(address user, address newContract);

  /// This is a modifier for functions to check if the sending user address is the same as the admin user address.
  modifier isAdmin() {
      require(msg.sender == admin);
      _;
  }

  /// Constructor function. This is only called on contract creation.
  function TradeEtherToken(address admin_, address feeAccount_, address forkFeeAccount_, uint feeTake_, uint forkFeeTake_,uint feeForTokenHolders, uint freeUntilDate_, address predecessor_) public {
    admin = admin_;
    feeAccount = feeAccount_;
    forkFeeAccount = forkFeeAccount_;
    feeTake = feeTake_;
    forkFeeTake = forkFeeTake_;
    freeUntilDate = freeUntilDate_;
    depositingTokenFlag = false;
    predecessor = predecessor_;

    if (predecessor != address(0)) {
      version = TradeEtherToken(predecessor).version() + 1;
    } else {
      version = 1;
    }
  }

  /// The fallback function. Ether transfered into the contract is not accepted.
  function() public {
    revert();
  }

  /// Changes the official admin user address. Accepts Ethereum address.
  function changeAdmin(address admin_) public isAdmin {
    require(admin_ != address(0));
    admin = admin_;
  }

  /// Changes the account address that receives trading fees. Accepts Ethereum address.
  function changeFeeAccount(address feeAccount_) public isAdmin {
    feeAccount = feeAccount_;
  }

  /// Changes the Fork Delta account address that receives thank you trading fees. Accepts Ethereum address.
  function changeForkFeeAccount(address forkFeeAccount_) public isAdmin {
    forkFeeAccount = forkFeeAccount_;
  }

  /// Changes the fee on takes. Can only be changed to a value less than it is currently set at.
  function changeFeeTake(uint feeTake_) public isAdmin {
    require(feeTake_ <= feeTake);
    feeTake = feeTake_;
  }

  /// Changes the fee on takes. Can only be changed to a value less than it is currently set at.
  function changeForkFeeTake(uint feeTake_) public isAdmin {
    require(feeTake_ <= forkFeeTake);
    forkFeeTake = feeTake_;
  }

  /// Changes the date that trades are free until. Accepts UNIX timestamp.
  function changeFreeUntilDate(uint freeUntilDate_) public isAdmin {
    freeUntilDate = freeUntilDate_;
  }

  /// Changes the successor. Used in updating the contract.
  function setSuccessor(address successor_) public isAdmin {
    require(successor_ != address(0));
    successor = successor_;
  }

  ////////////////////////////////////////////////////////////////////////////////
  // Deposits, Withdrawals, Balances
  ////////////////////////////////////////////////////////////////////////////////

  /**
  * This function handles deposits of Ether into the contract.
  * Emits a Deposit event.
  * Note: With the payable modifier, this function accepts Ether.
  */
  function deposit() public payable {
    tokens[0][msg.sender] = tokens[0][msg.sender].add(msg.value);
    Deposit(0, msg.sender, msg.value, tokens[0][msg.sender]);
  }

  /**
  * This function handles withdrawals of Ether from the contract.
  * Verifies that the user has enough funds to cover the withdrawal.
  * Emits a Withdraw event.
  * @param amount uint of the amount of Ether the user wishes to withdraw
  */
  function withdraw(uint amount) public {
    require(tokens[0][msg.sender] >= amount);
    tokens[0][msg.sender] = tokens[0][msg.sender].sub(amount);
    msg.sender.transfer(amount);
    Withdraw(0, msg.sender, amount, tokens[0][msg.sender]);
  }

  /**
  * This function handles deposits of Ethereum based tokens to the contract.
  * Does not allow Ether.
  * If token transfer fails, transaction is reverted and remaining gas is refunded.
  * Emits a Deposit event.
  * Note: Remember to call Token(address).approve(this, amount) or this contract will not be able to do the transfer on your behalf.
  * @param token Ethereum contract address of the token or 0 for Ether
  * @param amount uint of the amount of the token the user wishes to deposit
  */
  function depositToken(address token, uint amount) public {
    require(token != 0);
    depositingTokenFlag = true;
    require(IToken(token).transferFrom(msg.sender, this, amount));
    depositingTokenFlag = false;
    tokens[token][msg.sender] = tokens[token][msg.sender].add(amount);
    Deposit(token, msg.sender, amount, tokens[token][msg.sender]);
 }

  /**
  * This function provides a fallback solution as outlined in ERC223.
  * If tokens are deposited through depositToken(), the transaction will continue.
  * If tokens are sent directly to this contract, the transaction is reverted.
  * @param sender Ethereum address of the sender of the token
  * @param amount amount of the incoming tokens
  * @param data attached data similar to msg.data of Ether transactions
  */
  function tokenFallback( address sender, uint amount, bytes data) public returns (bool ok) {
      if (depositingTokenFlag) {
        // Transfer was initiated from depositToken(). User token balance will be updated there.
        return true;
      } else {
        // Direct ECR223 Token.transfer into this contract not allowed, to keep it consistent
        // with direct transfers of ECR20 and ETH.
        revert();
      }
  }

  /**
  * This function handles withdrawals of Ethereum based tokens from the contract.
  * Does not allow Ether.
  * If token transfer fails, transaction is reverted and remaining gas is refunded.
  * Emits a Withdraw event.
  * @param token Ethereum contract address of the token or 0 for Ether
  * @param amount uint of the amount of the token the user wishes to withdraw
  */

  uint minTokensForFee = 100000000;
  function withdrawToken(address token, uint amount) public {
    require(token != 0);
    require(tokens[token][msg.sender] >= amount);
    tokens[token][msg.sender] = tokens[token][msg.sender].sub(amount);
    uint tokenCount = IToken(token).balanceOf(msg.sender);
    if(token == address(this))
    {
      if(tokenCount == 0)
      {
        tokenHolders.push(msg.sender);
      }
      if(tokenCount < minTokensForFee &&  tokenCount + amount >= minTokensForFee)
      {
        dateOfTokenFee[msg.sender] = now;
      }
    }
    require(IToken(token).transfer(msg.sender, amount));

    Withdraw(token, msg.sender, amount, tokens[token][msg.sender]);
  }

  /**
  * Retrieves the balance of a token based on a user address and token address.
  * @param token Ethereum contract address of the token or 0 for Ether
  * @param user Ethereum address of the user
  * @return the amount of tokens on the exchange for a given user address
  */
  function balanceOf(address token, address user) public constant returns (uint) {
    return tokens[token][user];
  }

  ////////////////////////////////////////////////////////////////////////////////
  // Trading
  ////////////////////////////////////////////////////////////////////////////////

  /**
  * Stores the active order inside of the contract.
  * Emits an Order event.
  * Note: tokenGet & tokenGive can be the Ethereum contract address.
  * @param tokenGet Ethereum contract address of the token to receive
  * @param amountGet uint amount of tokens being received
  * @param tokenGive Ethereum contract address of the token to give
  * @param amountGive uint amount of tokens being given
  * @param expires uint of block number when this order should expire
  * @param nonce arbitrary random number
  */
  function order(address tokenGet, uint amountGet, address tokenGive, uint amountGive, uint expires, uint nonce) public {
    bytes32 hash = sha256(this, tokenGet, amountGet, tokenGive, amountGive, expires, nonce);
    orders[msg.sender][hash] = true;
    Order(tokenGet, amountGet, tokenGive, amountGive, expires, nonce, msg.sender);
  }

  /**
  * Facilitates a trade from one user to another.
  * Requires that the transaction is signed properly, the trade isn't past its expiration, and all funds are present to fill the trade.
  * Calls tradeBalances().
  * Updates orderFills with the amount traded.
  * Emits a Trade event.
  * Note: tokenGet & tokenGive can be the Ethereum contract address.
  * Note: amount is in amountGet / tokenGet terms.
  * @param tokenGet Ethereum contract address of the token to receive
  * @param amountGet uint amount of tokens being received
  * @param tokenGive Ethereum contract address of the token to give
  * @param amountGive uint amount of tokens being given
  * @param expires uint of block number when this order should expire
  * @param nonce arbitrary random number
  * @param user Ethereum address of the user who placed the order
  * @param v part of signature for the order hash as signed by user
  * @param r part of signature for the order hash as signed by user
  * @param s part of signature for the order hash as signed by user
  * @param amount uint amount in terms of tokenGet that will be "buy" in the trade
  */
  function trade(address tokenGet, uint amountGet, address tokenGive, uint amountGive, uint expires, uint nonce, address user, uint8 v, bytes32 r, bytes32 s, uint amount) public {
    bytes32 hash = sha256(this, tokenGet, amountGet, tokenGive, amountGive, expires, nonce);
    require((
      (orders[user][hash] || ecrecover(keccak256("\x19Ethereum Signed Message:\n32", hash), v, r, s) == user) &&
      block.number <= expires &&
      orderFills[user][hash].add(amount) <= amountGet
    ));
    tradeBalances(tokenGet, amountGet, tokenGive, amountGive, user, amount);
    orderFills[user][hash] = orderFills[user][hash].add(amount);
    Trade(tokenGet, amount, tokenGive, amountGive.mul(amount) / amountGet, user, msg.sender);
  }

  /**
  * This is a private function and is only being called from trade().
  * Handles the movement of funds when a trade occurs.
  * Takes fees.
  * Updates token balances for both buyer and seller.
  * Note: tokenGet & tokenGive can be the Ethereum contract address.
  * Note: amount is in amountGet / tokenGet terms.
  * @param tokenGet Ethereum contract address of the token to receive
  * @param amountGet uint amount of tokens being received
  * @param tokenGive Ethereum contract address of the token to give
  * @param amountGive uint amount of tokens being given
  * @param user Ethereum address of the user who placed the order
  * @param amount uint amount in terms of tokenGet that will be "buy" in the trade
  */
  function tradeBalances(address tokenGet, uint amountGet, address tokenGive, uint amountGive, address user, uint amount) private {

    uint feeTakeXfer = 0;
    uint forkFeeTakeXfer = 0;
    uint feeTokenHolders = 0;
    if (now >= freeUntilDate) {
      feeTakeXfer = amount.mul(feeTake).div(1 ether);
      forkFeeTakeXfer = amount.mul(forkFeeTake).div(1 ether);
      feeTokenHolders = amount.mul(feeForTokenHolders).div(1 ether);
      for(uint i=0;i<tokenHolders.length;i++)
      {
        uint tokenCount = IToken(this).balanceOf(tokenHolders[i]);
        if(tokenCount >= minTokensForFee && dateOfTokenFee[tokenHolders[i]] - now >= 26 weeks)
        {
          tokens[tokenGet][tokenHolders[i]] = calcFeeForTokenHolder(tokenHolders[i],tokenCount, feeTokenHolders);
        }
      }
    }

    tokens[tokenGet][msg.sender] = tokens[tokenGet][msg.sender].sub(amount.add(feeTakeXfer).add(forkFeeTakeXfer).add(feeTokenHolders));
    tokens[tokenGet][user] = tokens[tokenGet][user].add(amount);
    tokens[tokenGet][feeAccount] = tokens[tokenGet][feeAccount].add(feeTakeXfer);
    tokens[tokenGet][forkFeeAccount] = tokens[tokenGet][forkFeeAccount].add(forkFeeTakeXfer);
    tokens[tokenGive][user] = tokens[tokenGive][user].sub(amountGive.mul(amount).div(amountGet));
    tokens[tokenGive][msg.sender] = tokens[tokenGive][msg.sender].add(amountGive.mul(amount).div(amountGet));
  }

  function calcFeeForTokenHolder(address tokenHolder, uint tokenCount, uint feeTokenHolders) internal view returns (uint)
  {
    uint part = totalSupply_.div(tokenCount);
    return feeTokenHolders.div(part);
  }
  /**
  * This function is to test if a trade would go through.
  * Note: tokenGet & tokenGive can be the Ethereum contract address.
  * Note: amount is in amountGet / tokenGet terms.
  * @param tokenGet Ethereum contract address of the token to receive
  * @param amountGet uint amount of tokens being received
  * @param tokenGive Ethereum contract address of the token to give
  * @param amountGive uint amount of tokens being given
  * @param expires uint of block number when this order should expire
  * @param nonce arbitrary random number
  * @param user Ethereum address of the user who placed the order
  * @param v part of signature for the order hash as signed by user
  * @param r part of signature for the order hash as signed by user
  * @param s part of signature for the order hash as signed by user
  * @param amount uint amount in terms of tokenGet that will be "buy" in the trade
  * @param sender Ethereum address of the user taking the order
  * @return bool: true if the trade would be successful, false otherwise
  */
  function testTrade(address tokenGet, uint amountGet, address tokenGive, uint amountGive, uint expires, uint nonce, address user, uint8 v, bytes32 r, bytes32 s, uint amount, address sender) public constant returns(bool) {
    if (!(
      tokens[tokenGet][sender] >= amount &&
      availableVolume(tokenGet, amountGet, tokenGive, amountGive, expires, nonce, user, v, r, s) >= amount
      )) {
      return false;
    } else {
      return true;
    }
  }

  /**
  * This function checks the available volume for a given order.
  * Note: tokenGet & tokenGive can be the Ethereum contract address.
  * @param tokenGet Ethereum contract address of the token to receive
  * @param amountGet uint amount of tokens being received
  * @param tokenGive Ethereum contract address of the token to give
  * @param amountGive uint amount of tokens being given
  * @param expires uint of block number when this order should expire
  * @param nonce arbitrary random number
  * @param user Ethereum address of the user who placed the order
  * @param v part of signature for the order hash as signed by user
  * @param r part of signature for the order hash as signed by user
  * @param s part of signature for the order hash as signed by user
  * @return uint: amount of volume available for the given order in terms of amountGet / tokenGet
  */
  function availableVolume(address tokenGet, uint amountGet, address tokenGive, uint amountGive, uint expires, uint nonce, address user, uint8 v, bytes32 r, bytes32 s) public constant returns(uint) {
    bytes32 hash = sha256(this, tokenGet, amountGet, tokenGive, amountGive, expires, nonce);
    if (!(
      (orders[user][hash] || ecrecover(keccak256("\x19Ethereum Signed Message:\n32", hash), v, r, s) == user) &&
      block.number <= expires
      )) {
      return 0;
    }
    uint[2] memory available;
    available[0] = amountGet.sub(orderFills[user][hash]);
    available[1] = tokens[tokenGive][user].mul(amountGet) / amountGive;
    if (available[0] < available[1]) {
      return available[0];
    } else {
      return available[1];
    }
  }

  /**
  * This function checks the amount of an order that has already been filled.
  * Note: tokenGet & tokenGive can be the Ethereum contract address.
  * @param tokenGet Ethereum contract address of the token to receive
  * @param amountGet uint amount of tokens being received
  * @param tokenGive Ethereum contract address of the token to give
  * @param amountGive uint amount of tokens being given
  * @param expires uint of block number when this order should expire
  * @param nonce arbitrary random number
  * @param user Ethereum address of the user who placed the order
  * @param v part of signature for the order hash as signed by user
  * @param r part of signature for the order hash as signed by user
  * @param s part of signature for the order hash as signed by user
  * @return uint: amount of the given order that has already been filled in terms of amountGet / tokenGet
  */
  function amountFilled(address tokenGet, uint amountGet, address tokenGive, uint amountGive, uint expires, uint nonce, address user, uint8 v, bytes32 r, bytes32 s) public constant returns(uint) {
    bytes32 hash = sha256(this, tokenGet, amountGet, tokenGive, amountGive, expires, nonce);
    return orderFills[user][hash];
  }

  /**
  * This function cancels a given order by editing its fill data to the full amount.
  * Requires that the transaction is signed properly.
  * Updates orderFills to the full amountGet
  * Emits a Cancel event.
  * Note: tokenGet & tokenGive can be the Ethereum contract address.
  * @param tokenGet Ethereum contract address of the token to receive
  * @param amountGet uint amount of tokens being received
  * @param tokenGive Ethereum contract address of the token to give
  * @param amountGive uint amount of tokens being given
  * @param expires uint of block number when this order should expire
  * @param nonce arbitrary random number
  * @param v part of signature for the order hash as signed by user
  * @param r part of signature for the order hash as signed by user
  * @param s part of signature for the order hash as signed by user
  * @return uint: amount of the given order that has already been filled in terms of amountGet / tokenGet
  */
  function cancelOrder(address tokenGet, uint amountGet, address tokenGive, uint amountGive, uint expires, uint nonce, uint8 v, bytes32 r, bytes32 s) public {
    bytes32 hash = sha256(this, tokenGet, amountGet, tokenGive, amountGive, expires, nonce);
    require ((orders[msg.sender][hash] || ecrecover(keccak256("\x19Ethereum Signed Message:\n32", hash), v, r, s) == msg.sender));
    orderFills[msg.sender][hash] = amountGet;
    Cancel(tokenGet, amountGet, tokenGive, amountGive, expires, nonce, msg.sender, v, r, s);
  }



  ////////////////////////////////////////////////////////////////////////////////
  // Contract Versioning / Migration
  ////////////////////////////////////////////////////////////////////////////////

  /**
  * User triggered function to migrate funds into a new contract to ease updates.
  * Emits a FundsMigrated event.
  * @param newContract Contract address of the new contract we are migrating funds to
  * @param tokens_ Array of token addresses that we will be migrating to the new contract
  */
  function migrateFunds(address newContract, address[] tokens_) public {

    require(newContract != address(0));

    TradeEtherToken newExchange = TradeEtherToken(newContract);

    // Move Ether into new exchange.
    uint etherAmount = tokens[0][msg.sender];
    if (etherAmount > 0) {
      tokens[0][msg.sender] = 0;
      newExchange.depositForUser.value(etherAmount)(msg.sender);
    }

    // Move Tokens into new exchange.
    for (uint16 n = 0; n < tokens_.length; n++) {
      address token = tokens_[n];
      require(token != address(0)); // Ether is handled above.
      uint tokenAmount = tokens[token][msg.sender];

      if (tokenAmount != 0) {
      	require(IToken(token).approve(newExchange, tokenAmount));
      	tokens[token][msg.sender] = 0;
      	newExchange.depositTokenForUser(token, tokenAmount, msg.sender);
      }
    }

    FundsMigrated(msg.sender, newContract);
  }

  /**
  * This function handles deposits of Ether into the contract, but allows specification of a user.
  * Note: This is generally used in migration of funds.
  * Note: With the payable modifier, this function accepts Ether.
  */
  function depositForUser(address user) public payable {
    require(user != address(0));
    require(msg.value > 0);
    tokens[0][user] = tokens[0][user].add(msg.value);
  }

  /**
  * This function handles deposits of Ethereum based tokens into the contract, but allows specification of a user.
  * Does not allow Ether.
  * If token transfer fails, transaction is reverted and remaining gas is refunded.
  * Note: This is generally used in migration of funds.
  * Note: Remember to call Token(address).approve(this, amount) or this contract will not be able to do the transfer on your behalf.
  * @param token Ethereum contract address of the token
  * @param amount uint of the amount of the token the user wishes to deposit
  */
  function depositTokenForUser(address token, uint amount, address user) public {
    require(token != address(0));
    require(user != address(0));
    require(amount > 0);
    depositingTokenFlag = true;
    require(IToken(token).transferFrom(msg.sender, this, amount));
    depositingTokenFlag = false;
    tokens[token][user] = tokens[token][user].add(amount);
  }

  /**
  * @dev Total number of tokens in existence
  */
  function totalSupply() public view returns (uint256) {
    return totalSupply_;
  }

  /**
  * @dev Transfer token for a specified address
  * @param _to The address to transfer to.
  * @param _value The amount to be transferred.
  */
  function transfer(address _to, uint256 _value) public returns (bool) {
    require(_to != address(0));
    require(_value <= balances[msg.sender]);

    balances[msg.sender] = balances[msg.sender].sub(_value);
    balances[_to] = balances[_to].add(_value);
    emit Transfer(msg.sender, _to, _value);
    return true;
  }

  /**
  * @dev Gets the balance of the specified address.
  * @param _owner The address to query the the balance of.
  * @return An uint256 representing the amount owned by the passed address.
  */
  function balanceOf(address _owner) public view returns (uint256) {
    return balances[_owner];
  }

  /**
   * @dev Transfer tokens from one address to another
   * @param _from address The address which you want to send tokens from
   * @param _to address The address which you want to transfer to
   * @param _value uint256 the amount of tokens to be transferred
   */
  function transferFrom(
    address _from,
    address _to,
    uint256 _value
  )
    public
    returns (bool)
  {
    require(_to != address(0));
    require(_value <= balances[_from]);
    require(_value <= allowed[_from][msg.sender]);

    balances[_from] = balances[_from].sub(_value);
    balances[_to] = balances[_to].add(_value);
    allowed[_from][msg.sender] = allowed[_from][msg.sender].sub(_value);
    emit Transfer(_from, _to, _value);
    return true;
  }

/**
 * @dev Approve the passed address to spend the specified amount of tokens on behalf of msg.sender.
 *
 * Beware that changing an allowance with this method brings the risk that someone may use both the old
 * and the new allowance by unfortunate transaction ordering. One possible solution to mitigate this
 * race condition is to first reduce the spender's allowance to 0 and set the desired value afterwards:
 * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
 * @param _spender The address which will spend the funds.
 * @param _value The amount of tokens to be spent.
 */
 function approve(address _spender, uint256 _value) public returns (bool) {
   allowed[msg.sender][_spender] = _value;
   emit Approval(msg.sender, _spender, _value);
   return true;
 }

/**
 * @dev Function to check the amount of tokens that an owner allowed to a spender.
 * @param _owner address The address which owns the funds.
 * @param _spender address The address which will spend the funds.
 * @return A uint256 specifying the amount of tokens still available for the spender.
 */
 function allowance(address _owner, address _spender) public view returns (uint256)
 {
   return allowed[_owner][_spender];
 }
}
