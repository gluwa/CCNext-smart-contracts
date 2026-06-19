import { ethers } from "hardhat";
import {
  buildProverProofUrl,
  fetchProverApiProofFromUrl,
  packBridgeProofsFromProverApi
} from "./prover";

export const PROVER_REORG_WINDOW_BLOCKS = 32;
export const PROVER_INDEX_POLL_MS = 10_000;
export const PROVER_INDEX_MAX_ATTEMPTS = 180;
export const NONCE_SYNC_POLL_MS = 5_000;
export const NONCE_SYNC_TIMEOUT_MS = 600_000;

export const LOAN_REGISTER_EIP712_DOMAIN_NAME = "SourceLoanRegistry";
export const LOAN_REGISTER_EIP712_DOMAIN_VERSION = "1";

export const LOAN_REGISTER_EIP712_TYPES = {
  LoanRegister: [
    { name: "loanId", type: "uint256" },
    { name: "fundFrom", type: "address" },
    { name: "fundTo", type: "address" },
    { name: "fundToken", type: "address" },
    { name: "repayFrom", type: "address" },
    { name: "repayTo", type: "address" },
    { name: "repayToken", type: "address" },
    { name: "loanAmount", type: "uint256" },
    { name: "interestRate", type: "uint256" },
    { name: "expectedRepaymentAmount", type: "uint256" },
    { name: "deadlineTimestamp", type: "uint256" }
  ]
} as const;
export const LOAN_TERMS_TYPE =
  "tuple(uint256 loanAmount, uint256 interestRate, uint256 expectedRepaymentAmount, uint256 deadlineTimestamp)";

export const LOAN_REGISTERED_EVENT_SIG =
  "0x4150dd864303d6b1464100e690e63c0ea11347decbb123e909018da0470f9870";
export const LOAN_FUNDED_EVENT_SIG =
  "0x9e71d2fb732e68272b7e74ecfd14638673c1d77e19a5d390a3ffff054d57c44b";
export const LOAN_REPAID_EVENT_SIG =
  "0x040cee90ee4799897c30ca04e5feb6fa43dbba9b6d084b4b257cdafd84ba013e";

export type LoanFlow = { from: string; to: string; withToken: string };
export type LoanTerms = {
  loanAmount: bigint;
  interestRate: bigint;
  expectedRepaymentAmount: bigint;
  deadlineTimestamp: bigint;
};

export type ProofTarget = {
  txHash: string;
  blockNumber: number;
  txIndex: number;
  proofUrl: string;
  head: number;
  blocksUntilConfirmed: number;
};

export function requireEnv(name: string): string {
  const value = (process.env[name] ?? "").trim();
  if (!value) throw new Error(`Missing required env var: ${name}`);
  return value;
}

export function optionalEnv(name: string): string {
  return (process.env[name] ?? "").trim();
}

export function requireAddress(name: string, value: string): string {
  if (!value) throw new Error(`Missing required env var: ${name}`);
  const trimmed = value.replace(/\s+/g, "");
  if (!/^0x[0-9a-fA-F]{40}$/.test(trimmed)) {
    throw new Error(
      `${name} is not a valid address (got "${value}"). ` +
        `Each 0x address must be 42 characters on a single line in .env — no line wraps.`
    );
  }
  return ethers.getAddress(trimmed);
}

export function isReuseAddress(address: string): boolean {
  if (!address) return false;
  try {
    return ethers.getAddress(address) !== ethers.ZeroAddress;
  } catch {
    return false;
  }
}

export function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

export async function walletFromEnv(envVar: string, fallback: ethers.Signer | null) {
  const pk = optionalEnv(envVar);
  if (pk) {
    const provider = ethers.provider;
    return new ethers.Wallet(pk, provider);
  }
  if (!fallback) throw new Error(`Missing ${envVar} and no fallback signer`);
  return fallback;
}

export async function readNonce(address: string) {
  const [latest, pending] = await Promise.all([
    ethers.provider.getTransactionCount(address, "latest"),
    ethers.provider.getTransactionCount(address, "pending")
  ]);
  return { latest, pending, inFlight: pending - latest };
}

export async function waitForNonceReady(address: string): Promise<number> {
  const start = Date.now();
  while (Date.now() - start < NONCE_SYNC_TIMEOUT_MS) {
    const s = await readNonce(address);
    if (s.inFlight === 0) return s.latest;
    await sleep(NONCE_SYNC_POLL_MS);
  }
  const s = await readNonce(address);
  throw new Error(
    `Timed out waiting for pending txs (latest=${s.latest}, inFlight=${s.inFlight})`
  );
}

