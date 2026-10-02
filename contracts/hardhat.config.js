require("@nomicfoundation/hardhat-toolbox");
const { subtask } = require("hardhat/config");
const { TASK_COMPILE_SOLIDITY_GET_SOLC_BUILD } = require("hardhat/builtin-tasks/task-names");
subtask(TASK_COMPILE_SOLIDITY_GET_SOLC_BUILD, async (args, hre, runSuper) => {
  if (args.solcVersion === "0.8.24") {
    const p = require.resolve("solc/soljson.js");
    return { compilerPath: p, isSolcJs: true, version: args.solcVersion, longVersion: require("solc/package.json").version };
  }
  return runSuper();
});
module.exports = {
  solidity: { version: "0.8.24", settings: { optimizer: { enabled: true, runs: 200 }, evmVersion: "berlin", metadata: { bytecodeHash: "none" } } },
  networks: { hardhat: { hardfork: "berlin", chainId: 1404, accounts: { accountsBalance: "1000000000000000000000000" } }, localhost: { url: "http://127.0.0.1:8545", chainId: 1404 } },
};
