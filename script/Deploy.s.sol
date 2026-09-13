// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {FuguiToken} from "../src/tokens/FuguiToken.sol";
import {StockToken} from "../src/tokens/StockToken.sol";
import {StaticOracle} from "../src/oracle/StaticOracle.sol";
import {FuguiBank} from "../src/bank/FuguiBank.sol";
import {BankNote} from "../src/bank/BankNote.sol";
import {LhbRewards} from "../src/lhb/LhbRewards.sol";
import {FuguiTreasury} from "../src/bank/FuguiTreasury.sol";
import {MockExchange} from "../src/mocks/MockExchange.sol";

/// @title Deploy
/// @notice Full FUGUI Finance testnet deployment (Robinhood Chain testnet, chain 46630).
/// @dev    forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast
contract Deploy is Script {
    // bootstrap market prices (FUGUI per 1 stock token)
    uint256 constant NVDA_PRICE = 1000 ether; // 1 tNVDA = 1000 FUGUI
    uint256 constant GME_PRICE = 30 ether; // 1 tGME = 30 FUGUI

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk); // deployer is unreliable inside scripts
        vm.startBroadcast(pk);

        // ---------------------------------------------------------- tokens
        FuguiToken fugui = new FuguiToken(1_000_000_000 ether);
        StockToken nvda = new StockToken("NVIDIA Stock Token", "tNVDA", "NVDA", "FUGUI Finance (Test Issuer)");
        StockToken gme = new StockToken("GameStop Stock Token", "tGME", "GME", "FUGUI Finance (Test Issuer)");

        // ------------------------------------------------------- infra
        MockExchange exchange = new MockExchange();
        StaticOracle oracle = new StaticOracle();
        FuguiTreasury treasury = new FuguiTreasury();
        LhbRewards rewards = new LhbRewards();
        BankNote note = new BankNote();
        FuguiBank bank =
            new FuguiBank(address(oracle), address(exchange), address(note), address(treasury));

        // -------------------------------------------------------- wiring
        note.setBank(address(bank));
        note.grantRole(note.ROLE_MINTER(), address(bank));

        bank.setTokenSupport(0, address(fugui), true); // meme whitelist
        bank.setTokenSupport(1, address(nvda), true); // stock whitelist
        bank.setTokenSupport(1, address(gme), true);

        // deployer becomes the oracle price setter (hand to a keeper bot later)
        oracle.grantRole(oracle.ROLE_SETTER(), deployer);

        rewards.grantRole(rewards.ROLE_RANKER(), deployer);
        rewards.grantRole(rewards.ROLE_FUNDER(), deployer);

        // ------------------------------------------- market bootstrap
        nvda.mint(deployer, 20_000 ether);
        gme.mint(deployer, 120_000 ether);
        fugui.approve(address(exchange), type(uint256).max);
        nvda.approve(address(exchange), type(uint256).max);
        gme.approve(address(exchange), type(uint256).max);

        exchange.addLiquidity(address(fugui), address(nvda), 10_000_000 ether, 10_000 ether);
        exchange.addLiquidity(address(fugui), address(gme), 3_000_000 ether, 100_000 ether);

        oracle.setPrice(address(nvda), address(fugui), NVDA_PRICE);
        oracle.setPrice(address(gme), address(fugui), GME_PRICE);

        // --------------------------------------------- prize pool seed
        nvda.mint(address(treasury), 2_000 ether);

        vm.stopBroadcast();

        // -------------------------------------------------- artifacts
        string memory obj = "deploy";
        vm.serializeAddress(obj, "network", 0xE55Db005A1906CB01076Dc5D007Ac55d7CaBCb5a);
        vm.serializeAddress(obj, "fuguiToken", address(fugui));
        vm.serializeAddress(obj, "stockTokenNVDA", address(nvda));
        vm.serializeAddress(obj, "stockTokenGME", address(gme));
        vm.serializeAddress(obj, "exchange", address(exchange));
        vm.serializeAddress(obj, "oracle", address(oracle));
        vm.serializeAddress(obj, "treasury", address(treasury));
        vm.serializeAddress(obj, "lhbRewards", address(rewards));
        vm.serializeAddress(obj, "bankNote", address(note));
        string memory finalJson = vm.serializeAddress(obj, "fuguiBank", address(bank));
        vm.writeJson(finalJson, "deployments/robinhood-testnet.json");

        console2.log("FUGUI        :", address(fugui));
        console2.log("tNVDA        :", address(nvda));
        console2.log("tGME         :", address(gme));
        console2.log("Exchange     :", address(exchange));
        console2.log("Oracle       :", address(oracle));
        console2.log("Treasury     :", address(treasury));
        console2.log("LhbRewards   :", address(rewards));
        console2.log("BankNote     :", address(note));
        console2.log("FuguiBank    :", address(bank));
    }
}
