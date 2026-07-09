const { ethers } = require("ethers");
const { encoding, queryBuilder } = require("@gluwa/usc-sdk");

const TALLY_EVENT_ABI = [
    {
        anonymous: false,
        inputs: [
            { indexed: false, name: "proposalId", type: "uint256" },
            { indexed: false, name: "chainKey", type: "uint64" },
            { indexed: false, name: "forVotes", type: "uint256" },
            { indexed: false, name: "againstVotes", type: "uint256" },
            { indexed: false, name: "abstainVotes", type: "uint256" },
        ],
        name: "ChainTallyFinalized",
        type: "event",
    },
];
const TALLY_EVENT_SIGNATURE = ethers.id(
    "ChainTallyFinalized(uint256,uint64,uint256,uint256,uint256)",
);

/**
 * Build the ten-segment USC readability query consumed by CrossChainGovernorHub.
 * Offsets are computed from the finalized transaction because receipt-log offsets
 * vary with the transaction type and the other logs in the receipt.
 */
async function buildGovernanceTallyQuery(provider, transactionHash, spokeAddress, chainKey) {
    const normalizedSpoke = ethers.getAddress(spokeAddress);
    const normalizedChainKey = BigInt(chainKey);
    if (normalizedChainKey === 0n || normalizedChainKey > 2n ** 64n - 1n) {
        throw new Error("chainKey must be a non-zero uint64 USC source-chain key");
    }

    const receipt = await provider.getTransactionReceipt(transactionHash);
    if (!receipt) {
        throw new Error(`Transaction receipt not found: ${transactionHash}`);
    }

    const formattedTransaction = await provider.getTransaction(transactionHash);
    if (!formattedTransaction) {
        throw new Error(`Transaction not found: ${transactionHash}`);
    }
    const rawTransaction = await provider.send("eth_getTransactionByHash", [transactionHash]);
    const rawAuthorizationList =
        rawTransaction?.authorizationList?.map(({ yParity }) => ({
            yParity: Number(yParity),
        })) ?? null;
    const transaction = new encoding.TransactionWithRaw(
        formattedTransaction,
        new encoding.RawTransactionResponse(rawAuthorizationList),
    );
    const builder = queryBuilder.QueryBuilder.createFromTransaction(
        transaction,
        receipt,
        encoding.EncodingVersion.V1,
    );
    builder.setAbiProvider(async (contractAddress) => {
        if (contractAddress.toLowerCase() !== normalizedSpoke.toLowerCase()) {
            throw new Error(`Unexpected tally event emitter: ${contractAddress}`);
        }
        return JSON.stringify(TALLY_EVENT_ABI);
    });

    builder
        .addStaticField(queryBuilder.QueryableFields.RxStatus)
        .addStaticField(queryBuilder.QueryableFields.TxFrom)
        .addStaticField(queryBuilder.QueryableFields.TxTo);

    await builder.eventBuilder(
        TALLY_EVENT_SIGNATURE,
        (log, description) =>
            log.address.toLowerCase() === normalizedSpoke.toLowerCase() &&
            BigInt(description.args.chainKey) === normalizedChainKey,
        (event) =>
            event
                .addAddress()
                .addSignature()
                .addArgument("proposalId")
                .addArgument("chainKey")
                .addArgument("forVotes")
                .addArgument("againstVotes")
                .addArgument("abstainVotes"),
    );

    const layoutSegments = builder.build();
    if (layoutSegments.length !== 10 || layoutSegments.some(({ size }) => size !== 32)) {
        throw new Error("Unexpected tally query layout");
    }

    const query = {
        chainId: normalizedChainKey,
        height: BigInt(receipt.blockNumber),
        index: BigInt(receipt.index),
        layoutSegments: layoutSegments.map(({ offset, size }) => ({
            offset: BigInt(offset),
            size: BigInt(size),
        })),
    };

    const queryId = ethers.keccak256(
        ethers.AbiCoder.defaultAbiCoder().encode(
            [
                "tuple(uint64 chainId,uint64 height,uint64 index," +
                    "tuple(uint64 offset,uint64 size)[] layoutSegments)",
            ],
            [query],
        ),
    );

    return { query, queryId };
}

function printable(result) {
    return JSON.stringify(
        result,
        (_, value) => (typeof value === "bigint" ? value.toString() : value),
        2,
    );
}

async function main() {
    const [rpcUrl, transactionHash, spokeAddress, chainKey] = process.argv.slice(2);
    if (!rpcUrl || !transactionHash || !spokeAddress || !chainKey) {
        throw new Error(
            "Usage: node scripts/buildGovernanceTallyQuery.js " +
                "<source-rpc-url> <finalize-tx-hash> <spoke-address> <usc-chain-key>",
        );
    }

    const provider = new ethers.JsonRpcProvider(rpcUrl);
    const result = await buildGovernanceTallyQuery(
        provider,
        transactionHash,
        spokeAddress,
        chainKey,
    );
    console.log(printable(result));
}

if (require.main === module) {
    main().catch((error) => {
        console.error(error.message);
        process.exitCode = 1;
    });
}

module.exports = {
    TALLY_EVENT_SIGNATURE,
    buildGovernanceTallyQuery,
};
