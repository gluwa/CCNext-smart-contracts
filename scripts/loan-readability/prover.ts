import { ethers } from "ethers";

export type ProverApiProofResponse = {
  chainKey: number;
  headerNumber: number;
  txIndex: number;
  txHash: string;
  txBytes: string;
  merkleProof: {
    root: string;
    siblings: Array<{ hash: string; isLeft: boolean }>;
  };
  continuityProof: {
    lowerEndpointDigest: string;
    roots: string[];
  };
};

const MERKLE_SIBLING_TYPE = "tuple(bytes32 sibling,bool isLeft)";

export function packBridgeProofsFromProverApi(proof: ProverApiProofResponse) {
  const siblings = proof.merkleProof.siblings.map((s) => ({
    sibling: s.hash,
    isLeft: s.isLeft
  }));

  const inclusionProof = {
    kind: 0,
    root: proof.merkleProof.root,
    data: ethers.AbiCoder.defaultAbiCoder().encode(
      ["bytes", `${MERKLE_SIBLING_TYPE}[]`],
      [proof.txBytes, siblings]
    )
  };

  const continuityProof = {
    lowerEndpointDigest: proof.continuityProof.lowerEndpointDigest,
    roots: proof.continuityProof.roots
  };

  return { inclusionProof, continuityProof, txBytes: proof.txBytes };
}

export async function fetchProverApiProofFromUrl(
  proofUrl: string
): Promise<ProverApiProofResponse> {
  const res = await fetch(proofUrl.trim());
  if (!res.ok) {
    throw new Error(`Prover API ${res.status}: ${await res.text()}`);
  }
  return (await res.json()) as ProverApiProofResponse;
}

export function buildProverProofUrl(
  chainKey: number | string,
  blockHeight: number,
  txIndex: number,
  baseUrl = process.env.PROOF_BUILDER_URL ?? "https://prover.cc3-testnet.creditcoin.network"
): string {
  return `${baseUrl.replace(/\/$/, "")}/api/v1/proof/${chainKey}/${blockHeight}/${txIndex}`;
}
