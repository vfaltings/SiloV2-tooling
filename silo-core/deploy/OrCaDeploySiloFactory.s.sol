// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {ISiloFactory} from "silo-core/contracts/interfaces/ISiloFactory.sol";
import {SiloFactory} from "silo-core/contracts/SiloFactory.sol";
import {
    IInterestRateModelV2Factory,
    InterestRateModelV2Factory
} from "silo-core/contracts/interestRateModel/InterestRateModelV2Factory.sol";
import {IInterestRateModelV2} from "silo-core/contracts/interfaces/IInterestRateModelV2.sol";
import {Silo} from "silo-core/contracts/Silo.sol";
import {ShareProtectedCollateralToken} from "silo-core/contracts/utils/ShareProtectedCollateralToken.sol";
import {ShareDebtToken} from "silo-core/contracts/utils/ShareDebtToken.sol";
import {ISiloDeployer} from "silo-core/contracts/interfaces/ISiloDeployer.sol";
import {SiloDeployer} from "silo-core/contracts/SiloDeployer.sol";
import {ISiloConfig} from "silo-core/contracts/interfaces/ISiloConfig.sol";
import {SiloHookV1} from "silo-core/contracts/hooks/SiloHookV1.sol";
import {InterestRateModelV2} from "silo-core/contracts/interestRateModel/InterestRateModelV2.sol";
import {TestToken} from "./TestToken.sol";

