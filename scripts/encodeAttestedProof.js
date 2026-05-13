require('dotenv').config();
const { ethers } = require('ethers');
const {
    abiEncode,
    EncodingVersion,
    getTransactionWithRaw,
    TransactionWithRaw,
    RawTransactionResponse,
} = require('@gluwa/usc-sdk').encoding;

const {
    LAYOUT_SEGMENTS,
    CHAIN_KEY,
    PROVER_BASE,
    compute_query_id,
    srcChainRPC,
} = require('./common/utils');

const txHash = process.argv[2];
if (!txHash) {
    console.error('Usage: node scripts/encodeAttestedProof.js <txHash>');
    process.exit(1);
}

async function main() {

    const provider = new ethers.JsonRpcProvider(srcChainRPC);

    console.log('RPC:', srcChainRPC);
    console.log('TX_HASH:', txHash);

    const receipt = await provider.getTransactionReceipt(txHash);
    if (!receipt) {
        console.error('Transaction receipt not found');
        return;
    }

    let tx_with_raw = await getTransactionWithRaw(provider, txHash);
    if (!tx_with_raw) {
        const tx = await provider.getTransaction(tx_hash_str);
        if (!tx) {
            console.error('Transaction not found');
            return;
        }
        tx_with_raw = new TransactionWithRaw(tx, new RawTransactionResponse(null));
    }

    const tx = tx_with_raw.formatted;

    console.log('tx.type:', tx.type);
    console.log('blockNumber:', receipt.blockNumber, 'txIndex:', receipt.index);

    const encoded = abiEncode(tx_with_raw, receipt, EncodingVersion.V1);
    const usc_sdk_tx_bytes = encoded.abi;
    console.log('\n--- USC SDK proof.txBytes ---');
    console.log('length (bytes):', (usc_sdk_tx_bytes.length - 2) / 2);
    console.log(usc_sdk_tx_bytes);

    const proof_url = `${PROVER_BASE.replace(/\/$/, '')}/api/v1/proof/${CHAIN_KEY}/${receipt.blockNumber}/${receipt.index}`;
    console.log('\n--- Prover API comparison ---');
    console.log('GET', proof_url);

    const res = await fetch(proof_url);
    if (!res.ok) {
        const text = await res.text();
        throw new Error(`Prover HTTP ${res.status}: ${text.slice(0, 500)}`);
    }

    const proof = await res.json();
    const match = usc_sdk_tx_bytes.toLowerCase() === proof.txBytes.toLowerCase();
    console.log(match
        ? 'OK: local txBytes matches prover API txBytes'
        : 'MISMATCH: local txBytes != prover API txBytes');
    if (!match) {
        console.log('  local  (prefix):', usc_sdk_tx_bytes.slice(0, 66));
        console.log('  prover (prefix):', proof.txBytes.slice(0, 66));
        process.exitCode = 1;
    }

    const chain_key = BigInt(process.env.QUERY_CHAIN_ID || '1');
    const qid = compute_query_id(
        chain_key,
        BigInt(receipt.blockNumber),
        BigInt(receipt.index),
        LAYOUT_SEGMENTS,
    );
    console.log('queryId:', qid);
}

main()
    .then(() =>
        process.exit(
            typeof process.exitCode === 'number' ? process.exitCode : 0,
        ),
    )
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
