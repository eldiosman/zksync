pragma solidity ^0.4.24;

import {Plasma} from "./Plasma.sol";

contract PlasmaTransactor is Plasma {

    uint256 constant TRANSFER_BLOCK_SIZE = 128;

    mapping (uint32 => mapping (uint24 => uint128)) public partialExits;

    function commitTransferBlock(
        uint32 blockNumber, 
        uint128 totalFees, 
        bytes memory txDataPacked, 
        bytes32 newRoot
    ) 
    public 
    operator_only 
    {
        require(blockNumber == lastCommittedBlockNumber + 1, "may only commit next block");

        // create now commitments and write to storage
        bytes32 publicDataCommitment = createPublicDataCommitmentForTransfer(blockNumber, totalFees, txDataPacked);

        blocks[blockNumber] = Block(
            uint8(Circuit.TRANSFER), 
            uint64(block.timestamp + DEADLINE), 
            totalFees, newRoot, 
            publicDataCommitment, 
            msg.sender
        );
        emit BlockCommitted(blockNumber);
        parsePartialExitsBlock(blockNumber, txDataPacked);
        lastCommittedBlockNumber++;
    }

    function verifyTransferBlock(uint32 blockNumber, uint256[8] memory proof) public operator_only {
        require(lastVerifiedBlockNumber < lastCommittedBlockNumber, "no committed block to verify");
        require(blockNumber == lastVerifiedBlockNumber + 1, "may only verify next block");
        Block memory committed = blocks[blockNumber];
        require(committed.circuit == uint8(Circuit.TRANSFER), "trying to prove the invalid circuit for this block number");
        bool verification_success = verifyProof(Circuit.TRANSFER, proof, lastVerifiedRoot, committed.newRoot, committed.publicDataCommitment);
        require(verification_success, "invalid proof");

        emit BlockVerified(blockNumber);
        lastVerifiedBlockNumber++;
        lastVerifiedRoot = committed.newRoot;

        balances[committed.prover] += committed.totalFees;
    }

    // pure functions to calculate commitment formats
    function createPublicDataCommitmentForTransfer(uint32 blockNumber, uint128 totalFees, bytes memory txDataPacked)
    public 
    pure
    returns (bytes32 h) {

        bytes32 initialHash = sha256(abi.encodePacked(uint256(blockNumber), uint256(totalFees)));
        bytes32 finalHash = sha256(abi.encodePacked(initialHash, txDataPacked));

        // // this can be used if inside of a SNARK the edge case of transfer 
        // // from 0 to 0 with zero amount and fee
        // // is properly covered. Account number 0 does NOT have a public key
        // if (txDataPacked.length / 9 == TRANSFER_BLOCK_SIZE) {
        //     bytes32 finalHash = sha256(abi.encodePacked(initialHash, txDataPacked));
        // } else {
        //     // do the ad-hoc padding with zeroes
        //     bytes32 finalHash = sha256(abi.encodePacked(initialHash, txDataPacked, new bytes(TRANSFER_BLOCK_SIZE * 9 - txDataPacked.length)));
        // }
        
        return finalHash;
    }

    // parse every tx in a block and of destination == 0 - write a partial exit information
    function parsePartialExitsBlock(
        uint32 blockNumber,
        bytes memory txDataPacked
    )
    internal
    {
        uint256 chunk;
        uint256 pointer = 32;
        uint24 to;
        uint24 from;
        uint128 scaledAmount;
        uint16 floatValue;
        // there is no check for a length of the public data because it's not provable if broken
        // unless sha256 collision is found
        for (uint256 i = 0; i < txDataPacked.length / 9; i++) { 
            assembly {
                chunk := mload(add(txDataPacked, pointer))
            }
            pointer += 9;
            to = uint24((chunk << 24) >> 232);
            if (to == 0) {
                from = uint24(chunk >> 232);
                if (from == 0) {
                    continue;
                }
                floatValue = uint16((chunk << 48) >> 240);

                scaledAmount = parseFloat(floatValue);
                partialExits[blockNumber][from] = scaledAmount;
            }
        }
    }

    // parses 5 bits of exponent base 10 and 11 bits of mantissa
    // there are no overflow checks here cause maximum float value < UINT128_MAX
    function parseFloat(
        uint16 float  
    )
    public 
    pure
    returns (uint128 scaledValue)
    {
        uint128 exponent = 0;
        uint128 powerOfTwo = 1;
        for (uint256 i = 0; i < 5; i++) {
            if (float & (1 << (15 - i)) > 0) {
                exponent += powerOfTwo;
            }
            powerOfTwo = powerOfTwo * 2;
        }
        exponent = uint128(10) ** exponent;

        uint128 mantissa = 0;
        powerOfTwo = 1;
        // TODO: change when 0.5.0 is used
        for (i = 0; i < 11; i++) {
            if (float & (1 << (10 - i)) > 0) {
                mantissa += powerOfTwo;
            }
            powerOfTwo = powerOfTwo * 2;
        }
        return exponent * mantissa;
    }


    function withdrawPartialExitBalance(
        uint32 blockNumber
    )
    public
    {
        uint24 accountID = ethereumAddressToAccountID[msg.sender];
        require(accountID != 0, "trying to access a non-existent account");
        require(blockNumber <= lastVerifiedBlockNumber, "can only process exits from verified blocks");
        uint128 balance = partialExits[blockNumber][accountID];
        require(balance != 0, "nothing to exit");
        delete partialExits[blockNumber][accountID];
        uint256 amountInWei = scaleFromPlasmaUnitsIntoWei(balance);
        msg.sender.transfer(amountInWei);
    }
}