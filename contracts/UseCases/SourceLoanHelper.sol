// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title SourceLoanHelper
/// @notice Source-chain ERC20 fund/repay; emits events proved by `USCLoanReadabilityManager`.
contract SourceLoanHelper is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    event LoanFunded(uint256 indexed loanId);
    event LoanRepaid(uint256 indexed loanId, uint256 amount);

    struct LoanRecord {
        address lender;
        address borrower;
        address token;
        uint256 fundAmount;
        uint256 repayAmount;
        bool funded;
        bool registered;
    }

    mapping(uint256 => LoanRecord) public loans;
    mapping(address => bool) public authorizedTokens;

    constructor(address admin_) Ownable(admin_) {}

    function authorizeToken(address token) external onlyOwner {
        require(token != address(0), "zero address");
        authorizedTokens[token] = true;
    }

    function revokeToken(address token) external onlyOwner {
        authorizedTokens[token] = false;
    }

    function registerLoanFund(
        uint256 loanId,
        address lender,
        address borrower,
        address token,
        uint256 fundAmount,
        uint256 repayAmount
    ) external onlyOwner {
        require(!loans[loanId].registered, "already registered");
        require(lender != address(0) && borrower != address(0), "zero address");
        require(lender != borrower, "lender == borrower");
        require(authorizedTokens[token], "token not authorized");
        require(fundAmount > 0, "fundAmount must be > 0");
        require(repayAmount >= fundAmount, "repayAmount < fundAmount");

        loans[loanId] = LoanRecord({
            lender: lender,
            borrower: borrower,
            token: token,
            fundAmount: fundAmount,
            repayAmount: repayAmount,
            funded: false,
            registered: true
        });
    }

    function fundLoan(uint256 loanId) external nonReentrant {
        LoanRecord storage rec = loans[loanId];
        require(rec.registered, "loan not registered");
        require(!rec.funded, "already funded");
        require(msg.sender == rec.lender, "only lender");

        rec.funded = true;
        IERC20(rec.token).safeTransferFrom(rec.lender, rec.borrower, rec.fundAmount);
        emit LoanFunded(loanId);
    }

    function repayLoan(uint256 loanId, uint256 amount) external nonReentrant {
        LoanRecord storage rec = loans[loanId];
        require(rec.registered, "loan not registered");
        require(rec.funded, "loan not funded yet");
        require(msg.sender == rec.borrower, "only borrower");
        require(amount > 0 && amount <= rec.repayAmount, "invalid amount");

        IERC20(rec.token).safeTransferFrom(rec.borrower, rec.lender, amount);
        emit LoanRepaid(loanId, amount);
    }
}
