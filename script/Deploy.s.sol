// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/StreamPay.sol";

/// @dev Deploy StreamPay to Arc testnet:
///      forge script script/Deploy.s.sol \
///        --rpc-url https://rpc.testnet.arc.network \
///        --broadcast \
///        --private-key $PRIVATE_KEY
contract Deploy is Script {

    address constant USDC = 0x3600000000000000000000000000000000000000;

    function run() external {
        uint256 pk       = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        console.log("=================================================");
        console.log("  StreamPay Protocol - Arc Testnet Deploy");
        console.log("=================================================");
        console.log("Deployer: ", deployer);
        console.log("Chain ID: ", block.chainid);
        console.log("USDC:     ", USDC);
        console.log("-------------------------------------------------");

        vm.startBroadcast(pk);
        StreamPay streampay = new StreamPay();
        vm.stopBroadcast();

        console.log("StreamPay deployed:", address(streampay));
        console.log("Explorer: https://testnet.arcscan.app/address/", address(streampay));
        console.log("=================================================");
        console.log("Paste into web/index.html:");
        console.log("  let STREAMPAY_ADDR =", address(streampay));
        console.log("=================================================");
    }
}
