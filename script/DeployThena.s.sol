// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {IERC20} from "oz/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "oz/proxy/ERC1967/ERC1967Proxy.sol";

import {OptionsToken} from "../src/OptionsToken.sol";
import {DiscountExercise} from "../src/exercise/DiscountExercise.sol";
import {ThenaOracle, IThenaPair} from "../src/oracles/ThenaOracle.sol";
import {IERC20Mintable} from "../src/interfaces/IERC20Mintable.sol";
import {IBalancerTwapOracle} from "../src/interfaces/IBalancerTwapOracle.sol";

contract DeployScript is Script {
    constructor() {}

    function run() public returns (OptionsToken optionsToken, DiscountExercise exercise, ThenaOracle oracle) {
        uint256 deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));

        vm.startBroadcast(deployerPrivateKey);

        {
            IThenaPair thenaPair = IThenaPair(vm.envAddress("BALANCER_POOL"));
            address owner = vm.envAddress("OWNER");
            address targetToken = vm.envAddress("ORACLE_TOKEN");
            uint56 secs = uint56(vm.envUint("ORACLE_SECS"));
            uint128 minPrice = uint128(vm.envUint("ORACLE_MIN_PRICE"));

            oracle = new ThenaOracle(thenaPair, targetToken, owner, secs, minPrice);
        }

        {
            string memory name = vm.envString("OT_NAME");
            string memory symbol = vm.envString("OT_SYMBOL");
            address owner = vm.envAddress("OWNER");
            address tokenAdmin = vm.envAddress("OT_TOKEN_ADMIN");

            address implementation = address(new OptionsToken());
            ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
            optionsToken = OptionsToken(address(proxy));
            optionsToken.initialize(name, symbol, tokenAdmin);
            optionsToken.transferOwnership(owner);
        }

        {
            address owner = vm.envAddress("OWNER");
            uint256 multiplier = vm.envUint("MULTIPLIER");

            address[] memory feeRecipients = vm.envAddress("OT_FEE_RECIPIENTS", ",");
            uint256[] memory feeBps = vm.envUint("OT_FEE_BPS", ",");

            address paymentToken = vm.envAddress("OT_PAYMENT_TOKEN");
            address underlyingToken = vm.envAddress("OT_UNDERLYING_TOKEN");

            exercise = new DiscountExercise(
                optionsToken,
                owner,
                IERC20(paymentToken),
                IERC20(underlyingToken),
                oracle,
                multiplier,
                feeRecipients,
                feeBps
            );
        }

        optionsToken.setExerciseContract(address(exercise), true);

        vm.stopBroadcast();
    }
}
