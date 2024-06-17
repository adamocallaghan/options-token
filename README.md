# OptionsToken

An options token representing the right to exercise any one of the whitelisted exercise contracts, allowing the user to receive different forms of discounted assets in return for the appropriate payment. The option does not expire. The options token receives user input and a specified exercise contract address, passing through to the exercise contract to execute the option. We fork https://github.com/timeless-fi/options-token, which is a simple implementation of an option for discounted tokens at an adjusted oracle rate. Here, we divorce the exercise functionality from the token contract, and allow an admin to whitelist and fund exercise contracts as the desired. We also implement more potential oracle types, and make several other minor changes.

We want to ensure there are no attacks on pricing in DiscountExercise, atomically or otherwise, in each oracle implementation.  We want to ensure users will never pay more than maxPaymentAmount. When properly specified, this should ensure users experience no more deviation in price than they specify.

Given the nature of this token, it is fine for the admin to have some centralized permissions (admin can mint tokens, admin is the one who funds exercise contracts, etc).  The team is responsible for refilling the exercise contracts. We limit the amount of funds we leave in an exercise contract at any given time to limit risk.  

# Flow of an Option Token Exercise (Ex. Discount Exercise)

The user will always interact with the OptionsToken itself, and never with any exercise contract directly.

1. The user approves OptionsToken the amount of WETH they wish to spend
2. User calls exercise on the OptionsToken, specifying their desired exercise contract and encoding exercise parameters
3. OptionsToken validates the exercise contract, decodes the parameters for the exercise function on the exercise contract of choice, and calls said function. In the case of DiscountExercise, the params are maxPaymentAmount and deadline.
4. oTokens are burnt, WETH is sent to the treasury, and underlyingTokens, discounted by the multiplier, are sent to the user exercising
    a. Can be priced using balancer, thena, univ3 twap oracles
    b. Reverts above maxPaymentAmount or past deadline


## Installation

To install with [DappTools](https://github.com/dapphub/dapptools):

```
dapp install timeless-fi/options-token
```

To install with [Foundry](https://github.com/gakonst/foundry):

```
forge install timeless-fi/options-token
```

## Local development

This project uses [Foundry](https://github.com/gakonst/foundry) as the development framework.

### Dependencies

```
forge install
```

Install Sablier contracts and dependencies. This will create and place then into node_modules

```
bun add @sablier/v2-core @sablier/v2-periphery
```

And add the remappings

```
"@sablier/v2-core=node_modules/@sablier/v2-core/" >> remappings.txt
"@sablier/v2-periphery=node_modules/@sablier/v2-periphery/" >> remappings.txt
"@openzeppelin/contracts/=node_modules/@openzeppelin/contracts/" >> remappings.txt
"@prb/math/=node_modules/@prb/math/" >> remappings.txt```
```
### Compilation

```
forge build
```

### Testing

```
forge test
```