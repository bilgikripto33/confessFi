// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ConfessFi} from "../src/ConfessFi.sol";

/**
 * @notice Deploys ConfessFi to Arc Testnet.
 *
 * Usage:
 *   forge script script/Deploy.s.sol:DeployScript \
 *     --rpc-url arc_testnet --broadcast
 *
 * Required env vars (.env in the contract/ folder):
 *   ARC_TESTNET_RPC_URL=https://rpc.testnet.arc.network
 *   PRIVATE_KEY=<your testnet private key, no 0x prefix>
 *   TREASURY_ADDRESS=<wallet that receives the 10% platform fee>
 */
contract DeployScript is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address treasury = vm.envAddress("TREASURY_ADDRESS");

        vm.startBroadcast(deployerKey);
        ConfessFi confessFi = new ConfessFi(treasury);
        vm.stopBroadcast();

        console.log("ConfessFi deployed at:", address(confessFi));
        console.log("Treasury:", treasury);
    }
}
