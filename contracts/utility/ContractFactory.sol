// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract ContractFactory is Ownable {
    event ProxyDeployed(address indexed proxyAddress, bytes32 salt);
    event ContractDeployed(address contractAddress);

    constructor(address initialOwner) Ownable(initialOwner) {}

    function deployWithProxy(
        address logic,
        address admin,
        bytes32 salt,
        bytes memory data
    ) external onlyOwner returns (address proxyAddress) {
        bytes memory bytecode = abi.encodePacked(
            type(TransparentUpgradeableProxy).creationCode,
            abi.encode(logic, admin, data)
        );

        assembly {
            proxyAddress := create2(0, add(bytecode, 32), mload(bytecode), salt)
            if iszero(extcodesize(proxyAddress)) {
                revert(0, 0)
            }
        }

        emit ProxyDeployed(proxyAddress, salt);
    }

    function deploy(
        bytes32 salt,
        bytes memory bytecode
    ) external returns (address deployedAddress) {
        require(bytecode.length > 0, "Bytecode is empty");

        assembly {
            deployedAddress := create2(
                0,
                add(bytecode, 32),
                mload(bytecode),
                salt
            )
        }

        require(deployedAddress != address(0), "Deployment failed");

        emit ContractDeployed(deployedAddress);
    }

    function computeAddress(
        bytes32 salt,
        address deployer
    ) external pure returns (address) {
        return
            address(
                uint160(
                    uint(
                        keccak256(
                            abi.encodePacked(
                                bytes1(0xff),
                                deployer,
                                salt,
                                keccak256(
                                    abi.encodePacked(
                                        type(TransparentUpgradeableProxy)
                                            .creationCode
                                    )
                                )
                            )
                        )
                    )
                )
            );
    }
}
