import { Wallet, utils } from 'zksync-web3';
import { ethers } from 'hardhat';
import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { Deployer } from '@matterlabs/hardhat-zksync-deploy';

// An example of a deploy script that will deploy and call a simple contract.
export default async function (hre: HardhatRuntimeEnvironment) {
  console.log(`Running deploy script for the unilend contract`);

  const wethAddress = '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2';

  // Initialize the wallet.
  const wallet = new Wallet(
    '0x76d9f1a35854375d5838320a21efea0de52be68b4654ba61b358bc47adf176ab'
  );

  // Create deployer object and load the artifact of the contract you want to deploy.
  const deployer = new Deployer(hre, wallet);
  const pool = await deployer.loadArtifact('UnilendV2Pool');
  const core = await deployer.loadArtifact('UnilendV2Core');
  const oracle = await deployer.loadArtifact('UnilendV2oracle');
  const position = await deployer.loadArtifact('UnilendV2Position');
  const UnilendInterestRateModel = await deployer.loadArtifact(
    'UnilendV2InterestRateModel'
  );
  const testToken = await deployer.loadArtifact('newERC20Token');
  const helper = await deployer.loadArtifact('helper');

  // ############################# Test Token #############################

  // deploy test token
  // const erc20Contract = await deployer.deploy(testToken, [
  //   // '0xe2a3422f3168149AD2d11b4dE2B97b05f1ebF76e',
  //   '0x4605A6219BC5f9138E4a265C1c3e9fDD4FE1E256',
  //   'WETH Token',
  //   'WETH',
  //   '100000000000000000000000000',
  // ]);
  // const tokenAddress = erc20Contract.address;
  // console.log(`${testToken.contractName} was deployed to ${tokenAddress}`);

  // ############################# Contracts deployment #############################

  // deploy pool contract
  const poolContract = await deployer.deploy(pool);
  const poolAddress = poolContract.address;
  console.log(`${pool.contractName} was deployed to ${poolAddress}`);

  // deploy core contract
  const coreContract = await deployer.deploy(core, [poolAddress]);
  const coreAddress = coreContract.address;
  console.log(`${core.contractName} was deployed to ${coreAddress}`);

  // deploy interestRate contract
  const UnilendInterestRateContract = await deployer.deploy(
    UnilendInterestRateModel
  );
  const UnilendInterestRateAddress = UnilendInterestRateContract.address;
  console.log(
    `${UnilendInterestRateModel.contractName} was deployed to ${UnilendInterestRateAddress}`
  );

  // deploy oracle contract
  let weth = wethAddress;
  const oracleContract = await deployer.deploy(oracle, [weth]);
  const oracleAddress = oracleContract.address;
  console.log(`${oracle.contractName} was deployed to ${oracleAddress}`);

  // deploy position contract
  const positionContract = await deployer.deploy(position, [coreAddress]);
  const positionAddress = positionContract.address;
  console.log(`${position.contractName} was deployed to ${positionAddress}`);

  // deploy helper contract
  // const helperContract = await deployer.deploy(helper);
  // const helperAddress = helperContract.address;
  // console.log(`${helper.contractName} was deployed to ${helperAddress}`);

  // set default interest rate address
  await coreContract.setDefaultInterestRateAddress(UnilendInterestRateAddress);
  console.log('Default Interest Rate Address Set...');

  // set position address
  await coreContract.setPositionAddress(poolAddress);
  console.log('Position Address Set...');

  // set oracle address
  await coreContract.setOracleAddress(oracleAddress);
  console.log('Oracle Address Set...');

  // ########################## createPool call #######################################
  const txs = await coreContract.createPool(
    '0x4127976420204dF0869Ca3ED1C2f62c04F6cb137',
    '0x8C57273241C2b4f4a295ccf3D1Feb29A08225A08', {gasLimit: 800000}
  );
    await txs.wait();
  console.log('pool created', txs);
  const length = await coreContract.poolLength();
  console.log(length, "length");
  // ###############################################################################
  
}


// Deploy this contract. The returned object will be of a `Contract` type, similarly to ones in `ethers`.
// `greeting` is an argument for contract constructor.

//obtain the Constructor Arguments
// console.log("constructor args:" + greeterContract.interface.encodeDeploy([greeting]));

// Estimate contract deployment fee
// const greeting = 'Hi there!';
// const deploymentFee = await deployer.estimateDeployFee(pool);

// const parsedFee = ethers.utils.formatEther(deploymentFee.toString());
// console.log(`The deployment is estimated to cost ${parsedFee} ETH`);
