import '@matterlabs/hardhat-zksync-deploy';
import '@matterlabs/hardhat-zksync-solc';
import "@nomiclabs/hardhat-ethers"

module.exports = {
  zksolc: {
    version: '1.3.10',
    compilerSource: 'binary',
    settings: {
      optimizer: {
        enabled: true,
        runs: 1000,
      },
    },
  },
  defaultNetwork: 'zkSyncTestnet',

  networks: {
    zkSyncTestnet: {
      url: 'https://testnet.era.zksync.dev',
      ethNetwork: 'https://eth-goerli.g.alchemy.com/v2/A1Y7FhzKANPFRJo7k9YV9RVhaFS33MCy', // RPC URL of the network (e.g. `https://goerli.infura.io/v3/<API_KEY>`)
      zksync: true,
    },
  },
  solidity: {
    version: '0.8.8',
  },
};
