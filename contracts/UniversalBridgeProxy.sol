// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "@gluwa/creditcoin-public-prover/contracts/sol/Types.sol";
import {Initializable, AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IERC20Mintable} from "./abstract/ERC20Mintable.sol";
import {ICreditcoinPublicProver} from "@gluwa/creditcoin-public-prover/contracts/sol/Prover.sol";
import {DecodeRLP} from "./abstract/DecodeRLP.sol";

contract UniversalBridgeProxy is
    Initializable,
    AccessControlUpgradeable    
{
    struct LockedQuery {
        uint64 approvals;
        address ERC20Address;
        uint64 unlockTime;
        address mintRecipient;
        uint256 amount;
        mapping(address => bool) approvedBy;
    }

    event TokensMinted(
        address indexed token,
        address indexed recipient,
        uint256 amount,
        bytes32 indexed queryId
    );
    event QueryLocked(bytes32 indexed queryId, uint256 unlockTime);
    event QueryApproved(
        bytes32 indexed queryId,
        address indexed approver,
        uint256 approvals
    );

    // keccak256(abi.encode(uint256(keccak256("usc.storage.prover")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ProxyStorageLocation =
        0xf5c2b13d5d6ee9861927a008fb55acc9714edb6cfe1604df008b8bdc9d539100;

    struct ProxyStorage {
        uint64 lockupDuration;
        uint64 approvalThreshold;
        uint128 maxInstantMint;
        mapping(address => mapping(bytes32 => bool)) usedQueryId;
        mapping(address => mapping(bytes32 => LockedQuery)) lockedQueries;
    }

    function _getProxyStorage() private pure returns (ProxyStorage storage $) {
        assembly {
            $.slot := ProxyStorageLocation
        }
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        uint64 lockupDuration_,
        uint64 approvalThreshold_,
        uint128 maxInstantMint_,
        address[] calldata admins
    ) external initializer {
        ProxyStorage storage $ = _getProxyStorage();
        $.maxInstantMint = maxInstantMint_;
        $.lockupDuration = lockupDuration_;
        $.approvalThreshold = approvalThreshold_;
        uint256 length = admins.length;
        for (uint96 i; i < length; ) {
            _grantRole(DEFAULT_ADMIN_ROLE, admins[i]);
            unchecked {
                ++i;
            }
        }
    }

    function lockupDuration() public view virtual returns (uint64) {
        return _getProxyStorage().lockupDuration;
    }

    function setlockupDuration(
        uint64 lockupDuration_
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ProxyStorage storage $ = _getProxyStorage();
        $.lockupDuration = lockupDuration_;
    }

    function approvalThreshold() public view returns (uint64) {
        return _getProxyStorage().approvalThreshold;
    }

    function setApprovalThreshold(
        uint64 threshold
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ProxyStorage storage $ = _getProxyStorage();
        $.approvalThreshold = threshold;
    }

    function maxInstantMint() public view returns (uint128) {
        return _getProxyStorage().maxInstantMint;
    }

    function setMaxInstantMint(
        uint128 maxMint
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ProxyStorage storage $ = _getProxyStorage();
        $.maxInstantMint = maxMint;
    }

    function markQueryUsed(
        address user,
        bytes32 queryId
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _getProxyStorage().usedQueryId[user][queryId] = true;
    }

    function isQueryUsed(
        address user,
        bytes32 queryId
    ) external view returns (bool) {
        return _getProxyStorage().usedQueryId[user][queryId];
    }

    function lockQuery(
        address user,
        bytes32 queryId,
        uint256 amount,
        uint64 unlockTime
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ProxyStorage storage $ = _getProxyStorage();
        $.lockedQueries[user][queryId].amount = amount;
        $.lockedQueries[user][queryId].unlockTime = unlockTime;
    }

    function getLockedQuery(
        address user,
        bytes32 queryId
    ) external view returns (uint256, uint256) {
        LockedQuery storage query = _getProxyStorage().lockedQueries[user][
            queryId
        ];
        return (query.amount, query.unlockTime);
    }

    function setAdmin(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(DEFAULT_ADMIN_ROLE, account);
    }

    function removeAdmin(
        address account
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(DEFAULT_ADMIN_ROLE, account);
    }

    function uscBridgeCompleteMint(
        address proverContractAddr,
        bytes32 queryId,
        address ERC20Address
    ) external {
        ProxyStorage storage $ = _getProxyStorage();
        require(
            !$.usedQueryId[proverContractAddr][queryId],
            "QueryId already used"
        );
        require(
            $.lockedQueries[proverContractAddr][queryId].unlockTime == 0,
            "Query is locked"
        );

        ICreditcoinPublicProver prover = ICreditcoinPublicProver(
            proverContractAddr
        );

        // We only accept queries submitted using admin keys, such as from our own
        // query builder worker. Otherwise there is no guarantee that the result
        // segments provided actually pertain to our protocol. They could be
        // constructed by bad actors to look like an interaction with our mint/burn
        // contract, when in fact they come from some completely unrelated finalized
        // transaction on the source chain.
        QueryDetails memory queryDetails = prover.getQueryDetails(queryId);
        require(hasRole(DEFAULT_ADMIN_ROLE, queryDetails.principal));

        // Result segment availability validated on prover side
       ResultSegment[] memory resultSegments = queryDetails.resultSegments;
        // Result segments for default ERC20 Transfer correspond to these fields:
        // 0: Rx - Status
        // 1: Tx - From
        // 2: Tx - To (contract addr)
        // 3: Event - Addr (contract emitting event) 
        // 4: Event - Signature
        // 5: Event - from (address which burned ERC20)
        // 6: Event - to (burn address receiving ERC20)
        // 7: Event - value (sent amount)
        require(resultSegments.length >= 8, "Invalid result length");
        // Need to recover from verifier code
        address fromAddress = address(
            uint160(uint256(bytes32(resultSegments[5].abiBytes)))
        );
        address toAddress = address(
            uint160(uint256(bytes32(resultSegments[6].abiBytes)))
        );
        uint256 amount = uint256(bytes32(resultSegments[7].abiBytes));

        require(amount > 0, "No amount to send");
        // The 0 address was made an invalid address for EVM token transfers, since that
        // was resulting in accidental lost funds. Other addresses which are also near impossible
        // to have the keys to are used for burns instead. We accept addresses up through
        // 0x00000...128. That is, addresses with 19 leading bytes of 0's.
        require(toAddress < address(128), "Not valid burn address");
        require(fromAddress != address(0), "Invalid address to mint ERC20");

        if (
            amount > $.maxInstantMint &&
            $.lockedQueries[proverContractAddr][queryId].amount == 0
        ) {
            LockedQuery storage lockedQuery = $.lockedQueries[
                proverContractAddr
            ][queryId];
            lockedQuery.unlockTime = uint64(block.timestamp) + $.lockupDuration;
            lockedQuery.ERC20Address = ERC20Address;
            lockedQuery.mintRecipient = fromAddress;
            lockedQuery.amount = amount;
            lockedQuery.approvals = 1;
            lockedQuery.approvedBy[msg.sender] = true;
            emit QueryLocked(queryId, lockedQuery.unlockTime);
            return;
        }

        _mintTokens(ERC20Address, fromAddress, amount, queryId);
    }

    function approveLockedMint(
        address proverContractAddr,
        bytes32 queryId
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        LockedQuery storage lockedQuery = _getProxyStorage().lockedQueries[
            proverContractAddr
        ][queryId];
        require(lockedQuery.unlockTime > 0, "Query is not locked");
        require(
            block.timestamp >= lockedQuery.unlockTime,
            "Lockup period not over"
        );
        require(!lockedQuery.approvedBy[msg.sender], "Already approved");

        lockedQuery.approvals += 1;
        lockedQuery.approvedBy[msg.sender] = true;
        emit QueryApproved(queryId, msg.sender, lockedQuery.approvals);
    }

    function executeLockedMint(
        address proverContractAddr,
        bytes32 queryId
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ProxyStorage storage $ = _getProxyStorage();
        LockedQuery storage lockedQuery = $.lockedQueries[proverContractAddr][
            queryId
        ];
        require(lockedQuery.unlockTime > 0, "Query is not locked");
        require(
            block.timestamp >= lockedQuery.unlockTime,
            "Lockup period not over"
        );
        require(
            lockedQuery.approvals >= $.approvalThreshold,
            "Not enough approvals"
        );

        address ERC20Address = lockedQuery.ERC20Address;
        address toAddress = lockedQuery.mintRecipient;
        uint256 amount = lockedQuery.amount;
        delete $.lockedQueries[proverContractAddr][queryId];

        _mintTokens(ERC20Address, toAddress, amount, queryId);
    }

    function _mintTokens(
        address ERC20Address,
        address principal,
        uint256 amount,
        bytes32 queryId
    ) internal {
        IERC20Mintable token = IERC20Mintable(ERC20Address);
        ProxyStorage storage $ = _getProxyStorage();
        require(
            !$.usedQueryId[ERC20Address][queryId],
            "Query is already processed"
        );
        $.usedQueryId[ERC20Address][queryId] = true;
        token.mint(principal, amount);
        emit TokensMinted(ERC20Address, principal, amount, queryId);
    }
}