export function decodeRegisterLoanCalldata(data: string): {
  loanId: bigint;
  fundFlow: LoanFlow;
  repayFlow: LoanFlow;
  loanTerms: LoanTerms;
} | null {
  const selector = ethers.id(
    "registerLoan(uint256,(address,address,address),(address,address,address),(uint256,uint256,uint256,uint256),bytes,bytes)"
  ).slice(0, 10);
  if (!data.toLowerCase().startsWith(selector)) return null;

  const coder = ethers.AbiCoder.defaultAbiCoder();
  const decoded = coder.decode(
    [
      "uint256",
      "tuple(address,address,address)",
      "tuple(address,address,address)",
      "tuple(uint256,uint256,uint256,uint256)",
      "bytes",
      "bytes"
    ],
    "0x" + data.slice(10)
  );

  const fund = decoded[1] as [string, string, string];
  const repay = decoded[2] as [string, string, string];
  const terms = decoded[3] as [bigint, bigint, bigint, bigint];

  return {
    loanId: decoded[0] as bigint,
    fundFlow: { from: fund[0], to: fund[1], withToken: fund[2] },
    repayFlow: { from: repay[0], to: repay[1], withToken: repay[2] },
    loanTerms: {
      loanAmount: terms[0],
      interestRate: terms[1],
      expectedRepaymentAmount: terms[2],
      deadlineTimestamp: terms[3]
    }
  };
}

export function decodeRegisterLoanFromTxBytes(txBytes: string) {
  const coder = ethers.AbiCoder.defaultAbiCoder();
  const [, chunks] = coder.decode(["uint8", "bytes[]"], txBytes);
  const [, , , , , , data] = coder.decode(
    ["uint64", "uint64", "address", "bool", "address", "uint256", "bytes"],
    chunks[0]
  );
  return decodeRegisterLoanCalldata(String(data));
}

export function loanRegisterTypedDataValue(
  loanId: bigint,
  fundFlow: LoanFlow,
  repayFlow: LoanFlow,
  loanTerms: LoanTerms
) {
  return {
    loanId,
    fundFrom: fundFlow.from,
    fundTo: fundFlow.to,
    fundToken: fundFlow.withToken,
    repayFrom: repayFlow.from,
    repayTo: repayFlow.to,
    repayToken: repayFlow.withToken,
    loanAmount: loanTerms.loanAmount,
    interestRate: loanTerms.interestRate,
    expectedRepaymentAmount: loanTerms.expectedRepaymentAmount,
    deadlineTimestamp: loanTerms.deadlineTimestamp
  };
}

export function loanRegisterEip712Domain(chainId: bigint, verifyingContract: string) {
  return {
    name: LOAN_REGISTER_EIP712_DOMAIN_NAME,
    version: LOAN_REGISTER_EIP712_DOMAIN_VERSION,
    chainId,
    verifyingContract
  };
}

/** @deprecated Use signLoanRegisterTypedData for EIP-712 bound signatures. */
export function loanRegisterMessageHash(
  fundFlow: LoanFlow,
  repayFlow: LoanFlow,
  loanTerms: LoanTerms
): string {
  return ethers.solidityPackedKeccak256(
    [
      "address",
      "address",
      "address",
      "address",
      "address",
      "address",
      "uint256",
      "uint256",
      "uint256",
      "uint256"
    ],
    [
      fundFlow.from,
      fundFlow.to,
      fundFlow.withToken,
      repayFlow.from,
      repayFlow.to,
      repayFlow.withToken,
      loanTerms.loanAmount,
      loanTerms.interestRate,
      loanTerms.expectedRepaymentAmount,
      loanTerms.deadlineTimestamp
    ]
  );
}

export async function signLoanRegisterTypedData(
  signer: ethers.Signer,
  registryAddress: string,
  loanId: bigint,
  fundFlow: LoanFlow,
  repayFlow: LoanFlow,
  loanTerms: LoanTerms
): Promise<string> {
  const network = await signer.provider!.getNetwork();
  const domain = loanRegisterEip712Domain(network.chainId, registryAddress);
  const value = loanRegisterTypedDataValue(loanId, fundFlow, repayFlow, loanTerms);
  return signer.signTypedData(domain, LOAN_REGISTER_EIP712_TYPES, value);
}

export function plainRegisterLoanArgs(
  loanId: bigint,
  fundFlow: LoanFlow,
  repayFlow: LoanFlow,
  loanTerms: LoanTerms,
  sigLender: string,
  sigBorrower: string
) {
  return [
    loanId,
    {
      from: fundFlow.from,
      to: fundFlow.to,
      withToken: fundFlow.withToken
    },
    {
      from: repayFlow.from,
      to: repayFlow.to,
      withToken: repayFlow.withToken
    },
    {
      loanAmount: loanTerms.loanAmount,
      interestRate: loanTerms.interestRate,
      expectedRepaymentAmount: loanTerms.expectedRepaymentAmount,
      deadlineTimestamp: loanTerms.deadlineTimestamp
    },
    sigLender,
    sigBorrower
  ] as const;
}

export function loanKeyBytes32(chainKey: string, sourceLoanId: bigint): string {
  return ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(["bytes32", "uint256"], [chainKey, sourceLoanId])
  );
}

