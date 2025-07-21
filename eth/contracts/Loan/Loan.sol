// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
library LoanModel {
    enum LoanState {
        /*0*/
        Active,
        /*1*/
        Funded,
        /*2*/
        Repaid,
        /*3*/
        Expired
    }
    struct LoanTerm {
        uint256 idx;
        address lender;
        address borrower;
        uint32 interestRate;
        uint32 interestRatePercentageBase;
        uint256 principal;
        uint256 creationDate;
        uint256 maturityDate;
        uint256 repaymentDeadline;
        uint256 repaymentDue;
        uint256 totalRepayment;
        bytes borrowerSig;
        bytes lenderSig;
        LoanState state;
    }
}

library HashMapIndex {

    /**
     * @dev Enum to store the states of HashMapping entries
     */
    enum HashState {
        /*0*/
        Invalid,
        /*1*/
        Active,
        /*2*/
        Archived
    }

    /**
     * @dev Efficient storage container for active and archived hashes enabling iteration
     */
    struct HashMapping {
        mapping(bytes32 => HashState) hashState;
        mapping(uint256 => bytes32) itHashMap;
        uint256 firstIdx;
        uint256 nextIdx;
        uint256 count;
    }

    /**
     * @dev Add a new hash to the storage container if it is not yet part of it
     * @param self Struct storage container pointing to itself
     * @param _hash Hash to add to the struct
     */
    function add(HashMapping storage self, bytes32 _hash) internal {
        // Ensure that the hash has not been previously already been added (is still in an invalid state)
        assert(self.hashState[_hash] == HashState.Invalid);
        // Set the state of hash to Active
        self.hashState[_hash] = HashState.Active;
        // Index the hash with the next idx
        self.itHashMap[self.nextIdx] = _hash;
        self.nextIdx++;
        self.count++;
    }

    /**
     * @dev Archives an existing hash if it is an active hash part of the struct
     * @param self Struct storage container pointing to itself
     * @param _hash Hash to archive in the struct
     */
    function archive(HashMapping storage self, bytes32 _hash) internal {
        // Ensure that the state of the hash is active
        assert(self.hashState[_hash] == HashState.Active);
        // Set the State of hash to Archived
        self.hashState[_hash] = HashState.Archived;
        // Reduce the size of the number of active hashes
        self.count--;

        // Check if the first hash in the active list is in an archived state
        if (
            self.hashState[self.itHashMap[self.firstIdx]] == HashState.Archived
        ) {
            self.firstIdx++;
        }

        // Repeat one more time to allowing for 'catch up' of firstIdx;
        // Check if the first hash in the active list is still active or has it already been archived
        if (
            self.hashState[self.itHashMap[self.firstIdx]] == HashState.Archived
        ) {
            self.firstIdx++;
        }
    }

    /**
     * @dev Verifies if the hash provided is a currently active hash and part of the mapping
     * @param self Struct storage container pointing to itself
     * @param _hash Hash to verify
     * @return Indicates if the hash is active (and part of the mapping)
     */
    function isActive(HashMapping storage self, bytes32 _hash)
        internal
        view
        returns (bool)
    {
        return self.hashState[_hash] == HashState.Active;
    }

    /**
     * @dev Verifies if the hash provided is an archived hash and part of the mapping
     * @param self Struct storage container pointing to itself
     * @param _hash Hash to verify
     * @return Indicates if the hash is archived (and part of the mapping)
     */
    function isArchived(HashMapping storage self, bytes32 _hash)
        internal
        view
        returns (bool)
    {
        return self.hashState[_hash] == HashState.Archived;
    }

    /**
     * @dev Verifies if the hash provided is either an active or archived hash and part of the mapping
     * @param self Struct storage container pointing to itself
     * @param _hash Hash to verify
     * @return Indicates if the hash is either active or archived (part of the mapping)
     */
    function isValid(HashMapping storage self, bytes32 _hash)
        internal
        view
        returns (bool)
    {
        return self.hashState[_hash] != HashState.Invalid;
    }

    /**
     * @dev Retrieve the specified (_idx) hash from the struct
     * @param self Struct storage container pointing to itself
     * @param _idx Index of the hash to retrieve
     * @return Hash specified by the _idx value (returns 0x0 if _idx is an invalid index)
     */
    function get(HashMapping storage self, uint256 _idx)
        internal
        view
        returns (bytes32)
    {
        return self.itHashMap[_idx];
    }
}

