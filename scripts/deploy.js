const { ethers, upgrades } = require('hardhat');
const fs = require('fs');
const path = require('path');

// const ERC20Name = "Test";
// const ERC20Symbol = "TEST";

async function deployUSC(
    proceedsAccount,
    ERC20Name,
    ERC20Symbol,
    chainKey,
    timeout,
    lockupDuration,
    approvalThreshold,
    maxInstantMint,
    admin
) {
    console.log(ERC20Name, ERC20Symbol, chainKey, timeout, lockupDuration, approvalThreshold, maxInstantMint, admin);
    if (!ethers.isAddress(admin) || !ethers.isAddress(proceedsAccount)) {
        console.error('admin and proceedsAccount must be correct address');
        process.exit(1);
    }

    if (isNaN(chainKey) || isNaN(timeout)) {
        console.error('chainKey and timeout must be numbers');
        process.exit(1);
    }

    const [owner] = await ethers.getSigners();
    const erc20Contract = await ethers.getContractFactory("ERC20Mintable");
    const erc20 = await erc20Contract.deploy(ERC20Name, ERC20Symbol);
    await erc20.waitForDeployment();

    const proxyFactory = await ethers.getContractFactory('UniversalBridgeProxy');
    const proxy = await upgrades.deployProxy(proxyFactory, [
        lockupDuration,
        approvalThreshold,
        BigInt(maxInstantMint) * BigInt(10 ** 18),
        [admin],
    ]);
    await proxy.waitForDeployment();
    console.log('ERC20 deployed to:', erc20.target);
    console.log('UniversalBridgeProxy deployed to:', proxy.target);
    await erc20.grantRole(await erc20.DEFAULT_ADMIN_ROLE(), proxy.target);
    renameKovan();
}

function renameKovan(){
    const openZeppelinDir = path.join(process.cwd(), '.openzeppelin');
    const kovanPath = path.join(openZeppelinDir, 'kovan.json');
    const ccnextDevnetPath = path.join(openZeppelinDir, 'ccnext_devnet.json');
    if (fs.existsSync(kovanPath)) {
        const kovanContent = fs.readFileSync(kovanPath, 'utf8');
        fs.writeFileSync(ccnextDevnetPath, kovanContent);
        fs.unlinkSync(kovanPath);
    }
}
module.exports = { deployUSC };