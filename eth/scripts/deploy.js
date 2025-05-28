const { ethers, upgrades } = require('hardhat');
async function deployUSC(
    proceedsAccount,
    costPerByte,
    baseFee,
    chainKey,
    displayName,
    timeout,
    lockupDuration,
    approvalThreshold,
    maxInstantMint,
    admin
) {
    if (!ethers.isAddress(admin) || !ethers.isAddress(proceedsAccount)) {
        console.error('admin and proceedsAccount must be correct address');
        process.exit(1);
    }

    if (isNaN(chainKey) || isNaN(timeout)) {
        console.error('chainKey and timeout must be numbers');
        process.exit(1);
    }

    const [owner] = await ethers.getSigners();
    const proverFactory = await ethers.getContractFactory('CreditcoinPublicProver');
    const prover = await proverFactory.deploy(
        proceedsAccount,
        costPerByte,
        baseFee,
        chainKey,
        displayName,
        timeout
    );
    await prover.waitForDeployment();

    const proxyFactory = await ethers.getContractFactory('UniversalBridgeProxy');
    const proxy = await upgrades.deployProxy(proxyFactory, [
        lockupDuration,
        approvalThreshold,
        BigInt(maxInstantMint) * BigInt(10 ** 18),
        [admin],
    ]);
    await proxy.waitForDeployment();
    console.log('Prover deployed to:', prover.target);
    console.log('UniversalBridgeProxy deployed to:', proxy.target);
}

module.exports = { deployUSC };