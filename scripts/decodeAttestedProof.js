require('dotenv').config();
const { ethers } = require('ethers');
const {
    getTransactionWithRaw,
    TransactionWithRaw,
    RawTransactionResponse,
} = require('@gluwa/usc-sdk').encoding;

const {
    srcChainRPC,
    CHAIN_KEY,
    PROVER_BASE,
    decode_proof_tx_bytes,
    recover_tx_hash,
    format_to,
    str,
} = require('./common/utils');

function parse_args() {
    const args = process.argv.slice(2);
    let txHash = null;
    let txBytes = null;

    for (let i = 0; i < args.length; i++) {
        if (args[i] === '--txHash' && args[i + 1]) {
            txHash = args[++i];
        } else if (args[i] === '--txBytes' && args[i + 1]) {
            txBytes = args[++i];
        }
    }

    if (txHash && txBytes) {
        console.error('Error: provide only one of --txHash or --txBytes, not both.');
        process.exit(1);
    }
    if (!txHash && !txBytes) {
        console.error('Usage: node scripts/decodeAttestedProof.js --txHash <hash>');
        console.error('       node scripts/decodeAttestedProof.js --txBytes <hex>');
        process.exit(1);
    }
    return { txHash, txBytes };
}

const { txHash, txBytes } = parse_args();

async function main() {
    let proof_tx_bytes;

    if (txBytes) {
        console.log('txBytes length (bytes):', (txBytes.length - 2) / 2);
        proof_tx_bytes = txBytes;

        const decoded = decode_proof_tx_bytes(proof_tx_bytes);
        const recovered = recover_tx_hash(decoded);
        if (recovered) {
            const provider = new ethers.JsonRpcProvider(srcChainRPC);
            const receipt = await provider.getTransactionReceipt(recovered.hash);
            console.log('source chain txHash:', recovered.hash);
            if (receipt) {
                const proof_url = `${PROVER_BASE.replace(/\/$/, '')}/api/v1/proof/${CHAIN_KEY}/${receipt.blockNumber}/${receipt.index}`;
                console.log('prover API:', proof_url);
            }
        }
    } else {
        const provider = new ethers.JsonRpcProvider(srcChainRPC);

        console.log('RPC:', srcChainRPC);
        console.log('TX_HASH:', txHash);

        const receipt = await provider.getTransactionReceipt(txHash);
        if (!receipt) {
            throw new Error('Transaction receipt not found on Sepolia RPC');
        }

        const block_number = receipt.blockNumber;
        const tx_index = receipt.index;

        console.log('Resolved: blockNumber =', block_number, 'txIndex =', tx_index);

        let tx_with_raw = await getTransactionWithRaw(provider, txHash);
        if (!tx_with_raw) {
            const tx = await provider.getTransaction(txHash);
            if (!tx) throw new Error('Transaction not found');
            tx_with_raw = new TransactionWithRaw(tx, new RawTransactionResponse(null));
        }

        const proof_url = `${PROVER_BASE.replace(/\/$/, '')}/api/v1/proof/${CHAIN_KEY}/${block_number}/${tx_index}`;

        const res = await fetch(proof_url);
        if (!res.ok) {
            const text = await res.text();
            throw new Error(`Prover HTTP ${res.status}: ${text.slice(0, 500)}`);
        }

        const proof = await res.json();
        proof_tx_bytes = proof.txBytes;
    }

    console.log('\n--- Decoded FROM proof.txBytes ---');
    try {
        const decoded = decode_proof_tx_bytes(proof_tx_bytes);
        print_decoded_from_proof_tx_bytes(decoded);
    } catch (e) {
        console.error('Decode proof.txBytes failed:', e.message);
    }
}

function print_decoded_from_proof_tx_bytes(decodedData) {
    const { tx_type, common, middle } = decodedData;
    const nonce = common[0];
    const gas_limit = common[1];
    const from = common[2];
    const value = common[5];
    const data = typeof common[6] === 'string' ? common[6] : ethers.hexlify(common[6]);

    console.log('tx type:', tx_type);

    switch (tx_type) {
        case 0: {
            const m = middle[0];
            console.log('nonce:   ', str(nonce));
            console.log('gasPrice:', str(m[0]));
            console.log('gasLimit:', str(gas_limit));
            console.log('from:    ', ethers.getAddress(from));
            console.log('to:      ', format_to(common));
            console.log('value:   ', str(value));
            console.log('data:    ', data);
            break;
        }
        case 1: {
            const m = middle[0];
            console.log('chainId: ', str(m[0]));
            console.log('nonce:   ', str(nonce));
            console.log('gasPrice:', str(m[1]));
            console.log('gasLimit:', str(gas_limit));
            console.log('from:    ', ethers.getAddress(from));
            console.log('to:      ', format_to(common));
            console.log('value:   ', str(value));
            console.log('data:    ', data);
            break;
        }
        case 2: {
            const m = middle[0];
            console.log('chain_id:                 ', str(m[0]));
            console.log('nonce:                    ', str(nonce));
            console.log('max_priority_fee_per_gas: ', str(m[1]));
            console.log('max_fee_per_gas:          ', str(m[2]));
            console.log('gas_limit:                ', str(gas_limit));
            console.log('from:                     ', ethers.getAddress(from));
            console.log('to:                       ', format_to(common));
            console.log('value:                    ', str(value));
            console.log('data:                     ', data);
            break;
        }
        case 3: {
            const m0 = middle[0];
            const m1 = middle[1];
            console.log('chain_id:                 ', str(m0[0]));
            console.log('nonce:                    ', str(nonce));
            console.log('max_priority_fee_per_gas: ', str(m0[1]));
            console.log('max_fee_per_gas:          ', str(m0[2]));
            console.log('gas_limit:                ', str(gas_limit));
            console.log('from:                     ', ethers.getAddress(from));
            console.log('to:                       ', format_to(common));
            console.log('value:                    ', str(value));
            console.log('data:                     ', data);
            break;
        }
        case 4: {
            const m0 = middle[0];
            console.log('chain_id:                 ', str(m0[0]));
            console.log('nonce:                    ', str(nonce));
            console.log('max_priority_fee_per_gas: ', str(m0[1]));
            console.log('max_fee_per_gas:          ', str(m0[2]));
            console.log('gas_limit:                ', str(gas_limit));
            console.log('from:                     ', ethers.getAddress(from));
            console.log('to:                       ', format_to(common));
            console.log('value:                    ', str(value));
            console.log('data:                     ', data);
            break;
        }
        default:
            console.log('(unsupported type for detailed print)');
    }
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
