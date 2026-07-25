// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {Position} from "../src/Position.sol";
import {PositionFactory} from "../src/PositionFactory.sol";

/// forge script script/Deploy.s.sol --rpc-url base --broadcast
contract Deploy is Script {
    // Base (8453)
    address constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant AAVE_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address constant BEBOP_ROUTER = 0xBeb0009ACa35087ce7cCF11637E24dd1Aad3bf2A;
    address constant BEBOP_SETTLEMENT = 0xbbbbbBB520d69a9775E85b458C58c648259FAD5F;

    function run() external {
        vm.startBroadcast();
        Position impl = new Position(MORPHO, AAVE_POOL, BEBOP_ROUTER, BEBOP_SETTLEMENT);
        PositionFactory factory = new PositionFactory(address(impl));
        vm.stopBroadcast();

        // consumed by ../server.ts for the local test harness
        string memory obj = "d";
        vm.serializeAddress(obj, "impl", address(impl));
        string memory out = vm.serializeAddress(obj, "factory", address(factory));
        vm.writeJson(out, "./addresses.json");
    }
}
