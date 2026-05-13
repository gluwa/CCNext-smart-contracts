const { ethers } = require('ethers');

const srcChainRPC = 'https://sepolia-proxy-rpc.creditcoin.network';
const CHAIN_KEY = 1;
const PROVER_BASE = 'https://prover.cc3-testnet.creditcoin.network';
const coder = ethers.AbiCoder.defaultAbiCoder();

const LAYOUT_SEGMENTS = [
    { offset: 448n, size: 32n },
    { offset: 192n, size: 32n },
    { offset: 224n, size: 32n },
    { offset: 800n, size: 32n },
    { offset: 928n, size: 32n },
    { offset: 960n, size: 32n },
    { offset: 992n, size: 32n },
    { offset: 1056n, size: 32n },
];

const COMMON_CHUNK_TYPES = [
    'uint64',
    'uint64',
    'address',
    'bool',
    'address',
    'uint256',
    'bytes',
];

/** Middle chunks between common and receipt — mirrors usc-sdk encoding/abi/v1.ts */
const MIDDLE_CHUNKS_TYPES_BY_TX_TYPE = {
    0: [['uint128', 'uint256', 'bytes32', 'bytes32']],
    1: [
        [
            'uint64',
            'uint128',
            'tuple(address,bytes32[])[]',
            'uint8',
            'bytes32',
            'bytes32',
        ],
    ],
    2: [
        [
            'uint64',
            'uint128',
            'uint128',
            'tuple(address,bytes32[])[]',
            'uint8',
            'bytes32',
            'bytes32',
        ],
    ],
    3: [
        ['uint64', 'uint128', 'uint128', 'tuple(address,bytes32[])[]'],
        ['uint256', 'bytes32[]', 'uint8', 'bytes32', 'bytes32'],
    ],
    4: [
        ['uint64', 'uint128', 'uint128', 'tuple(address,bytes32[])[]'],
        [
            'tuple(uint256,address,uint64,uint8,uint256,uint256)[]',
            'uint8',
            'bytes32',
            'bytes32',
        ],
    ],
};

function compute_query_id(chain_id, height, index, layout_segments) {
    const seg_tuple = layout_segments.map((s) => [s.offset, s.size]);
    return ethers.keccak256(
        coder.encode(
            ['uint64', 'uint64', 'uint64', 'tuple(uint64,uint64)[]'],
            [chain_id, height, index, seg_tuple],
        ),
    );
}

function str(v) {
    if (v == null) return '';
    if (typeof v === 'bigint') return v.toString();
    return String(v);
}

/**
 * Decode prover `txBytes` = abi.encode(uint8 txType, bytes[] chunks) per @gluwa/usc-sdk V1.
 */
function decode_proof_tx_bytes(tx_bytes_hex) {
    const [tx_type_bn, chunks] = coder.decode(['uint8', 'bytes[]'], tx_bytes_hex);
    const tx_type = Number(tx_type_bn);
    const middle_types = MIDDLE_CHUNKS_TYPES_BY_TX_TYPE[tx_type];
    if (!middle_types) {
        throw new Error(`Unsupported tx type in proof.txBytes: ${tx_type}`);
    }
    const expected_chunks = 1 + middle_types.length + 1;
    if (chunks.length !== expected_chunks) {
        throw new Error(
            `Bad chunk count: got ${chunks.length}, expected ${expected_chunks} for type ${tx_type}`,
        );
    }

    const common = coder.decode(COMMON_CHUNK_TYPES, chunks[0]);
    const middle = middle_types.map((types, i) =>
        coder.decode(types, chunks[1 + i]),
    );
    return { tx_type: tx_type, common, middle };
}

function format_to(common) {
    const to_is_null = common[3];
    const to = common[4];
    if (to_is_null) return '(contract creation — `to` null)';
    return ethers.getAddress(to);
}

/**
 * Reconstruct the signed transaction from decoded chunks and return its hash.
 */
function recover_tx_hash(decoded) {
    const { tx_type, common, middle } = decoded;
    const nonce = Number(common[0]);
    const gasLimit = BigInt(common[1]);
    const from = ethers.getAddress(common[2]);
    const to_is_null = common[3];
    const to = to_is_null ? null : ethers.getAddress(common[4]);
    const value = BigInt(common[5]);
    const data = typeof common[6] === 'string' ? common[6] : ethers.hexlify(common[6]);

    const txFields = { type: tx_type, nonce, gasLimit, to, value, data };

    switch (tx_type) {
        case 0: {
            const m = middle[0];
            txFields.gasPrice = BigInt(m[0]);
            txFields.signature = ethers.Signature.from({
                v: Number(BigInt(m[1])),
                r: ethers.hexlify(m[2]),
                s: ethers.hexlify(m[3]),
            });
            break;
        }
        case 1: {
            const m = middle[0];
            txFields.chainId = BigInt(m[0]);
            txFields.gasPrice = BigInt(m[1]);
            txFields.accessList = decode_access_list_tuples(m[2]);
            txFields.signature = ethers.Signature.from({
                yParity: Number(m[3]),
                r: ethers.hexlify(m[4]),
                s: ethers.hexlify(m[5]),
            });
            break;
        }
        case 2: {
            const m = middle[0];
            txFields.chainId = BigInt(m[0]);
            txFields.maxPriorityFeePerGas = BigInt(m[1]);
            txFields.maxFeePerGas = BigInt(m[2]);
            txFields.accessList = decode_access_list_tuples(m[3]);
            txFields.signature = ethers.Signature.from({
                yParity: Number(m[4]),
                r: ethers.hexlify(m[5]),
                s: ethers.hexlify(m[6]),
            });
            break;
        }
        case 3: {
            const m0 = middle[0];
            const m1 = middle[1];
            txFields.chainId = BigInt(m0[0]);
            txFields.maxPriorityFeePerGas = BigInt(m0[1]);
            txFields.maxFeePerGas = BigInt(m0[2]);
            txFields.accessList = decode_access_list_tuples(m0[3]);
            txFields.maxFeePerBlobGas = BigInt(m1[0]);
            txFields.blobVersionedHashes = m1[1].map((h) => ethers.hexlify(h));
            txFields.signature = ethers.Signature.from({
                yParity: Number(m1[2]),
                r: ethers.hexlify(m1[3]),
                s: ethers.hexlify(m1[4]),
            });
            break;
        }
        default:
            return null;
    }

    const tx = ethers.Transaction.from(txFields);
    return { hash: tx.hash, from };
}

function decode_access_list_tuples(tuples) {
    if (!tuples?.length) return [];
    return tuples.map((entry) => ({
        address: ethers.getAddress(entry[0]),
        storageKeys: entry[1] ? entry[1].map((k) => ethers.hexlify(k)) : [],
    }));
}

module.exports = {
    srcChainRPC,
    CHAIN_KEY,
    PROVER_BASE,
    coder,
    LAYOUT_SEGMENTS,
    COMMON_CHUNK_TYPES,
    MIDDLE_CHUNKS_TYPES_BY_TX_TYPE,
    compute_query_id,
    str,
    decode_proof_tx_bytes,
    format_to,
    recover_tx_hash,
};
