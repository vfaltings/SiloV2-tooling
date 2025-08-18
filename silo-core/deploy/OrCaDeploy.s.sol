// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {
  IInterestRateModelV2Factory, 
  InterestRateModelV2Factory
} from "silo-core/contracts/interestRateModel/InterestRateModelV2Factory.sol";
import {InterestRateModelV2} from "silo-core/contracts/interestRateModel/InterestRateModelV2.sol";
import {ShareDebtToken} from "silo-core/contracts/utils/ShareDebtToken.sol";
import {ShareProtectedCollateralToken} from "silo-core/contracts/utils/ShareProtectedCollateralToken.sol";
import {SiloConfig} from "silo-core/contracts/SiloConfig.sol";
import {SiloDeployer} from "silo-core/contracts/SiloDeployer.sol";
import {SiloFactory} from "silo-core/contracts/SiloFactory.sol";
import {SiloHookV1} from "silo-core/contracts/hooks/SiloHookV1.sol";
import {Silo} from "silo-core/contracts/Silo.sol";
import {TestToken} from "silo-core/contracts/TestToken.sol";
import {Views} from "silo-core/contracts/lib/Views.sol";

import {IHookReceiver} from "silo-core/contracts/interfaces/IHookReceiver.sol";
import {IInterestRateModelV2} from "silo-core/contracts/interfaces/IInterestRateModelV2.sol";
import {IShareTokenInitializable} from "silo-core/contracts/interfaces/IShareTokenInitializable.sol";
import {IShareToken} from "silo-core/contracts/interfaces/IShareToken.sol";
import {ISiloConfig} from "silo-core/contracts/interfaces/ISiloConfig.sol";
import {ISiloDeployer} from "silo-core/contracts/interfaces/ISiloDeployer.sol";
import {ISiloFactory} from "silo-core/contracts/interfaces/ISiloFactory.sol";
import {ISilo} from "silo-core/contracts/interfaces/ISilo.sol";