interface ILoan {
    event LoanTermCreated(bytes32 indexed loanHash, address indexed lender, address indexed borrower, uint256 principal, uint32 interestRate, uint32 interestRatePercentageBase, uint256 maturityTerm, uint256 repaymentDeadline);
    event LoanFundInitiated(bytes32 indexed loanHash, address indexed lender, address indexed borrower, uint256 amount);
    event LoanRepaid(bytes32 indexed loanHash, address indexed borrower, uint256 amount);
    event LoanPartiallyRepaid(bytes32 indexed loanHash, address indexed borrower, address indexed lender, uint256 repayAmount, uint256 remainingAmount);
    event LoanExpired(bytes32 indexed loanHash, address indexed borrower);
    event LoanLateRepayment(bytes32 indexed loanHash, address indexed borrower);
}

contract Loan is ILoan {
    using HashMapIndex for HashMapIndex.HashMapping;
    using ECDSA for bytes32;
    uint256 public constant LOAN_EXPIRED_TIME = 30 minutes;
    // keccak256(abi.encode(uint256(keccak256("loan.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_LOCATION = 0x5c1f313428252390f87006a4ad2f9ff7dab4057d66066b76617f306a39940ffa;
    IERC20 public immutable erc20;

    constructor(address _erc20) {
        erc20 = IERC20(_erc20);
    }

    struct LoanStorage {
        HashMapIndex.HashMapping accountIndex;
        HashMapIndex.HashMapping loanIndex;
        HashMapIndex.HashMapping fundedLoanIndex;
        mapping(address => bytes32) addressLoanMapping;
        mapping(bytes32 => LoanModel.LoanTerm) loanTermStorage;
        mapping(address => bool) borrowerRegistry;
        mapping(address => bool) lenderRegistry;
        mapping(address => mapping(bytes32 => bool)) usedQueryId;
    }

    function _getLoanStorage()
        private
        pure
        returns (LoanStorage storage $)
    {
        assembly {
            $.slot := STORAGE_LOCATION
        }
    }
        
    modifier isLoanParty(bytes32 loanTermHash) {
        LoanStorage storage $ = _getLoanStorage();
        require(
            $.loanTermStorage[loanTermHash].lender == msg.sender || 
            $.loanTermStorage[loanTermHash].borrower == msg.sender,
            "Loan: Not a party to this loan"
        );
        _;
    }

    modifier loanStateIs(bytes32 loanTermHash, LoanModel.LoanState state) {
        LoanStorage storage $ = _getLoanStorage();
        require(
            $.loanTermStorage[loanTermHash].state == state,
            "Loan: Invalid loan state"
        );
        _;
    }

    function getLoanTerm(bytes32 loanTermHash)
        external
        view
        returns (LoanModel.LoanTerm memory)
    {
        LoanStorage storage $ = _getLoanStorage();
        return $.loanTermStorage[loanTermHash];
    }

    function _calculateYield(
        uint64 term,
        uint32 interestRate,
        uint32 interestRatePercentageBase,
        uint256 amount
    ) private pure returns (uint256) {
        unchecked {
            // Break down the calculation to avoid overflow
            // First calculate the interest portion
            uint256 interestPortion = (amount * interestRate) / interestRatePercentageBase;
            
            // Then calculate the time portion
            uint256 timePortion = (interestPortion * term) / 31536000;
            
            return timePortion;
        }
    }

    /**
     * @notice return loanTermHash without creating a loan term, allow both lender and borrower to sign
     * @param lender The lender of the loan
     * @param borrower The borrower of the loan
     * @param principal The principal of the loan
     * @param interestRate The interest rate of the loan
     * @param interestRatePercentageBase The interest rate percentage base of the loan
     * @param maturityTerm The maturity term of the loan
     * @param repaymentDeadline The repayment deadline of the loan
     */
    function predictLoanTermHash(
        address lender,
        address borrower,
        uint256 principal,
        uint32 interestRate,
        uint32 interestRatePercentageBase,
        uint256 maturityTerm,
        uint256 repaymentDeadline
    ) public view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                address(this),
                lender,
                borrower,
                principal,
                interestRate,
                interestRatePercentageBase,
                maturityTerm,
                repaymentDeadline
            )
        );
    }

    /**
     * @notice creates a loan term
     * @param lender The lender of the loan
     * @param borrower The borrower of the loan
     * @param principal The principal of the loan
     * @param interestRate The interest rate of the loan
     * @param interestRatePercentageBase The interest rate percentage base of the loan
     * @param maturityTerm The maturity term of the loan
     * @param repaymentDeadline The repayment deadline of the loan
     */
    function createLoanTerm(
        address lender,
        address borrower,
        uint256 principal,
        uint32 interestRate,
        uint32 interestRatePercentageBase,
        uint256 maturityTerm,
        uint256 repaymentDeadline,
        bytes memory lenderSig,
        bytes memory borrowerSig
    ) external returns (bytes32) {
        LoanStorage storage $ = _getLoanStorage();
        require(principal > 0, "Loan createLoanTerm: Amount must be greater than 0");
        require(
            interestRate > 0 && interestRatePercentageBase >= interestRate,
            "Loan createLoanTerm: Invalid interest rate"
        );
        require(maturityTerm > 0, "Loan createLoanTerm: Maturity term must be greater than 0");
        require(lender != address(0), "Loan createLoanTerm: Invalid lender address");
        require(borrower != address(0), "Loan createLoanTerm: Invalid borrower address");
        require(lender != borrower, "Loan createLoanTerm: Lender cannot be borrower");

        bytes32 loanTermHash = predictLoanTermHash(lender, borrower, principal, interestRate, interestRatePercentageBase, maturityTerm, repaymentDeadline);
        _verifyLoanSignature(loanTermHash, lender, borrower, lenderSig, borrowerSig);
        uint256 startDate = block.timestamp;
        $.loanTermStorage[loanTermHash] = LoanModel.LoanTerm({
            idx: $.loanIndex.nextIdx,
            lender: lender,
            borrower: borrower,
            interestRate: interestRate,
            interestRatePercentageBase: interestRatePercentageBase,
            creationDate: startDate,
            maturityDate: startDate + maturityTerm,
            repaymentDeadline: repaymentDeadline,
            repaymentDue:  principal + _calculateYield(
                uint64(maturityTerm),
                interestRate,
                interestRatePercentageBase,
                principal
            ),
            principal: principal,
            totalRepayment: 0,
            borrowerSig: borrowerSig,
            lenderSig: lenderSig,
            state: LoanModel.LoanState.Active
        });

        // Register lender and borrower
        $.lenderRegistry[lender] = true;
        $.borrowerRegistry[borrower] = true;

        $.loanIndex.add(loanTermHash);
        emit LoanTermCreated(
            loanTermHash,
            lender,
            borrower,
            principal,
            interestRate,
            interestRatePercentageBase,
            maturityTerm,
            repaymentDeadline
        );

        return loanTermHash;
    }

    function _verifyLoanSignature(bytes32 loanTermHash, address lender, address borrower, bytes memory lenderSig, bytes memory borrowerSig) private pure {
        bytes32 messageHash = keccak256(
            abi.encodePacked(
                "\x19Ethereum Signed Message:\n32",
                loanTermHash
            )
        );
        address signer = messageHash.recover(lenderSig);
        address signer2 = messageHash.recover(borrowerSig);
        require(signer == lender, "Loan: Invalid lender signature");
        require(signer2 == borrower, "Loan: Invalid borrower signature");
    }

    function fundLoan(bytes32 loanTermHash) 
        external
        loanStateIs(loanTermHash, LoanModel.LoanState.Active) 
    {
        checkExpiredLoans();
        LoanStorage storage $ = _getLoanStorage();
        LoanModel.LoanTerm storage loanTerm = $.loanTermStorage[loanTermHash];
        require(loanTerm.lender == msg.sender, "Loan: Not a lender for this loanTerm");
        require(loanTerm.borrower != address(0), "Loan: No borrower for this loanTerm");
        require(erc20.transferFrom(loanTerm.lender, loanTerm.borrower, loanTerm.principal), "Loan: Transfer failed");
        loanTerm.state = LoanModel.LoanState.Funded;
        $.fundedLoanIndex.add(loanTermHash);
        emit LoanFundInitiated(loanTermHash, loanTerm.lender, loanTerm.borrower, loanTerm.principal);
    }

    function repay(bytes32 loanTermHash) 
        external
        loanStateIs(loanTermHash, LoanModel.LoanState.Funded)
    {
        checkExpiredLoans();
        LoanStorage storage $ = _getLoanStorage();
        LoanModel.LoanTerm storage loanTerm = $.loanTermStorage[loanTermHash];
        if(loanTerm.state == LoanModel.LoanState.Expired) return;
        require(loanTerm.borrower == msg.sender, "Loan: Not a borrower for this loanTerm");
        _processRepayment($, loanTermHash, loanTerm, loanTerm.repaymentDue - loanTerm.totalRepayment);
    }

    function partialRepay(bytes32 loanTermHash, uint256 repayAmount) 
        external
        loanStateIs(loanTermHash, LoanModel.LoanState.Funded)
    {
        checkExpiredLoans();
        LoanStorage storage $ = _getLoanStorage();
        LoanModel.LoanTerm storage loanTerm = $.loanTermStorage[loanTermHash];
        if(loanTerm.state == LoanModel.LoanState.Expired) return;
        require(repayAmount > 0, "Loan: Repay amount must be greater than 0");
        require(repayAmount <= loanTerm.repaymentDue - loanTerm.totalRepayment, "Loan: Repay amount exceeds remaining amount");
        require(loanTerm.borrower == msg.sender, "Loan: Not a borrower for this loanTerm");
        _processRepayment($, loanTermHash, loanTerm, repayAmount);
    }

    function _processRepayment(
        LoanStorage storage $,
        bytes32 loanTermHash,
        LoanModel.LoanTerm storage loanTerm,
        uint256 repayAmount
    ) private {
        uint256 remainingAmount = loanTerm.repaymentDue - loanTerm.totalRepayment;
        require(repayAmount <= remainingAmount, "Repay amount exceeds remaining amount");
        require(erc20.transferFrom(msg.sender, loanTerm.lender, repayAmount), "Loan: Transfer failed");
        if(block.timestamp > loanTerm.repaymentDeadline) {
            emit LoanLateRepayment(loanTermHash, loanTerm.borrower);
        }
        loanTerm.totalRepayment += repayAmount;
        if (loanTerm.totalRepayment == loanTerm.repaymentDue) {
            loanTerm.state = LoanModel.LoanState.Repaid;
            $.fundedLoanIndex.archive(loanTermHash);
            emit LoanRepaid(loanTermHash, loanTerm.borrower, remainingAmount);
        }
    }

    function checkExpiredLoans() public {
        LoanStorage storage $ = _getLoanStorage();
        uint256 currentTimestamp = block.timestamp;
        
        for (uint256 i = $.fundedLoanIndex.firstIdx; i < $.fundedLoanIndex.nextIdx; i++) {
            bytes32 loanHash = $.fundedLoanIndex.get(i);
            LoanModel.LoanTerm storage loanTerm = $.loanTermStorage[loanHash];
            
            if (loanTerm.state == LoanModel.LoanState.Funded && currentTimestamp > loanTerm.repaymentDeadline + LOAN_EXPIRED_TIME) {
                loanTerm.state = LoanModel.LoanState.Expired;
                $.fundedLoanIndex.archive(loanHash);
                emit LoanExpired(loanHash, loanTerm.borrower);
            }
        }
    }

}