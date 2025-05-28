const { ethers, upgrades } = require('hardhat');
async function main() {
    // get the encoded RLP transaction from the transaction hash
    let rpc_url = "https://sepolia-proxy-rpc.creditcoin.network";
    let tx_hash_str = "0xe3de4394fc39316c737abe75768a0050d69cb610956434d7cd7d8bb0fa7d5b90";
    const encoded = await getRlpEncodedTx(tx_hash_str, rpc_url);
    const [owner] = await ethers.getSigners();
    const proverFactory = await ethers.getContractFactory('CreditcoinPublicProver');
    const proxyFactory = await ethers.getContractFactory('UniversalBridgeProxy');
    const prover = await proverFactory.deploy(owner.address);
    await prover.waitForDeployment();
    
    const proxy = await upgrades.deployProxy(proxyFactory, [
        BigInt(10**18), // 1 ether
        60 * 60 * 24, // 1 day
        2, // 2 approvals
        [owner.address], // admins
    ]);
    await proxy.waitForDeployment();
    // decode the transaction using the proxy contract
    console.log(await proxy.decodeTransaction(encoded));
}

async function getRlpEncodedTx(txHash, rpcUrl) {
    const provider = new ethers.JsonRpcProvider(rpcUrl);
    const tx = await provider.getTransaction(txHash);
    if (!tx) {
        console.error("Transaction not found");
        return;
    }
    const receipt = await provider.getTransactionReceipt(txHash);
    if (!receipt) {
        console.error("Transaction receipt not found");
        return;
    }
    if (tx.type && tx.type !== 0) {
        console.error("Transaction is not a legacy transaction");
        return;
    }
    const rawTx = [
        ethers.toBeHex(ethers.toBigInt(tx.nonce)),          // Nonce
        ethers.toBeHex(ethers.toBigInt(tx.gasPrice)),      // Gas Price
        ethers.toBeHex(ethers.toBigInt(tx.gasLimit)),       // Gas Limit
        tx.to ?? "0x",                                          // To address (empty for contract creation)
        ethers.toBeHex(ethers.toBigInt(tx.value)),          // Value
        tx.data,                                                // Data field
        ethers.toBeHex(ethers.toBigInt(tx.signature.v)),             // v
        ethers.toBeHex(ethers.toBigInt(tx.signature.r)),             // r
        ethers.toBeHex(ethers.toBigInt(tx.signature.s))              // s
    ];
    // Encode the transaction separately
    const rlpEncodedTx = ethers.encodeRlp(rawTx);

    // Prepare receipt fields for RLP encoding
    const rawReceipt = [
        ethers.toBeHex(ethers.toBigInt(receipt.status)),         // Status (1 = success, 0 = failure)
        ethers.toBeHex(ethers.toBigInt(receipt.cumulativeGasUsed)), // Cumulative gas used
        receipt.logsBloom,                                            // Logs bloom filter
        receipt.logs.map(log => [
            log.address,
            log.topics.map(topic => ethers.toBeHex(ethers.toBigInt(topic))), // Topics array
            log.data
        ])
    ];

    // Encode the receipt separately
    const rlpEncodedReceipt = ethers.encodeRlp(rawReceipt);

    // Encode the final array [RLP(tx), RLP(receipt)]
    const finalRlpArray = ethers.encodeRlp([rlpEncodedTx, rlpEncodedReceipt]);

    return finalRlpArray;
}


main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