contract OrCaDeploy is Script {
  uint256 internal DEPLOYER_PRIVATE_KEY;
  address internal DEPLOYER_ADDR;

  // Deployed contracts on mainnet taken from `silo-core/deployments/mainnet`
  address internal constant WSTETH_MAINNET = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
  address internal constant WETH_MAINNET = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

  address internal constant SILO_DEPLOYER_MAINNET = 0xB2f45335F2A728F1D43BFA2D43Ec426b07f30A00;
  address internal constant SILO_MAINNET = 0xEF1BC66E0eA9717a3f2C969633A989D6BF41024B;
  address internal constant IRM_MAINNET = 0xA418681A28E3513aA9dc092658E583561AC4E720;
  address internal constant HOOKV1_MAINNET = 0xc51f048279705a9427983DCB2813c06af1dA3f5b;

  // Token types
  uint24 internal constant PROTECTED_TOKEN = 2 ** 12;
  uint24 internal constant DEBT_TOKEN = 2 ** 13;

  // Manually deployed contracts
  ISiloFactory internal siloFactory;
  IInterestRateModelV2Factory internal irmFactory;
  address internal hookV1;
  address internal token0;
  address internal token1;
  ISilo internal silo0;
  ISilo internal silo1;
  address internal protectedShareToken0;
  address internal debtShareToken0;
  address internal protectedShareToken1;
  address internal debtShareToken1;
  ISiloConfig internal siloConfig;

  constructor() {
    DEPLOYER_PRIVATE_KEY = uint256(vm.envBytes32("PRIVATE_KEY"));
    DEPLOYER_ADDR = vm.addr(DEPLOYER_PRIVATE_KEY);
  }

  function run() public {
    bool reuse = vm.envOr("REUSE_DEPLOYMENTS", false);
    if (reuse) {
      console2.log("Reusing deployments on mainnet");
      reuseDeploymentsRun();
    } else {
      console2.log("Deploying all contracts");
      manualRun();
    }
  }

  function reuseDeploymentsRun() public {
    ISiloDeployer.Oracles memory oracles = noOracles();
    IInterestRateModelV2.Config memory irmConfigData = defaultIRMConfig();
    ISiloDeployer.ClonableHookReceiver memory hookReceiver = defaultHookReceiver(HOOKV1_MAINNET);
    ISiloConfig.InitData memory siloInitData = defaultInitData(
      WSTETH_MAINNET,
      WETH_MAINNET,
      address(0),
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

    // Deploy SiloFactory
    siloFactory = deploySiloFactory();

    // Deploy IRM factory
    irmFactory = deployIRMFactory();

    // Empty oracles
    ISiloDeployer.Oracles memory oracles = noOracles();

    // Deploy IRM
    IInterestRateModelV2.Config memory irmConfigData = defaultIRMConfig();
    bytes32 irmFactorySalt;
    (, IInterestRateModelV2 interestRateModel) = irmFactory.create(irmConfigData, irmFactorySalt);

    hookV1 = deployHook();
    ISiloDeployer.ClonableHookReceiver memory hookReceiver = defaultHookReceiver(hookV1);

    // Deploy assets
    token0 = deployTestToken(0);
    token1 = deployTestToken(1);

    // Prepare SiloConfig init data
    ISiloConfig.InitData memory siloInitData = defaultInitData(
      token0,
      token1,
      address(hookV1),
      address(interestRateModel)
    );

    ISiloConfig.ConfigData memory configData0;
    ISiloConfig.ConfigData memory configData1;

    (configData0, configData1) = Views.copySiloConfig(
      siloInitData,
      siloFactory.daoFeeRange(),
      siloFactory.maxDeployerFee(),
      siloFactory.maxFlashloanFee(),
      siloFactory.maxLiquidationFee()
    );

    // Deploy Silos + share tokens
    silo0 = deploySilo(siloFactory); 
    silo1 = deploySilo(siloFactory); 
    protectedShareToken0 = deployProtectedShareToken();
    debtShareToken0 = deployDebtShareToken();
    protectedShareToken1 = deployProtectedShareToken();
    debtShareToken1 = deployDebtShareToken();

    configData0.silo = address(silo0);
    configData1.silo = address(silo1);
    configData0.collateralShareToken = configData0.silo;
    configData1.collateralShareToken = configData1.silo;
    configData0.protectedShareToken = protectedShareToken0;
    configData1.protectedShareToken = protectedShareToken1;
    configData0.debtShareToken = debtShareToken0;
    configData1.debtShareToken = debtShareToken1;

    // Deploy SiloConfig
    siloConfig = deploySiloConfig(configData0, configData1);

    // Initialize Silos
    vm.startBroadcast(DEPLOYER_PRIVATE_KEY);
    silo0.initialize(siloConfig);
    silo1.initialize(siloConfig);

    // Initialize silo0 share tokens
    address hookReceiver0 = IShareToken(address(silo0)).hookReceiver();
    (protectedShareToken0, , debtShareToken0) = siloConfig.getShareTokens(address(silo0));

    IShareTokenInitializable(protectedShareToken0).initialize(silo0, hookReceiver0, PROTECTED_TOKEN);
    IShareTokenInitializable(debtShareToken0).initialize(silo0, hookReceiver0, DEBT_TOKEN);

    // Initialize silo1 share tokens
    address hookReceiver1 = IShareToken(address(silo1)).hookReceiver();
    (protectedShareToken1, , debtShareToken1) = siloConfig.getShareTokens(address(silo1));

    IShareTokenInitializable(protectedShareToken1).initialize(silo1, hookReceiver1, PROTECTED_TOKEN);
    IShareTokenInitializable(debtShareToken1).initialize(silo1, hookReceiver1, DEBT_TOKEN);

    // Update hooks
    silo0.updateHooks();
    silo1.updateHooks();

    // Initialize hook receiver 
    IHookReceiver(hookV1).initialize(
      siloConfig,
      hookReceiver.initializationData
    );
    vm.stopBroadcast();
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

  function deploySilo(ISiloFactory f) internal returns (ISilo s) {
    vm.startBroadcast(DEPLOYER_PRIVATE_KEY);
    s = ISilo(address(new Silo(f)));
    vm.stopBroadcast();
    console2.log("Deployed Silo:", address(s));
  }

  function deployProtectedShareToken() internal returns (address cToken) {
    vm.startBroadcast(DEPLOYER_PRIVATE_KEY);
    cToken = address(new ShareProtectedCollateralToken());
    vm.stopBroadcast();
    console2.log("Deployed ShareProtectedCollateralToken:", cToken);
  }

  function deployDebtShareToken() internal returns (address dToken) {
    vm.startBroadcast(DEPLOYER_PRIVATE_KEY);
    dToken = address(new ShareDebtToken());
    vm.stopBroadcast();
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

  function deploySiloConfig(
    ISiloConfig.ConfigData memory configData0,
    ISiloConfig.ConfigData memory configData1
  ) internal returns (ISiloConfig siloConfig) {
    vm.startBroadcast(DEPLOYER_PRIVATE_KEY);
    siloConfig = ISiloConfig(address(new SiloConfig(100, configData0, configData1)));
    vm.stopBroadcast();
    console2.log("Deployed SiloConfig:", address(siloConfig));
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
    address hook,
    address irm
  ) internal returns (ISiloConfig.InitData memory initData) {
    initData = ISiloConfig.InitData({
      deployer: address(0),
      hookReceiver: hook,
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
