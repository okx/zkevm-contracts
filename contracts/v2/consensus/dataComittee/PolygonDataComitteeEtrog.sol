// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.20;

import "../../lib/PolygonRollupBaseEtrog.sol";
import "../../interfaces/ICDKDataCommittee.sol";
import "../../interfaces/IPolygonDataComittee.sol";

/**
 * Contract responsible for managing the states and the updates of L2 network.
 * There will be a trusted sequencer, which is able to send transactions.
 * Any user can force some transaction and the sequencer will have a timeout to add them in the queue.
 * The sequenced state is deterministic and can be precalculated before it's actually verified by a zkProof.
 * The aggregators will be able to verify the sequenced state with zkProofs and therefore make available the withdrawals from L2 network.
 * To enter and exit of the L2 network will be used a PolygonZkEVMBridge smart contract that will be deployed in both networks.
 */
contract PolygonDataComitteeEtrog is
    PolygonRollupBaseEtrog,
    IPolygonDataComittee
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    /**
     * @notice Struct which will be used to call sequenceBatches
     * @param transactionsHash keccak256 hash of the L2 ethereum transactions EIP-155 or pre-EIP-155 with signature:
     * EIP-155: rlp(nonce, gasprice, gasLimit, to, value, data, chainid, 0, 0,) || v || r || s
     * pre-EIP-155: rlp(nonce, gasprice, gasLimit, to, value, data) || v || r || s
     * @param forcedGlobalExitRoot Global exit root, empty when sequencing a non forced batch
     * @param forcedTimestamp Minimum timestamp of the force batch data, empty when sequencing a non forced batch
     * @param forcedBlockHashL1 blockHash snapshot of the force batch data, empty when sequencing a non forced batch
     */
    struct ValidiumBatchData {
        bytes32 transactionsHash;
        bytes32 forcedGlobalExitRoot;
        uint64 forcedTimestamp;
        bytes32 forcedBlockHashL1;
    }

    // CDK Data Committee Address
    ICDKDataCommittee public dataCommittee;

    // Indicates if sequence with data avialability is allowed
    // This allow the sequencer to post the data and skip the Data comittee
    bool public isSequenceWithDataAvailabilityAllowed;

    /**
     * @dev Emitted when the admin updates the data committee
     */
    event SetDataCommittee(address newDataCommittee);

    /**
     * @dev Emitted when switch the ability to sequence with data availability
     */
    event SwitchSequenceWithDataAvailability();

    /**
     * @param _globalExitRootManager Global exit root manager address
     * @param _pol POL token address
     * @param _bridgeAddress Bridge address
     * @param _rollupManager Global exit root manager address
     */
    constructor(
        IPolygonZkEVMGlobalExitRootV2 _globalExitRootManager,
        IERC20Upgradeable _pol,
        IPolygonZkEVMBridgeV2 _bridgeAddress,
        PolygonRollupManager _rollupManager
    )
        PolygonRollupBaseEtrog(
            _globalExitRootManager,
            _pol,
            _bridgeAddress,
            _rollupManager
        )
    {}

    /////////////////////////////////////
    // Sequence/Verify batches functions
    ////////////////////////////////////

    function sequenceBatches(
        BatchData[] calldata batches,
        address l2Coinbase
    ) public override {
        if (!isSequenceWithDataAvailabilityAllowed) {
            revert SequenceWithDataAvailabilityNotAllowed();
        }
        super.sequenceBatches(batches, l2Coinbase);
    }

    /**
     * @notice Allows a sequencer to send multiple batches
     * @param batches Struct array which holds the necessary data to append new batches to the sequence
     * @param l2Coinbase Address that will receive the fees from L2
     * @param dataAvailabilityMessage Byte array containing the signatures and all the addresses of the committee in ascending order
     * [signature 0, ..., signature requiredAmountOfSignatures -1, address 0, ... address N]
     * note that each ECDSA signatures are used, therefore each one must be 65 bytes
     */
    function sequenceBatchesDataCommittee(
        ValidiumBatchData[] calldata batches,
        address l2Coinbase,
        bytes calldata dataAvailabilityMessage
    ) external onlyTrustedSequencer {
        uint256 batchesNum = batches.length;
        if (batchesNum == 0) {
            revert SequenceZeroBatches();
        }

        if (batchesNum > _MAX_VERIFY_BATCHES) {
            revert ExceedMaxVerifyBatches();
        }

        // Update global exit root if there are new deposits
        bridgeAddress.updateGlobalExitRoot();

        // Get global batch variables
        bytes32 l1InfoRoot = globalExitRootManager.getRoot();
        uint64 currentTimestamp = uint64(block.timestamp);

        // Store storage variables in memory, to save gas, because will be overrided multiple times
        uint64 currentLastForceBatchSequenced = lastForceBatchSequenced;
        bytes32 currentAccInputHash = lastAccInputHash;

        // Store in a temporal variable, for avoid access again the storage slot
        uint64 initLastForceBatchSequenced = currentLastForceBatchSequenced;

        for (uint256 i = 0; i < batchesNum; i++) {
            // Load current sequence
            ValidiumBatchData memory currentBatch = batches[i];

            // Check if it's a forced batch
            if (currentBatch.forcedTimestamp > 0) {
                currentLastForceBatchSequenced++;

                // Check forced data matches
                bytes32 hashedForcedBatchData = keccak256(
                    abi.encodePacked(
                        currentBatch.transactionsHash,
                        currentBatch.forcedGlobalExitRoot,
                        currentBatch.forcedTimestamp,
                        currentBatch.forcedBlockHashL1
                    )
                );

                if (
                    hashedForcedBatchData !=
                    forcedBatches[currentLastForceBatchSequenced]
                ) {
                    revert ForcedDataDoesNotMatch();
                }

                // Calculate next accumulated input hash
                currentAccInputHash = keccak256(
                    abi.encodePacked(
                        currentAccInputHash,
                        currentBatch.transactionsHash,
                        currentBatch.forcedGlobalExitRoot,
                        currentBatch.forcedTimestamp,
                        l2Coinbase,
                        currentBatch.forcedBlockHashL1
                    )
                );

                // Delete forceBatch data since won't be used anymore
                delete forcedBatches[currentLastForceBatchSequenced];
            } else {
                // Note that forcedGlobalExitRoot and forcedBlockHashL1 remain unused and unchecked in this path
                // The synchronizer should be aware of that

                // Calculate next accumulated input hash
                currentAccInputHash = keccak256(
                    abi.encodePacked(
                        currentAccInputHash,
                        currentBatch.transactionsHash,
                        l1InfoRoot,
                        currentTimestamp,
                        l2Coinbase,
                        bytes32(0)
                    )
                );
            }
        }

        // Sanity check, should be unreachable
        if (currentLastForceBatchSequenced > lastForceBatch) {
            revert ForceBatchesOverflow();
        }

        // Store back the storage variables
        lastAccInputHash = currentAccInputHash;

        uint256 nonForcedBatchesSequenced = batchesNum;

        // Check if there has been forced batches
        if (currentLastForceBatchSequenced != initLastForceBatchSequenced) {
            uint64 forcedBatchesSequenced = currentLastForceBatchSequenced -
                initLastForceBatchSequenced;
            // substract forced batches
            nonForcedBatchesSequenced -= forcedBatchesSequenced;

            // Transfer pol for every forced batch submitted
            pol.safeTransfer(
                address(rollupManager),
                calculatePolPerForceBatch() * (forcedBatchesSequenced)
            );

            // Store new last force batch sequenced
            lastForceBatchSequenced = currentLastForceBatchSequenced;
        }

        // Pay collateral for every non-forced batch submitted
        pol.safeTransferFrom(
            msg.sender,
            address(rollupManager),
            rollupManager.getBatchFee() * nonForcedBatchesSequenced
        );

        uint64 currentBatchSequenced = rollupManager.onSequenceBatches(
            uint64(batchesNum),
            currentAccInputHash
        );

        // Validate that the data committee has signed the accInputHash for this sequence
        dataCommittee.verifySignatures(
            currentAccInputHash,
            dataAvailabilityMessage
        );

        emit SequenceBatches(currentBatchSequenced, l1InfoRoot);
    }

    //////////////////
    // admin functions
    //////////////////

    /**
     * @notice Allow the admin to set a new data committee
     * @param newDataCommittee Address of the new data committee
     */
    function setDataCommittee(
        ICDKDataCommittee newDataCommittee
    ) external onlyAdmin {
        dataCommittee = newDataCommittee;

        emit SetDataCommittee(address(newDataCommittee));
    }

    /**
     * @notice Allow the admin to turn on the force batches
     * This action is not reversible
     */
    function switchSequenceWithDataAvailability() external onlyAdmin {
        isSequenceWithDataAvailabilityAllowed = !isSequenceWithDataAvailabilityAllowed;
        emit SwitchSequenceWithDataAvailability();
    }
}
