pragma solidity ^0.6.6;

import {IRootChainManager} from "./IRootChainManager.sol";
import {RootChainManagerStorage} from "./RootChainManagerStorage.sol";

import {IStateSender} from "../StateSender/IStateSender.sol";
import {ICheckpointManager} from "../ICheckpointManager.sol";
import {WETH} from "../RootToken/WETH.sol";
import {RLPReader} from "../../lib/RLPReader.sol";
import {MerklePatriciaProof} from "../../lib/MerklePatriciaProof.sol";
import {Merkle} from "../../lib/Merkle.sol";
import {ITokenPredicate} from "../TokenPredicates/ITokenPredicate.sol";

contract RootChainManager is RootChainManagerStorage, IRootChainManager {
    using RLPReader for bytes;
    using RLPReader for RLPReader.RLPItem;
    using Merkle for bytes32;

    bytes32 private constant DEPOSIT = keccak256("DEPOSIT");
    bytes32 private constant MAP_TOKEN = keccak256("MAP_TOKEN");
    IStateSender private _stateSender;
    ICheckpointManager private _checkpointManager;
    address private _childChainManagerAddress;

    // TODO: add fallback function

    function setStateSender(address newStateSender)
        external
        only(DEFAULT_ADMIN_ROLE)
    {
        _stateSender = IStateSender(newStateSender);
    }

    function stateSenderAddress() external view returns (address) {
        return address(_stateSender);
    }

    function setCheckpointManager(address newCheckpointManager)
        external
        only(DEFAULT_ADMIN_ROLE)
    {
        _checkpointManager = ICheckpointManager(newCheckpointManager);
    }

    function checkpointManagerAddress() external view returns (address) {
        return address(_checkpointManager);
    }

    function setChildChainManagerAddress(address newChildChainManager)
        external
        only(DEFAULT_ADMIN_ROLE)
    {
        _childChainManagerAddress = newChildChainManager;
    }

    function childChainManagerAddress() external view returns (address) {
        return _childChainManagerAddress;
    }

    function registerPredicate(bytes32 tokenType, address predicateAddress)
        external
        override
        only(REGISTERER_ROLE)
    {
        _typeToPredicate[tokenType] = predicateAddress;
        emit PredicateRegistered(tokenType, predicateAddress);
    }

    function typeToPredicate(bytes32 tokenType)
        external
        override
        view
        returns (address)
    {
        return _typeToPredicate[tokenType];
    }

    function mapToken(
        address rootToken,
        address childToken,
        bytes32 tokenType
    ) external override only(MAPPER_ROLE) {
        require(
            _typeToPredicate[tokenType] != address(0x0),
            "RootChainManager: TOKEN_TYPE_NOT_SUPPORTED"
        );
        require(
            address(_stateSender) != address(0x0),
            "RootChainManager: STATESENDER_NOT_SET"
        );
        require(
            address(_childChainManagerAddress) != address(0x0),
            "RootChainManager: CHILDCHAINMANAGER_NOT_SET"
        );

        _rootToChildToken[rootToken] = childToken;
        _childToRootToken[childToken] = rootToken;
        _tokenToType[rootToken] = tokenType;

        emit TokenMapped(rootToken, childToken, tokenType);

        bytes memory syncData = abi.encode(rootToken, childToken, tokenType);
        _stateSender.syncState(
            _childChainManagerAddress,
            abi.encode(MAP_TOKEN, syncData)
        );
    }

    function rootToChildToken(address rootToken)
        external
        override
        view
        returns (address)
    {
        return _rootToChildToken[rootToken];
    }

    function childToRootToken(address childToken)
        external
        override
        view
        returns (address)
    {
        return _childToRootToken[childToken];
    }

    function tokenToType(address rootToken)
        external
        override
        view
        returns (bytes32)
    {
        return _tokenToType[rootToken];
    }

    function depositEtherFor(address user, uint256 amount)
        external
        override
        payable
    {}

    function depositFor(
        address user,
        address rootToken,
        bytes calldata depositData
    ) external override {
        require(
            address(_stateSender) != address(0x0),
            "RootChainManager: STATESENDER_NOT_SET"
        );
        require(
            address(_childChainManagerAddress) != address(0x0),
            "RootChainManager: CHILDCHAINMANAGER_NOT_SET"
        );
        require(
            _rootToChildToken[rootToken] != address(0x0) &&
                _tokenToType[rootToken] != 0,
            "RootChainManager: TOKEN_NOT_MAPPED"
        );
        address predicateAddress = _typeToPredicate[_tokenToType[rootToken]];
        require(
            predicateAddress != address(0),
            "RootChainManager: INVALID_TOKEN_TYPE"
        );

        ITokenPredicate(predicateAddress).lockTokens(
            _msgSender(),
            user,
            rootToken,
            depositData
        );
        bytes memory syncData = abi.encode(user, rootToken, depositData);
        _stateSender.syncState(
            _childChainManagerAddress,
            abi.encode(DEPOSIT, syncData)
        );
    }

    function processedExits(bytes32 exitHash)
        external
        override
        view
        returns (bool)
    {
        return _processedExits[exitHash];
    }

    /**
     * @param inputData RLP encoded data of the reference tx containing following list of fields
     *  0 - headerNumber Header block number of which the reference tx was a part of
     *  1 - blockProof Proof that the block header (in the child chain) is a leaf in the submitted merkle root
     *  2 - blockNumber Block number of which the reference tx is a part of
     *  3 - blockTime Reference tx block time
     *  4 - blocktxRoot Transactions root of block
     *  5 - blockReceiptsRoot Receipts root of block
     *  6 - receipt Receipt of the reference transaction
     *  7 - receiptProof Merkle proof of the reference receipt
     *  8 - branchMask Merkle proof branchMask for the receipt
     *  9 - logIndex Log Index to read from the receipt
     */
    function exit(bytes calldata inputData) external override {
        RLPReader.RLPItem[] memory inputDataRLPList = inputData
            .toRlpItem()
            .toList();

        // checking if exit has already been processed
        // unique exit is identified using hash of (blockNumber, receipt, logIndex)
        require(
            _processedExits[keccak256(
                abi.encodePacked(
                    inputDataRLPList[2].toBytes(), // blockNumber
                    inputDataRLPList[6].toBytes(), // receipt
                    inputDataRLPList[9].toBytes() // logIndex
                )
            )] == false,
            "RootChainManager: EXIT_ALREADY_PROCESSED"
        );
        _processedExits[keccak256(
            abi.encodePacked(
                inputDataRLPList[2].toBytes(), // blockNumber
                inputDataRLPList[6].toBytes(), // receipt
                inputDataRLPList[9].toBytes() // logIndex
            )
        )] = true;

        // verifying child withdraw log
        RLPReader.RLPItem[] memory receiptRLPList = inputDataRLPList[6]
            .toBytes()
            .toRlpItem()
            .toList();
        RLPReader.RLPItem memory logRLP = receiptRLPList[3]
            .toList()[inputDataRLPList[9].toUint()]; /* logIndex */

        address childToken = RLPReader.toAddress(logRLP.toList()[0]); // log emitter address field
        require(
            _childToRootToken[childToken] != address(0),
            "RootChainManager: TOKEN_NOT_MAPPED"
        );

            address predicateAddress
         = _typeToPredicate[_tokenToType[_childToRootToken[childToken]]];
        ITokenPredicate(predicateAddress).validateExitLog(
            _msgSender(),
            logRLP.toBytes()
        );

        // RLPReader.RLPItem[] memory logTopicRLPList = logRLPList[1].toList(); // log topics
        // require(
        //     bytes32(logTopicRLPList[0].toUint()) == TRANSFER_EVENT_SIG, // topic0 is event sig
        //     "RootChainManager: INVALID_SIGNATURE"
        // );
        // require(
        //     _msgSender() == address(logTopicRLPList[1].toUint()), // topic1 is from address
        //     "RootChainManager: INVALID_SENDER"
        // );
        // require(
        //     address(logTopicRLPList[2].toUint()) == address(0), // topic2 is to address
        //     "RootChainManager: INVALID_RECEIVER"
        // );

        require(
            inputDataRLPList[8].toBytes().toRlpItem().toUint() &
                0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF00000000 ==
                0,
            "RootChainManager: INVALID_BRANCH_MASK"
        );

        // verify receipt inclusion
        require(
            MerklePatriciaProof.verify(
                inputDataRLPList[6].toBytes(), // receipt
                inputDataRLPList[8].toBytes(), // branchMask
                inputDataRLPList[7].toBytes(), // receiptProof
                bytes32(inputDataRLPList[5].toUint()) // receiptsRoot
            ),
            "RootChainManager: INVALID_PROOF"
        );

        // verify checkpoint inclusion
        checkBlockMembershipInCheckpoint(
            inputDataRLPList[2].toUint(), // blockNumber
            inputDataRLPList[3].toUint(), // blockTime
            bytes32(inputDataRLPList[4].toUint()), // txRoot
            bytes32(inputDataRLPList[5].toUint()), // receiptRoot
            inputDataRLPList[0].toUint(), // headerNumber
            inputDataRLPList[1].toBytes() // blockProof
        );

        ITokenPredicate(predicateAddress).exitTokens(
            _msgSender(),
            _childToRootToken[childToken],
            logRLP.toBytes()
        );

        // transfer tokens
        // IERC20(_childToRootToken[childToken]).transfer(
        //     _msgSender(),
        //     logRLPList[2].toUint() // log data
        // );

        // if (_childToRootToken[childToken] == address(_WETH)) {
        //     _WETH.withdrawFor(logRLPList[2].toUint(), _msgSender());
        // }

        // emit Exited(
        //     _msgSender(),
        //     _childToRootToken[childToken],
        //     logRLPList[2].toUint()
        // );
    }

    function checkBlockMembershipInCheckpoint(
        uint256 blockNumber,
        uint256 blockTime,
        bytes32 txRoot,
        bytes32 receiptRoot,
        uint256 headerNumber,
        bytes memory blockProof
    ) internal view returns (uint256) {
        (
            bytes32 headerRoot,
            uint256 startBlock,
            ,
            uint256 createdAt,

        ) = _checkpointManager.headerBlocks(headerNumber);

        require(
            keccak256(
                abi.encodePacked(blockNumber, blockTime, txRoot, receiptRoot)
            )
                .checkMembership(
                blockNumber - startBlock,
                headerRoot,
                blockProof
            ),
            "RootChainManager: INVALID_HEADER"
        );
        return createdAt;
    }
}