contract OrCaDeploySiloFactory is Script {
  uint256 internal DEPLOYER_PRIVATE_KEY;
  address internal DEPLOYER_ADDR;

  // Deployed contracts on mainnet taken from `silo-core/deployments/mainnet`
  address internal constant WSTETH_MAINNET = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
  address internal constant WETH_MAINNET = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

  address internal constant SILO_DEPLOYER_MAINNET = 0xB2f45335F2A728F1D43BFA2D43Ec426b07f30A00;
  address internal constant SILO_MAINNET = 0xEF1BC66E0eA9717a3f2C969633A989D6BF41024B;
  address internal constant IRM_MAINNET = 0xA418681A28E3513aA9dc092658E583561AC4E720;
  address internal constant HOOKV1_MAINNET = 0xc51f048279705a9427983DCB2813c06af1dA3f5b;

  constructor() {
    DEPLOYER_PRIVATE_KEY = uint256(vm.envBytes32("PRIVATE_KEY"));
    DEPLOYER_ADDR = vm.addr(DEPLOYER_PRIVATE_KEY);
  }

  function run() public {
    bool reuse = vm.envOr("REUSE_DEPLOYMENTS", false);
    if (reuse) {
      console2.log("Reusing deployments on mainnet");
      reuseDeployerRun();
    } else {
      console2.log("Deploying all contracts");
      manualRun();
    }
  }

  function reuseDeployerRun() public {
    ISiloDeployer.Oracles memory oracles = noOracles();
    IInterestRateModelV2.Config memory irmConfigData = defaultIRMConfig();
    ISiloDeployer.ClonableHookReceiver memory hookReceiver = defaultHookReceiver(HOOKV1_MAINNET);
    ISiloConfig.InitData memory siloInitData = defaultInitData(
      WSTETH_MAINNET,
      WETH_MAINNET,
      IRM_MAINNET
    );

    vm.startBroadcast(DEPLOYER_PRIVATE_KEY);
    ISiloConfig siloConfig = ISiloDeployer(SILO_DEPLOYER_MAINNET).deploy(
      oracles,
      irmConfigData,
      irmConfigData,
      hookReceiver,
      siloInitData
    );
    vm.stopBroadcast();
    console2.log("[Deployed] SiloConfig:", address(siloConfig));
  }

  function manualRun() public {
    uint256 deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));
    address deployer = vm.addr(deployerPrivateKey);
    console2.log("Deploying with owner:", deployer);

    // Step 1: deploy SiloFactory
    ISiloFactory siloFactory = deploySiloFactory();

    // Step 2: deploy InterestRateModelV2Factory
    IInterestRateModelV2Factory interestRateModelV2ConfigFactory = deployIRMFactory();

    // Step 3: deploy SiloDeployer
    address siloImpl = SILO_MAINNET;
    (address shareProtectedCollateralTokenImpl, address shareDebtTokenImpl) = deployShareTokenImpls();

    ISiloDeployer siloDeployer = deploySiloDeployer(
      interestRateModelV2ConfigFactory,
      siloFactory,
      siloImpl,
      shareProtectedCollateralTokenImpl,
      shareDebtTokenImpl
    );

    // Step 4: deploy Silo
    ISiloDeployer.Oracles memory oracles = noOracles();

    address irmV2 = deployIRM();
    IInterestRateModelV2.Config memory irmConfigData = defaultIRMConfig();

    address hookV1 = deployHook();
    ISiloDeployer.ClonableHookReceiver memory hookReceiver = defaultHookReceiver(hookV1);

    address token0 = deployTestToken(0);
    address token1 = deployTestToken(1);
    ISiloConfig.InitData memory siloInitData = defaultInitData(
      token0,
      token1,
      irmV2
    );

    vm.startBroadcast(DEPLOYER_PRIVATE_KEY);
    ISiloConfig siloConfig = siloDeployer.deploy(
      oracles,
      irmConfigData,
      irmConfigData,
      hookReceiver,
      siloInitData
    );
    vm.stopBroadcast();

    console2.log("Deployed SiloConfig:", address(siloConfig));
  }

  // -------------------- Deployment helpers --------------------

  function deploySiloFactory() internal returns (ISiloFactory f) {
    vm.startBroadcast(DEPLOYER_PRIVATE_KEY);
    f = ISiloFactory(address(new SiloFactory(DEPLOYER_ADDR)));
    vm.stopBroadcast();
    console2.log("Deployed SiloFactory:", address(f));
  }

  function deployIRMFactory() internal returns (IInterestRateModelV2Factory f) {
    vm.startBroadcast(DEPLOYER_PRIVATE_KEY);
    f = IInterestRateModelV2Factory(address(new InterestRateModelV2Factory()));
    vm.stopBroadcast();
    console2.log("Deployed InterestRateModelV2Factory:", address(f));
  }

  function deploySiloImpl(ISiloFactory f) internal returns (address s) {
    vm.startBroadcast(DEPLOYER_PRIVATE_KEY);
    s = address(new Silo(f));
    vm.stopBroadcast();
    console2.log("Deployed Silo:", s);
  }

  function deployShareTokenImpls() internal returns (address cToken, address dToken) {
    vm.startBroadcast(DEPLOYER_PRIVATE_KEY);
    cToken = address(new ShareProtectedCollateralToken());
    dToken = address(new ShareDebtToken());
    vm.stopBroadcast();
    console2.log("Deployed ShareProtectedCollateralToken:", cToken);
    console2.log("Deployed ShareDebtToken:", dToken);
  }

  function deploySiloDeployer(
    IInterestRateModelV2Factory irmFactory,
    ISiloFactory factory,
    address siloImpl,
    address spcImpl,
    address sdtImpl
  ) internal returns (ISiloDeployer d) {
    vm.startBroadcast(DEPLOYER_PRIVATE_KEY);
    d = ISiloDeployer(address(new SiloDeployer(
      irmFactory,
      factory,
      siloImpl,
      spcImpl,
      sdtImpl
    )));
    vm.stopBroadcast();
    console2.log("Deployed SiloDeployer:", address(d));
  }

  function deployIRM() internal returns (address irm) {
    vm.startBroadcast(DEPLOYER_PRIVATE_KEY);
    irm = address(new InterestRateModelV2());
    vm.stopBroadcast();
    console2.log("Deployed InterestRateModelV2:", irm);
  }

  function deployHook() internal returns (address h) {
    vm.startBroadcast(DEPLOYER_PRIVATE_KEY);
    h = address(new SiloHookV1());
    vm.stopBroadcast();
    console2.log("Deployed SiloHookV1:", h);
  }

  function deployTestToken(uint256 id) internal returns (address token) {
    string memory name = string.concat("SiloTestToken", vm.toString(id));
    string memory symbol = string.concat("STT", vm.toString(id));

    vm.startBroadcast(DEPLOYER_PRIVATE_KEY);
    token = address(new TestToken(name, symbol));
    vm.stopBroadcast();

    console2.log("Deployed TestToken:", address(token));
    console2.log("  Name:", name);
    console2.log("  Symbol:", symbol);
  }

  // -------------------- Struct builders --------------------

  function noOracles() internal returns (ISiloDeployer.Oracles memory o) {
    ISiloDeployer.OracleCreationTxData memory txData;
    o = ISiloDeployer.Oracles({
      solvencyOracle0: txData,
      maxLtvOracle0: txData,
      solvencyOracle1: txData,
      maxLtvOracle1: txData
    });
  }

  function defaultIRMConfig() internal returns (IInterestRateModelV2.Config memory irmConfig) {
    irmConfig = IInterestRateModelV2.Config({
      uopt: 500000000000000000,
      ucrit: 900000000000000000,
      ulow: 300000000000000000,
      ki: 146805,
      kcrit: 317097919838,
      klow: 105699306613,
      klin: 4439370878,
      beta: 69444444444444,
      ri: 0,
      Tcrit: 0
    });
  }

  function defaultHookReceiver(address impl) internal returns (ISiloDeployer.ClonableHookReceiver memory hr) {
    hr = ISiloDeployer.ClonableHookReceiver({
      implementation: impl,
      initializationData: abi.encode(DEPLOYER_ADDR)
    });
  }

  function defaultInitData(
    address token0,
    address token1,
    address irm
  ) internal returns (ISiloConfig.InitData memory initData) {
    initData = ISiloConfig.InitData({
      deployer: address(0),
      hookReceiver: address(0),
      deployerFee: 0,
      daoFee: 0.15e18,
      token0: token0, 
      solvencyOracle0: address(0),
      maxLtvOracle0: address(0),
      interestRateModel0: irm,
      maxLtv0: 9300,
      lt0: 9600,
      liquidationTargetLtv0: 9500,
      liquidationFee0: 150,
      flashloanFee0: 0,
      callBeforeQuote0: false,
      token1: token1, 
      solvencyOracle1: address(0),
      maxLtvOracle1: address(0),
      interestRateModel1: irm,
      maxLtv1: 9300,
      lt1: 9600,
      liquidationTargetLtv1: 9500,
      liquidationFee1: 150,
      flashloanFee1: 0,
      callBeforeQuote1: false
    });
  }
}
