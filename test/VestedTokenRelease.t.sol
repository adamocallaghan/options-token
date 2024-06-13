// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import {VestedTokenRelease} from "../src/exercise/VestedTokenRelease.sol";
import {OptionsToken} from "../src/OptionsToken.sol";

import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {IERC20} from "oz/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "oz/proxy/ERC1967/ERC1967Proxy.sol";

import {TestERC20} from "./mocks/TestERC20.sol";


contract VestedTokenReleaseTest is Test {
    using FixedPointMathLib for uint256;

    uint16 constant PRICE_MULTIPLIER = 5000; // 0.5
    uint56 constant SECS = 30 minutes;
    uint128 constant MIN_PRICE = 1e17;
    uint256 constant MIN_PRICE_DENOM = 10000;
    uint256 constant MAX_SUPPLY = 1e27; // the max supply of the options token & the underlying token

    address owner;
    address tokenAdmin;
    address[] feeRecipients_;
    uint256[] feeBPS_;

    OptionsToken optionsToken;
    VestedTokenRelease exerciser;
    TestERC20 paymentToken;
    address underlyingToken;

    uint256 price;
  
    function setUp() public {
        // set up accounts
        owner = makeAddr("owner");
        tokenAdmin = makeAddr("tokenAdmin");

        feeRecipients_ = new address[](2);
        feeRecipients_[0] = makeAddr("feeRecipient");
        feeRecipients_[1] = makeAddr("feeRecipient2");

        feeBPS_ = new uint256[](2);
        feeBPS_[0] = 1000; // 10%
        feeBPS_[1] = 9000; // 90%

        // deploy contracts
        paymentToken = address (new TestERC20());
        underlyingToken = address(new TestERC20());

        address implementation = address(new OptionsToken());
        ERC1967Proxy proxy = new ERC1967Proxy(implementation, "");
        optionsToken = OptionsToken(address(proxy));
        optionsToken.initialize("VESTED Call Option Token", "oVEST", tokenAdmin);
        optionsToken.transferOwnership(owner);

        address[] memory tokens = new address[](2);
        tokens[0] = paymentToken;
        tokens[1] = underlyingToken;

        price = 1e18;

        //@todo need a mock oracle
        exerciser = new VestedTokenRelease(
            optionsToken,
            owner,
            IERC20(paymentToken),
            IERC20(underlyingToken),
            price,
            PRICE_MULTIPLIER, // 50% discount
            feeRecipients_,
            feeBPS_
        );

        TestERC20(underlyingToken).mint(address(exerciser), 1e20 ether);

        // add exerciser to the list of options
        vm.startPrank(owner);
        optionsToken.setExerciseContract(address(exerciser), true);
        vm.stopPrank();

        // set up contracts
        paymentToken.approve(address(exerciser), type(uint256).max);
    }

    function test_vestedOnlyTokenAdminCanMint(uint256 amount, address hacker) public {
        vm.assume(hacker != tokenAdmin);

        // try minting as non token admin
        vm.startPrank(hacker);
        vm.expectRevert(OptionsToken.OptionsToken__NotTokenAdmin.selector);
        optionsToken.mint(address(this), amount);
        vm.stopPrank();

        // mint as token admin
        vm.prank(tokenAdmin);
        optionsToken.mint(address(this), amount);

        // verify balance
        assertEqDecimal(optionsToken.balanceOf(address(this)), amount, 18);
    }


}