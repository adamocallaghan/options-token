import { ethers, upgrades } from "hardhat";
import { getImplementationAddress } from '@openzeppelin/upgrades-core';

async function main() {
  const thenaPair = process.env.ORACLE_SOURCE;
  const targetToken = process.env.OT_UNDERLYING_TOKEN;
  const owner = process.env.OWNER;
  const secs = process.env.ORACLE_SECS;
  const minPrice = process.env.ORACLE_MIN_PRICE;
  
  const oracle = await ethers.deployContract(
    "ThenaOracle",
    [thenaPair, targetToken, owner, secs, minPrice]
  );
  await oracle.waitForDeployment();
  console.log(`Oracle deployed to: ${await oracle.getAddress()}`);
  
  // OptionsToken
  const tokenName = process.env.OT_NAME;
  const symbol = process.env.OT_SYMBOL;
  const tokenAdmin = process.env.OT_TOKEN_ADMIN;
  const OptionsToken = await ethers.getContractFactory("OptionsToken");
  const optionsToken = await upgrades.deployProxy(
    OptionsToken,
    [tokenName, symbol, tokenAdmin],
    { kind: "uups", initializer: "initialize" }
  );

  await optionsToken.waitForDeployment();
  console.log(`OptionsToken deployed to: ${await optionsToken.getAddress()}`);
  console.log(`Implementation: ${await getImplementationAddress(ethers.provider, await optionsToken.getAddress())}`);

  // Exercise
  const paymentToken = process.env.OT_PAYMENT_TOKEN;
  const multiplier = process.env.MULTIPLIER;
  const feeRecipients = String(process.env.FEE_RECIPIENTS).split(",");
  const feeBps = String(process.env.FEE_BPS).split(",");

  const exercise = await ethers.deployContract(
    "DiscountExercise",
    [
      await optionsToken.getAddress(),
      owner,
      paymentToken,
      targetToken,
      await oracle.getAddress(),
      multiplier,
      feeRecipients,
      feeBps
    ]
  );
  await exercise.waitForDeployment();
  console.log(`Exercise deployed to: ${await exercise.getAddress()}`);

  // Set exercise
  const exerciseAddress = await exercise.getAddress();
  await optionsToken.setExerciseContract(exerciseAddress, true);
  console.log(`Exercise set to: ${exerciseAddress}`);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
