// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {AsyncSwapHook} from "../src/AsyncSwapHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

contract DeployAsyncSwapHook is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // Official PoolManager addresses
    address constant SEPOLIA_POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address constant ETHEREUM_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant BASE_POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;

    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        uint256 chainId = block.chainid;

        vm.startBroadcast(privateKey);

        // Get the correct PoolManager for this chain
        address poolManagerAddress = getPoolManagerForChain(chainId);
        IPoolManager poolManager = IPoolManager(poolManagerAddress);

        console.log("Using PoolManager:", poolManagerAddress);
        console.log("Chain ID:", chainId);
        console.log("Deployer:", msg.sender);

        // Set hook flags
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);

        // Mine for salt
        bytes memory creationCode = type(AsyncSwapHook).creationCode;
        bytes memory constructorArgs = abi.encode(poolManager);

        (address hookAddress, bytes32 salt) = HookMiner.find(CREATE2_DEPLOYER, flags, creationCode, constructorArgs);

        // Deploy hook
        AsyncSwapHook hook = new AsyncSwapHook{salt: salt}(poolManager);

        require(address(hook) == hookAddress, "Hook address mismatch");

        console.log("\n=== Deployment Successful ===");
        console.log("Hook Address:", address(hook));
        console.log("Configuration:");
        console.log("- LIQUIDITY_THRESHOLD_BPS:", hook.LIQUIDITY_THRESHOLD_BPS());
        console.log("- MIN_DELAY:", hook.MIN_DELAY(), "seconds");
        console.log("- EXECUTION_WINDOW:", hook.EXECUTION_WINDOW(), "seconds");
        console.log("- MAX_PENDING_TIME:", hook.MAX_PENDING_TIME(), "seconds");
        console.log("- EXECUTOR_FEE_BPS:", hook.EXECUTOR_FEE_BPS());
        console.log("============================\n");

        vm.stopBroadcast();
    }

    function getPoolManagerForChain(uint256 chainId) internal pure returns (address) {
        if (chainId == 11155111) return SEPOLIA_POOL_MANAGER; // Sepolia
        if (chainId == 1) return ETHEREUM_POOL_MANAGER; // Ethereum
        if (chainId == 8453) return BASE_POOL_MANAGER; // Base
        revert("Unsupported chain");
    }
}