export async function resolveProofTarget(
  txHashOrReceipt: string | ethers.TransactionReceipt,
  chainKey = Number(process.env.SOURCE_CHAIN_KEY ?? "1")
): Promise<ProofTarget> {
  let receipt: ethers.TransactionReceipt | null;
  let txHash: string;

  if (typeof txHashOrReceipt === "string") {
    txHash = txHashOrReceipt;
    receipt = await ethers.provider.getTransactionReceipt(txHash);
  } else {
    receipt = txHashOrReceipt;
    txHash = receipt.hash;
  }

  if (!receipt) throw new Error(`Receipt not found: ${txHash}`);
  if (receipt.status !== 1) throw new Error(`Transaction failed: ${txHash}`);

  const blockNumber = receipt.blockNumber;
  const txIndex = receipt.index;
  const proofUrl = buildProverProofUrl(chainKey, blockNumber, txIndex);
  const head = await ethers.provider.getBlockNumber();
  const blocksUntilConfirmed = Math.max(0, blockNumber + PROVER_REORG_WINDOW_BLOCKS - head);

  return { txHash, blockNumber, txIndex, proofUrl, head, blocksUntilConfirmed };
}

export function printProofTarget(t: ProofTarget) {
  console.log(`txHash:   ${t.txHash}`);
  console.log(`block:    ${t.blockNumber}`);
  console.log(`txIndex:  ${t.txIndex}`);
  console.log(`proofUrl: ${t.proofUrl}`);
  if (t.blocksUntilConfirmed > 0) {
    console.log(`reorg window: ~${t.blocksUntilConfirmed} block(s) remaining`);
  }
}

function parseProverError(err: unknown) {
  const msg = err instanceof Error ? err.message : String(err);
  const start = msg.indexOf("{");
  if (start < 0) return { msg, body: null as any };
  try {
    return { msg, body: JSON.parse(msg.slice(start)) };
  } catch {
    return { msg, body: null as any };
  }
}

export async function waitForProver(label: string, target: ProofTarget, skip = false) {
  if (skip) {
    console.log(`Skipping prover poll for ${label}.`);
    return null;
  }

  console.log(`Polling prover for "${label}"…`);
  const startMs = Date.now();

  for (let attempt = 1; attempt <= PROVER_INDEX_MAX_ATTEMPTS; attempt++) {
    try {
      const proof = await fetchProverApiProofFromUrl(target.proofUrl);
      const elapsed = ((Date.now() - startMs) / 1000).toFixed(0);
      console.log(`Prover indexed "${label}" after ${elapsed}s`);
      return proof;
    } catch (err) {
      const { msg, body } = parseProverError(err);
      if (body?.code === "BlockNotOnSourceChain") {
        const head = await ethers.provider.getBlockNumber();
        const remaining = Math.max(0, target.blockNumber + PROVER_REORG_WINDOW_BLOCKS - head);
        console.log(
          `  attempt ${attempt}/${PROVER_INDEX_MAX_ATTEMPTS}: BlockNotOnSourceChain (~${remaining} blocks left)`
        );
      } else if (body?.retriable) {
        console.log(`  attempt ${attempt}/${PROVER_INDEX_MAX_ATTEMPTS}: ${body.code}`);
      } else {
        console.log(`  attempt ${attempt}/${PROVER_INDEX_MAX_ATTEMPTS}: ${msg}`);
      }
    }
    await sleep(PROVER_INDEX_POLL_MS);
  }

  console.log(`Prover not ready for "${label}".`);
  return null;
}

export async function fetchProof(url: string) {
  if (!url) return null;
  console.log("Fetching proof:", url);
  const raw = await fetchProverApiProofFromUrl(url);
  const packed = packBridgeProofsFromProverApi(raw);
  return { raw, packed };
}

export function decodeReceiptFromTxBytes(txBytes: string) {
  const coder = ethers.AbiCoder.defaultAbiCoder();
  const [txType, chunks] = coder.decode(["uint8", "bytes[]"], txBytes);
  const receiptIdx = Number(txType) <= 2 ? 2 : 3;
  const [status, gasUsed, rawLogs] = coder.decode(
    ["uint8", "uint64", "tuple(address, bytes32[], bytes)[]", "bytes"],
    chunks[receiptIdx]
  );
  const logs = Array.from(rawLogs).map((log: any) => ({
    address_: log[0],
    topics: Array.from(log[1] as any),
    data: log[2]
  }));
  return { status: Number(status), gasUsed, logs };
}

export function filterLogsBySignature(logs: any[], eventSig: string) {
  return logs.filter(
    (log) => log.topics.length > 0 && log.topics[0].toLowerCase() === eventSig.toLowerCase()
  );
}

export function chainKeyBytes32(chainKey: number | string): string {
  const n = BigInt(chainKey);
  return ethers.zeroPadValue(ethers.toBeHex(n), 32);
}
