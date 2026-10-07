// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {AssetRouter} from "../contracts/AssetRouter.sol";

contract Deploy is Script {
    function run() external returns (AssetRouter router) {
        vm.startBroadcast();
        router = new AssetRouter();
        vm.stopBroadcast();
    }
}
