// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/AgentQuests.sol";

/// @notice Deploy AgentQuests to BNB Chain (mainnet or testnet).
/// @dev The constructor takes an explicit `initialOwner` (NOT msg.sender):
///      the production deploy goes through the Arachnid CREATE2 factory
///      (0x4e59b44847b379578588920cA78FbF26c0B4956C), where the factory is
///      msg.sender inside the constructor. Passing the owner as a parameter
///      keeps ownership with the real deployer (same fix as AVSC v3).
///      No other constructor arguments.
///      The Agent ID registry address is a constant in the contract, so on
///      BSC testnet the quest functions will revert (no registry there) —
///      testnet deploys only validate deployment mechanics. For end-to-end
///      testing use a BSC mainnet fork (see README.md) or the unit tests.
///
///      Usage (DO NOT run against mainnet without the owner's explicit go-ahead):
///        forge script script/Deploy.s.sol --rpc-url <RPC> --broadcast --private-key <KEY>
///      Verify on BscScan afterwards:
///        forge verify-contract <ADDRESS> src/AgentQuests.sol:AgentQuests \
///          --chain bsc --verifier etherscan --etherscan-api-key <KEY> \
///          --optimizer-runs 1 --constructor-args $(cast abi-encode "constructor(address)" <OWNER>)
contract Deploy is Script {
    function run() external returns (AgentQuests) {
        vm.startBroadcast();
        AgentQuests quests = new AgentQuests(msg.sender);
        vm.stopBroadcast();
        return quests;
    }
}
