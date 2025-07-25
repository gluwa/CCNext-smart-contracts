// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICreditcoinPublicProver, ResultSegment} from "@gluwa/creditcoin-public-prover/contracts/sol/Prover.sol";

contract CreditScore {
    // LoanFundInitiated(bytes32,address,address,uint256)
    bytes32 public constant FUND_LOAN_SELECTOR = 0xa1c86ab2ab7ae6485c68325a433de4a6c7f4bca1f08e39b6f472e966186009a3;
    // LoanRepaid(bytes32,address,uint256)
    bytes32 public constant REPAY_LOAN_SELECTOR = 0xa4513463869a9bb2a04ca9d0887721a32388ebe4ade85f8743261b3214b6d65b;
    // LoanLateRepayment(bytes32,address)
    bytes32 public constant LATE_REPAYMENT_SELECTOR = 0xb0d80134f4ded447f10109fd780b197cb9d2acd76570ec652dd08dccd2edb374;
    // LoanExpired(bytes32,uint256,uint256)
    bytes32 public constant EXPIRED_LOAN_SELECTOR = 0xb984513986e8897ae6977834a755925f5f09bed360746d95df469fed6f2f0fa5;

    event CreditScoreUpdated(address indexed , uint256 oldScore, uint256 newScore);
    // keccak256(abi.encode(uint256(keccak256("creditScore.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_LOCATION = 
        0x28db5ee85ba713f49cfd87f72c6df4da054218ab21d25ae61bab3f1cde4f7c8f;

    struct CreditScoreStorage {
        mapping(address => uint256) creditScore;
        mapping(bytes32 => bool) usedQueryId;
    }

    function _getCreditScoreStorage()
        private
        pure
        returns (CreditScoreStorage storage $)
    {
        assembly {
            $.slot := STORAGE_LOCATION
        }
    }

    function getCreditScore(address borrower) public view returns (uint256) {
        CreditScoreStorage storage $ = _getCreditScoreStorage();
        return $.creditScore[borrower];
    }

    /* 
       score range: 300-900
       action 0: initial score when fund loan
       action 1: add 1 point when repay loan
       action 2: deduct 1 point when late repay loan
       action 3: deduct 2 point when loan expired
    */ 
    function _updateCreditScore(address user, uint8 action) private {
        CreditScoreStorage storage $ = _getCreditScoreStorage();
        uint256 oldScore = $.creditScore[user];
        if (action == 0 && $.creditScore[user] == 0) {
            $.creditScore[user] = 300;
        } else if (action == 1 && $.creditScore[user] < 900) {
            $.creditScore[user] += 1;
        } else if (action == 2 && $.creditScore[user] > 300) {
            $.creditScore[user] -= 1;
        } else if (action == 3 && $.creditScore[user] > 300) {
            $.creditScore[user] = $.creditScore[user] > 301 ? $.creditScore[user] - 2 : 300;
        }
        emit CreditScoreUpdated(user, oldScore, $.creditScore[user]);
    }

    function verifyQueryResult(address proverContract, bytes32 queryId) external {
        CreditScoreStorage storage $ = _getCreditScoreStorage();
        if($.usedQueryId[queryId]) {
            revert("CreditScore: Query ID already used");
        }
        ICreditcoinPublicProver prover = ICreditcoinPublicProver(proverContract);
        ResultSegment[] memory resultSegments = prover.getQueryDetails(queryId).resultSegments;
        bytes32 functionSignature = resultSegments[4].abiBytes;
        uint8 action;
        address borrower;
        if(functionSignature == FUND_LOAN_SELECTOR) {
            borrower = address(
                uint160(uint256(bytes32(resultSegments[9].abiBytes)))
            );
            action = 0;
        } else if(functionSignature == REPAY_LOAN_SELECTOR) {
            borrower = address(
                uint160(uint256(bytes32(resultSegments[8].abiBytes)))
            );
            action = 1;
        } else if(functionSignature == LATE_REPAYMENT_SELECTOR) {
            borrower = address(
                uint160(uint256(bytes32(resultSegments[8].abiBytes)))
            );
            action = 2;
        } else if(functionSignature == EXPIRED_LOAN_SELECTOR) {
            borrower = address(
                uint160(uint256(bytes32(resultSegments[6].abiBytes)))
            );
            action = 3;
        } else {
            revert("Loan: Invalid function signature");
        }
        $.usedQueryId[queryId] = true;
        _updateCreditScore(borrower, action);
    }
}