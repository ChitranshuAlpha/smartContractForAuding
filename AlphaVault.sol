// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "hardhat/console.sol";

interface IWETH is IERC20 {
    function deposit() external payable;

    function withdraw(uint256 wad) external;
}

contract AlphaVaultSwap is Ownable {
    // AlphaVault custom events
    event WithdrawTokens(IERC20 buyToken, uint256 boughtAmount_);
    event EtherBalanceChange(uint256 wethBal_);
    event BadRequest(uint256 wethBal_, uint256 reqAmount_);
    event ZeroXCallSuccess(bool status, uint256 initialBuyTokenBalance);
    event buyTokenBought(uint256 buTokenAmount);
    event feePercentageChange(uint256 feePercentage);
    event maxTransactionsChange(uint256 maxTransactions);

    /**
     * @dev Event to notify if transfer successful or failed
     * after account approval verified
     */
    event TransferSuccessful(
        address indexed from_,
        address indexed to_,
        uint256 amount_
    );

    // event TransferFailed(
    //     address indexed from_,
    //     address indexed to_,
    //     uint256 amount_
    // );

    // The WETH contract.
    IWETH public immutable WETH;
    IERC20 ERC20Interface;

    uint256 public maxTransactions;
    uint256 public feePercentage;
    address private destination;

    constructor(){
        WETH = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
        maxTransactions = 25;
        feePercentage = 5;
    }

    /**
     * @dev method that handles transfer of ERC20 tokens to other address
     * it assumes the calling address has approved this contract
     * as spender
     * @param amount numbers of token to transfer
     */
    function depositToken(IERC20 sellToken, uint256 amount) private {
        // require(amount > 0);
        // ERC20Interface = IERC20(sellToken);
        
        // if (amount > ERC20Interface.allowance(msg.sender, address(this))) {
        //     emit TransferFailed(msg.sender, address(this), amount);
        //     revert();
        // }

        // bool success = ERC20Interface.transferFrom(msg.sender, address(this), amount);
        require(sellToken.transferFrom(msg.sender, address(this), amount), "SWAP_CALL_FAILED");
        emit TransferSuccessful(msg.sender, address(this), amount);
    }

    function setfeePercentage(uint256 num) external onlyOwner {
        feePercentage = num;
        emit feePercentageChange(feePercentage);
    }

    function setMaxTransactionLimit(uint256 num) external onlyOwner {
        maxTransactions = num;
        emit maxTransactionsChange(maxTransactions);
    }

    function withdrawFee(IERC20 token, uint256 amount) external onlyOwner{
        require(token.transfer(msg.sender, amount));
    }

    // Transfer ETH held by this contrat to the sender/owner.
    function withdrawETH(uint256 amount) external onlyOwner{
        payable(msg.sender).transfer(amount);
    }

    // Payable fallback to allow this contract to receive protocol fee refunds.
    receive() external payable {}

    fallback() external payable {}

    // Transfer tokens held by this contrat to the sender/owner.
    function withdrawToken(IERC20 token, uint256 amount) internal {
        require(token.transfer(msg.sender, amount));
    }

    //Sets destination address to msg.sender
    function setDestination() internal view returns (address) {
        // destination = msg.sender;
        return msg.sender;
    }

    // Transfer amount of ETH held by this contrat to the sender.
    function transferEth(uint256 amount, address msgSender) internal {
        payable(msgSender).transfer(amount);
    }


    // Swaps ERC20->ERC20 tokens held by this contract using a 0x-API quote.
    function fillQuote(
        // The `buyTokenAddress` field from the API response.
        IERC20 buyToken,

        IERC20 sellToken,
        // The `allowanceTarget` field from the API response.
        address spender,
        // The `to` field from the API response.
        address payable swapTarget,
        // The `data` field from the API response.
        bytes calldata swapCallData
    ) public payable returns (uint256) {
        require(
            spender != address(0),
            "Please provide a valid address"
        );
        // Track our balance of the buyToken to determine how much we've bought.
        uint256 boughtAmount = buyToken.balanceOf(address(this));
        require(sellToken.approve(spender, type(uint128).max),"144 ERROR");
        (bool success, ) = swapTarget.call{value: 0}(swapCallData);
        emit ZeroXCallSuccess(success, boughtAmount);
        require(success, "SWAP_CALL_FAILED");
        boughtAmount = buyToken.balanceOf(address(this)) - boughtAmount;
        emit buyTokenBought(boughtAmount);
        return boughtAmount;
    }


    /**
     * @param amount numbers of token to transfer  in unit256
     */
    function multiSwap(
        IERC20[] calldata sellToken,
        IERC20[] calldata buyToken,
        address[] calldata spender,
        address payable[] calldata swapTarget,
        bytes[] calldata swapCallData,
        uint256[] memory amount
    ) external payable {
        require(
            sellToken.length <= maxTransactions &&
                sellToken.length == buyToken.length &&
                spender.length == buyToken.length &&
                swapTarget.length == spender.length,
            "Please provide valid data"
        );

        uint256 eth_balance = 0;

        if (msg.value > 0) {
            WETH.deposit{value: msg.value}();
            eth_balance = ((msg.value*100)/(100+feePercentage));
            emit EtherBalanceChange(eth_balance);
        }

        for (uint256 i = 0; i < spender.length; i++) {
            // ETHER & WETH Withdrawl request.
            if (spender[i] == address(0)) {
                if (eth_balance > 0) {
                    if (eth_balance < amount[i]) {
                        emit BadRequest(eth_balance, amount[i]);
                        break;
                    } else {
                        if (amount[i] > 0) {
                            IWETH(WETH).withdraw(amount[i]);
                            eth_balance -= amount[i];
                            transferEth(amount[i], setDestination());
                            emit EtherBalanceChange(eth_balance);
                        }
                        withdrawToken(WETH, eth_balance);
                        eth_balance = 0;
                        emit EtherBalanceChange(eth_balance);
                        emit WithdrawTokens(WETH, eth_balance);
                    }
                }
                break;
            }
            // Condition For using Deposited Ether before using WETH From user balance.
            if (sellToken[i] == WETH) {
                if (sellToken[i] == buyToken[i]) {
                    depositToken(sellToken[i], (amount[i]));
                    eth_balance += ((amount[i]*100)/(100+feePercentage));
                    emit EtherBalanceChange(eth_balance);
                    continue;
                }
                if (eth_balance >= amount[i]) {
                    eth_balance -= amount[i];
                }
                emit EtherBalanceChange(eth_balance);
            } else {
                depositToken(sellToken[i], amount[i]);
            }

            // Variable to store amount of tokens purchased.
            uint256 boughtAmount = fillQuote(
                buyToken[i],
                sellToken[i],
                spender[i],
                swapTarget[i],
                swapCallData[i]
            );
            console.log("bought amount------->",boughtAmount,buyToken[i].balanceOf(address(this)));

            // Codition to check if token for withdrawl is ETHER/WETH
            if (buyToken[i] == WETH) {
                eth_balance += boughtAmount;
                emit EtherBalanceChange(eth_balance);
            } else {
                withdrawToken(buyToken[i], boughtAmount);
                emit WithdrawTokens(buyToken[i], boughtAmount);
            }
        }
    }
}