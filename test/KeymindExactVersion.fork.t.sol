// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Position} from "v4-core/src/libraries/Position.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";

interface IGraphFactory {
    struct GraphAuthorization {
        bytes32 routeNamespace;
        bytes32 routeNonce;
        bytes32 topologyHash;
        bytes32 graphCommitment;
        address authorizedLauncher;
        uint256 totalValue;
    }

    struct Target {
        bytes32 targetIdHash;
        bytes32 applicantSalt;
        uint256 deploymentValue;
        uint256 initializerValue;
        bytes initCode;
        bytes initializerCalldata;
    }

    function deployGraph(GraphAuthorization calldata authorization, Target[] calldata targets)
        external
        payable
        returns (address[] memory, bytes32[] memory, bytes[] memory, bytes32);
    function computeGraphCommitment(GraphAuthorization calldata authorization, Target[] calldata targets)
        external
        view
        returns (bytes32, uint256);
}

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

interface IToken {
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function startedAt() external view returns (uint256);
    function start() external;
    function walletTokenLimit() external view returns (uint256);
    function launchSupply() external view returns (uint256);
    function receivedDuringProtection(address) external view returns (uint256);
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
}

interface IHook {
    function poolKey() external view returns (PoolKey memory);
    function feeVault() external view returns (address);
    function openingTaxVault() external view returns (address);
    function module() external view returns (address);
    function boughtDuringProtection(address) external view returns (uint256);
    function creatorBuyFeeBps() external view returns (uint16);
    function creatorSellFeeBps() external view returns (uint16);
    function PLATFORM_FEE_BPS() external view returns (uint16);
    function previewTradeFees(uint256 amount, bool amountIsNet, bool isBuy, address buyer)
        external
        view
        returns (uint256, uint256, uint256, uint256);
}

interface IInitializer {
    function initialize(address hook, address token, int24 startTick, address buyer, uint256 minTokenOut) external payable;
    function lockedLiquidity() external view returns (uint128);
    function openingFdvUsd() external view returns (uint256);
    function MAX_FEED_AGE() external view returns (uint256);
    function unlockCallback(bytes calldata) external returns (bytes memory);
}

interface IFeeVault {
    function platformAccrued() external view returns (uint256);
    function creatorAccrued() external view returns (uint256);
    function creatorRecipient() external view returns (address);
    function claimPlatform() external returns (uint256);
    function claimCreator() external returns (uint256);
    function recordFees(uint256, uint256) external;
    function unlockCallback(bytes calldata) external returns (bytes memory);
}

interface IModule {
    function additionalTaxPpmForBuyer(address) external view returns (uint24);
    function openingTaxPpmForSender(address) external view returns (uint24);
    function protectedBuyer(address) external view returns (address);
    function developer() external view returns (address);
}

interface IKeymindVault {
    function distribute() external;
    function guardian() external view returns (address);
    function treasury() external view returns (address);
    function grantsPool() external view returns (uint256);
    function proposeGrant(bytes32 grantId, address recipient, uint128 amount, bytes32 descriptionHash) external;
    function cancelGrant(bytes32 grantId) external;
    function executeGrant(bytes32 grantId) external;
}

/// @dev A minimal direct PoolManager integration: no router, arbitrary hookData. Used to show fees cannot be bypassed.
contract DirectSwapper is IUnlockCallback {
    IPoolManager internal immutable pm;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    function buy(PoolKey memory key, uint256 amountIn, bytes memory hookData) external payable returns (uint256) {
        return abi.decode(pm.unlock(abi.encode(msg.sender, key, amountIn, hookData)), (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "pm only");
        (address to, PoolKey memory key, uint256 amountIn, bytes memory hookData) =
            abi.decode(data, (address, PoolKey, uint256, bytes));
        BalanceDelta d = pm.swap(key, SwapParams(true, -int256(amountIn), TickMath.MIN_SQRT_PRICE + 1), hookData);
        pm.settle{value: uint256(uint128(-d.amount0()))}();
        uint256 out = uint256(uint128(d.amount1()));
        pm.take(key.currency1, to, out);
        return abi.encode(out);
    }
}

/// @notice Exact-version execution evidence for the packed KEYMIND request.
/// @dev Deploys the exact Router graph targets of protected/launch.json (exported by programmable/export-exact-fixture.mjs)
///      through Programmable's real GraphFactory on a mainnet fork, called as the 24h Router with the launch wallet as
///      tx.origin. Only the permit signature check of the Router is not exercised. Every scenario writes its
///      address-independent observations to evidence/exact/<scenario>.json.
///      Run: ETH_RPC_URL=<rpc> [FORK_BLOCK=<n>] forge test --match-contract KeymindExactVersionForkTest
contract KeymindExactVersionForkTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    // Chain infrastructure comes from the fixture (Ethereum defaults keep older fixtures working).
    IPoolManager PM = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IGraphFactory FACTORY = IGraphFactory(0xB012e4A8F2c5FC4E8E4faCA9D5Ad6FfF13FBA887);
    IUniversalRouter UR = IUniversalRouter(0xd92A36B0000531EF3063dEd4De20A0783308446C);
    address FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address constant TREASURY = 0xD88539d3c4C460136a733A3Fd60cf6BF269079da;
    string evidenceDir = "evidence/exact/";
    bytes32 constant TOPOLOGY = keccak256("keymind.exact-version-evidence.topology");
    uint256 constant NORMAL_PPM = 28_000; // 0.30% platform + 2.5% creator, both sides
    uint256 constant OPENING_TOTAL_PPM = 990_000;

    string fixture;
    bool forked;
    address router;
    address launchWallet;
    address developer;
    int24 startTick;
    uint256 initialBuyWei;
    uint256 minimumTokensOut;

    IInitializer initializer;
    IToken kmd;
    IHook hook;
    IFeeVault fees;
    IFeeVault taxVault;
    IModule module;
    address vault;
    PoolKey key;
    uint256 launchTime;
    uint256 devTokens;

    address alice = makeAddr("evidence-alice");
    address bob = makeAddr("evidence-bob");
    address carol = makeAddr("evidence-carol");
    address dave = makeAddr("evidence-dave");
    address lp = makeAddr("evidence-third-party-lp");
    address stranger = makeAddr("evidence-unauthorized-claimer");

    string obj;

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        uint256 forkBlock = vm.envOr("FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);
        forked = true;
        fixture = vm.readFile(vm.envOr("EXACT_FIXTURE", string("test/fixtures/exact-launch.json")));
        evidenceDir = vm.envOr("EXACT_EVIDENCE_DIR", string("evidence/exact/"));
        if (vm.keyExistsJson(fixture, ".poolManager")) {
            PM = IPoolManager(vm.parseJsonAddress(fixture, ".poolManager"));
            FACTORY = IGraphFactory(vm.parseJsonAddress(fixture, ".graphFactory"));
            UR = IUniversalRouter(vm.parseJsonAddress(fixture, ".universalRouter"));
            FEED = vm.parseJsonAddress(fixture, ".feed");
            assertEq(block.chainid, vm.parseJsonUint(fixture, ".chainId"), "fork chain matches the fixture");
        }
        router = vm.parseJsonAddress(fixture, ".router");
        launchWallet = vm.parseJsonAddress(fixture, ".launchWallet");
        developer = vm.parseJsonAddress(fixture, ".developer");
        startTick = int24(vm.parseJsonInt(fixture, ".startTick"));
        initialBuyWei = vm.parseJsonUint(fixture, ".initialBuyWei");
        minimumTokensOut = vm.parseJsonUint(fixture, ".minimumTokensOut");
        for (uint256 i; i < 6; ++i) {
            address a = [alice, bob, carol, dave, lp, stranger][i];
            vm.deal(a, 100 ether);
        }
    }

    // ------------------------------------------------------------------ launch through the real GraphFactory

    function _targets(uint256 initValue) internal view returns (IGraphFactory.Target[] memory t, uint256 total) {
        t = abi.decode(vm.parseJsonBytes(fixture, ".targetsAbi"), (IGraphFactory.Target[]));
        for (uint256 i; i < t.length; ++i) {
            if (t[i].initializerValue != 0) t[i].initializerValue = initValue;
            total += t[i].deploymentValue + t[i].initializerValue;
        }
    }

    function _deployGraph(uint256 initValue) internal returns (bool ok, bytes memory ret) {
        (IGraphFactory.Target[] memory t, uint256 total) = _targets(initValue);
        IGraphFactory.GraphAuthorization memory auth = IGraphFactory.GraphAuthorization({
            routeNamespace: vm.parseJsonBytes32(fixture, ".routeNamespace"),
            routeNonce: vm.parseJsonBytes32(fixture, ".routeNonce"),
            topologyHash: TOPOLOGY,
            graphCommitment: bytes32(0),
            authorizedLauncher: router,
            totalValue: total
        });
        (auth.graphCommitment,) = FACTORY.computeGraphCommitment(auth, t);
        vm.deal(router, router.balance + total);
        vm.prank(router, launchWallet);
        (ok, ret) = address(FACTORY).call{value: total}(abi.encodeCall(IGraphFactory.deployGraph, (auth, t)));
    }

    function _launch() internal {
        (bool ok, bytes memory ret) = _deployGraph(initialBuyWei);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        launchTime = block.timestamp;
        initializer = IInitializer(vm.parseJsonAddress(fixture, ".initializer"));
        kmd = IToken(vm.parseJsonAddress(fixture, ".token"));
        hook = IHook(vm.parseJsonAddress(fixture, ".hook"));
        vault = vm.parseJsonAddress(fixture, ".vault");
        // Exact version: every target sits at its predicted CREATE2 address with the packed runtime.
        assertEq(address(initializer).codehash, vm.parseJsonBytes32(fixture, ".initializerRuntimeCodeHash"), "initializer runtime");
        assertEq(address(kmd).codehash, vm.parseJsonBytes32(fixture, ".tokenRuntimeCodeHash"), "token runtime");
        assertEq(address(hook).codehash, vm.parseJsonBytes32(fixture, ".hookRuntimeCodeHash"), "hook runtime");
        assertEq(vault.codehash, vm.parseJsonBytes32(fixture, ".vaultRuntimeCodeHash"), "vault runtime");
        fees = IFeeVault(hook.feeVault());
        taxVault = IFeeVault(hook.openingTaxVault());
        module = IModule(hook.module());
        key = hook.poolKey();
        devTokens = kmd.balanceOf(developer);
    }

    // ------------------------------------------------------------------ trading helpers

    function _urBuy(address who, uint256 amountIn) internal returns (bool ok, bytes memory ret, uint256 out) {
        bytes memory actions = abi.encodePacked(uint8(0x06), uint8(0x0c), uint8(0x0f)); // exact-in single, settle all, take all
        bytes[] memory params = new bytes[](3);
        // Base's Universal Router release adds minHopPriceX36 to ExactInputSingleParams.
        params[0] = block.chainid == 8453
            ? abi.encode(key, true, uint128(amountIn), uint128(0), uint256(0), bytes(""))
            : abi.encode(key, true, uint128(amountIn), uint128(0), bytes(""));
        params[1] = abi.encode(Currency.wrap(address(0)), amountIn);
        params[2] = abi.encode(key.currency1, uint256(0));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
        uint256 before = kmd.balanceOf(who);
        vm.prank(who);
        (ok, ret) = address(UR).call{value: amountIn}(abi.encodeCall(IUniversalRouter.execute, (hex"10", inputs, block.timestamp)));
        out = kmd.balanceOf(who) - before;
    }

    function _testSwap(address who, bool zeroForOne, int256 amountSpecified, uint256 value)
        internal
        returns (bool ok, bytes memory ret)
    {
        PoolSwapTest swapper = new PoolSwapTest(PM);
        vm.deal(address(swapper), 0); // mainnet dust at Foundry-derived addresses would otherwise be refunded
        if (!zeroForOne) {
            vm.prank(who);
            kmd.approve(address(swapper), type(uint256).max);
        }
        vm.prank(who);
        (ok, ret) = address(swapper).call{value: value}(
            abi.encodeCall(
                PoolSwapTest.swap,
                (
                    key,
                    SwapParams(zeroForOne, amountSpecified, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
                    PoolSwapTest.TestSettings(false, false),
                    bytes("")
                )
            )
        );
    }

    struct Trade {
        uint256 nativeIn;
        uint256 nativeOut;
        uint256 tokensIn;
        uint256 tokensOut;
        uint256 platform;
        uint256 creator;
        uint256 openingTax;
    }

    function _measured(address who, bool zeroForOne, int256 amountSpecified, uint256 value) internal returns (Trade memory t) {
        uint256 eth0 = who.balance;
        uint256 tok0 = kmd.balanceOf(who);
        uint256 p0 = fees.platformAccrued();
        uint256 c0 = fees.creatorAccrued();
        uint256 x0 = taxVault.platformAccrued();
        (bool ok, bytes memory ret) = _testSwap(who, zeroForOne, amountSpecified, value);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        if (who.balance < eth0) t.nativeIn = eth0 - who.balance;
        else t.nativeOut = who.balance - eth0;
        if (kmd.balanceOf(who) < tok0) t.tokensIn = tok0 - kmd.balanceOf(who);
        else t.tokensOut = kmd.balanceOf(who) - tok0;
        t.platform = fees.platformAccrued() - p0;
        t.creator = fees.creatorAccrued() - c0;
        t.openingTax = taxVault.platformAccrued() - x0;
    }

    /// @dev Independent reimplementation of the published fee formula (gross native, ceil per trade).
    function _expect(uint256 amount, bool amountIsNet, uint256 taxPpm)
        internal
        pure
        returns (uint256 gross, uint256 platform, uint256 creator, uint256 tax)
    {
        uint256 totalPpm = NORMAL_PPM + taxPpm;
        gross = amountIsNet ? FullMath.mulDivRoundingUp(amount, 1e6, 1e6 - totalPpm) : amount;
        uint256 totalFee = amountIsNet ? gross - amount : FullMath.mulDivRoundingUp(gross, totalPpm, 1e6);
        uint256 normal = FullMath.mulDivRoundingUp(gross, NORMAL_PPM, 1e6);
        platform = FullMath.mulDivRoundingUp(gross, 30, 10_000);
        creator = normal - platform;
        tax = totalFee - normal;
    }

    /// @dev Checks one trade against the formula; returns the gross native amount.
    function _checkTrade(Trade memory t, bool isBuy, bool nativeExact, uint256 taxPpm) internal pure returns (uint256 gross) {
        uint256 hookFees = t.platform + t.creator + t.openingTax;
        if (isBuy) {
            gross = t.nativeIn; // the buyer's whole native payment is the gross trade value
            (uint256 g, uint256 p, uint256 c, uint256 x) =
                nativeExact ? _expect(t.nativeIn, false, taxPpm) : _expect(t.nativeIn - hookFees, true, taxPpm);
            require(g == gross && p == t.platform && c == t.creator && x == t.openingTax, "buy fees differ from formula");
        } else {
            gross = t.nativeOut + hookFees; // the pool paid gross; the seller received gross minus fees
            (uint256 g, uint256 p, uint256 c, uint256 x) =
                nativeExact ? _expect(t.nativeOut, true, 0) : _expect(gross, false, 0);
            require(g == gross && p == t.platform && c == t.creator && x == 0, "sell fees differ from formula");
        }
    }

    function _contains(bytes memory data, bytes4 selector) internal pure returns (bool) {
        if (data.length < 4) return false;
        for (uint256 i; i + 4 <= data.length; ++i) {
            if (data[i] == selector[0] && data[i + 1] == selector[1] && data[i + 2] == selector[2] && data[i + 3] == selector[3]) {
                return true;
            }
        }
        return false;
    }

    function _taxPpmAt(uint256 elapsed) internal pure returns (uint256) {
        if (elapsed >= 30) return 0;
        return FullMath.mulDiv(OPENING_TOTAL_PPM - NORMAL_PPM, 30 - elapsed, 30);
    }

    // ------------------------------------------------------------------ evidence output

    function _begin(string memory scenario) internal {
        obj = scenario;
        vm.serializeString(obj, "scenario", scenario);
    }

    function _rec(string memory k, uint256 v) internal {
        vm.serializeString(obj, k, vm.toString(v));
    }

    function _recInt(string memory k, int256 v) internal {
        vm.serializeString(obj, k, vm.toString(v));
    }

    function _recBool(string memory k, bool v) internal {
        vm.serializeBool(obj, k, v);
    }

    function _recTrade(string memory k, Trade memory t, uint256 gross) internal {
        string memory o = string.concat(obj, ".", k);
        vm.serializeString(o, "grossNative", vm.toString(gross));
        vm.serializeString(o, "nativeIn", vm.toString(t.nativeIn));
        vm.serializeString(o, "nativeOut", vm.toString(t.nativeOut));
        vm.serializeString(o, "tokensIn", vm.toString(t.tokensIn));
        vm.serializeString(o, "tokensOut", vm.toString(t.tokensOut));
        vm.serializeString(o, "platformFee", vm.toString(t.platform));
        vm.serializeString(o, "creatorFee", vm.toString(t.creator));
        string memory out = vm.serializeString(o, "openingTax", vm.toString(t.openingTax));
        vm.serializeString(obj, k, out);
    }

    function _end() internal {
        string memory out = vm.serializeBool(obj, "passed", true);
        vm.writeJson(out, string.concat(evidenceDir, obj, ".json"));
    }

    // ================================================================== initial buy (bound call)

    function test_exact_00_initialBuyBoundCall() public {
        if (!forked) return;
        uint256 bal0 = developer.balance;
        _launch();
        _begin("initial-buy-bound-call");
        (, int256 answer,, uint256 updatedAt,) = IFeed(FEED).latestRoundData();
        _recBool("deployedThroughRealGraphFactoryAsRouter", true);
        _recBool("allTargetsAtPredictedAddressesWithPackedRuntime", true);
        _rec("initialBuyInputWei", initialBuyWei);
        _rec("initialBuyTokensOut", devTokens);
        _rec("minimumTokensOut", minimumTokensOut);
        _rec("walletTokenLimit", kmd.walletTokenLimit());
        _recInt("startTick", startTick);
        _rec("openingFdvUsd", initializer.openingFdvUsd());
        _recInt("feedAnswer", answer);
        _rec("feedAgeSecondsAtLaunch", block.timestamp - updatedAt);
        _rec("maxFeedAgeSeconds", initializer.MAX_FEED_AGE());
        // Developer pays the normal fee only (exempt from the opening surcharge) and receives the tokens directly.
        assertGe(devTokens, minimumTokensOut, "minimum output");
        assertLe(devTokens, kmd.walletTokenLimit(), "2% cap");
        assertEq(hook.boughtDuringProtection(developer), devTokens, "counted against the buyer budget");
        assertEq(kmd.receivedDuringProtection(developer), devTokens, "counted against the recipient budget");
        (uint256 g, uint256 p, uint256 c, uint256 x) = _expect(initialBuyWei, false, 0);
        assertEq(fees.platformAccrued(), p, "platform fee on the initial buy");
        assertEq(fees.creatorAccrued(), c, "creator fee on the initial buy");
        assertEq(taxVault.platformAccrued(), x, "no opening tax for the developer");
        assertEq(developer.balance, bal0, "the router, not the developer EOA, funds msg.value in this harness");
        _rec("grossNative", g);
        _rec("platformFee", p);
        _rec("creatorFee", c);
        _rec("openingTax", x);
        assertEq(kmd.startedAt(), launchTime, "trading starts in the launch transaction");
        _end();
    }

    // ================================================================== twelve protection scenarios

    function test_exact_P01_openingFdvFloor() public {
        if (!forked) return;
        _begin("P01-opening-fdv-floor");
        (uint80 r, int256 answer, uint256 s, uint256 u, uint80 ar) = IFeed(FEED).latestRoundData();
        // Smallest feed answer that still clears USD 15,000 at this tick (same rounding as the initializer).
        uint256 supply = 1_000_000_000e18;
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(startTick);
        uint256 nativeValue = FullMath.mulDiv(uint256(1) << 192, supply, uint256(sqrtP) * sqrtP);
        uint256 minAnswer = FullMath.mulDivRoundingUp(15_000, 1 ether * 1e8, nativeValue);
        _rec("minimumEthUsdAnswerForLaunch", minAnswer);
        _rec("observedEthUsdAnswer", uint256(answer));
        _rec("priceDropToleranceBps", (uint256(answer) - minAnswer) * 10_000 / uint256(answer));
        uint256 snap = vm.snapshotState();
        vm.mockCall(FEED, abi.encodeWithSelector(IFeed.latestRoundData.selector), abi.encode(r, int256(minAnswer - 1), s, u, ar));
        (bool ok, bytes memory ret) = _deployGraph(initialBuyWei);
        assertFalse(ok, "launch below the floor reverts");
        assertTrue(_contains(ret, bytes4(keccak256("OpeningValuationTooLow(uint256)"))), "OpeningValuationTooLow");
        assertEq(vm.parseJsonAddress(fixture, ".token").code.length, 0, "atomic: nothing deployed");
        _recBool("belowFloorReverts", true);
        vm.revertToState(snap);
        vm.mockCall(FEED, abi.encodeWithSelector(IFeed.latestRoundData.selector), abi.encode(r, int256(minAnswer), s, u, ar));
        (ok,) = _deployGraph(initialBuyWei);
        assertTrue(ok, "launch exactly at the floor succeeds");
        _recBool("atFloorSucceeds", true);
        _end();
    }

    function test_exact_P02_staleOracleRejected() public {
        if (!forked) return;
        _begin("P02-stale-oracle-rejected");
        (uint80 r, int256 answer, uint256 s,, uint80 ar) = IFeed(FEED).latestRoundData();
        uint256 snap = vm.snapshotState();
        vm.mockCall(FEED, abi.encodeWithSelector(IFeed.latestRoundData.selector), abi.encode(r, answer, s, block.timestamp - 3601, ar));
        (bool ok, bytes memory ret) = _deployGraph(initialBuyWei);
        assertFalse(ok);
        assertTrue(_contains(ret, bytes4(keccak256("InvalidOraclePrice()"))), "InvalidOraclePrice");
        _recBool("feedOlderThanOneHourReverts", true);
        vm.revertToState(snap);
        vm.mockCall(FEED, abi.encodeWithSelector(IFeed.latestRoundData.selector), abi.encode(r, answer, s, block.timestamp - 3600, ar));
        (ok,) = _deployGraph(initialBuyWei);
        assertTrue(ok, "a feed exactly one hour old is accepted");
        _recBool("feedExactlyOneHourOldAccepted", true);
        _end();
    }

    function test_exact_P03_initialBuyAboveTwoPercentReverts() public {
        if (!forked) return;
        _begin("P03-initial-buy-above-2pct-reverts");
        (bool ok, bytes memory ret) = _deployGraph(0.5 ether);
        assertFalse(ok, "a 0.5 ETH opening buy would exceed 2% of supply");
        assertTrue(
            _contains(ret, bytes4(keccak256("BuyerLimitExceeded(address,uint256,uint256)")))
                || _contains(ret, bytes4(keccak256("WalletLimitExceeded(address,uint256,uint256)"))),
            "2% limit"
        );
        assertEq(vm.parseJsonAddress(fixture, ".hook").code.length, 0, "atomic: nothing deployed");
        _recBool("oversizedInitialBuyRevertsWholeGraph", true);
        _rec("attemptedInitialBuyWei", 0.5 ether);
        _end();
    }

    function test_exact_P04_initialBuyMinimumOutputEnforced() public {
        if (!forked) return;
        _begin("P04-initial-buy-minimum-output");
        (bool ok, bytes memory ret) = _deployGraph(0.045 ether);
        assertFalse(ok, "a smaller buy cannot meet the bound minimum output");
        assertTrue(_contains(ret, bytes4(keccak256("InvalidInitialBuy()"))), "InvalidInitialBuy");
        _recBool("underfundedInitialBuyReverts", true);
        _rec("attemptedInitialBuyWei", 0.045 ether);
        _end();
    }

    function test_exact_P05_singleAtomicInitialization() public {
        if (!forked) return;
        _launch();
        _begin("P05-single-atomic-initialization");
        vm.prank(launchWallet);
        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        initializer.initialize(address(hook), address(kmd), startTick, developer, 1);
        vm.deal(address(FACTORY), 1 ether);
        vm.prank(address(FACTORY));
        vm.expectRevert(bytes4(keccak256("AlreadyInitialized()")));
        initializer.initialize{value: 1}(address(hook), address(kmd), startTick, developer, 1);
        vm.expectRevert(bytes4(keccak256("NotInitializer()")));
        kmd.start();
        vm.expectRevert();
        PM.initialize(key, TickMath.getSqrtPriceAtTick(startTick));
        PoolKey memory other = PoolKey(Currency.wrap(address(0)), key.currency1, 0, 10, IHooks(address(hook)));
        vm.expectRevert();
        PM.initialize(other, TickMath.getSqrtPriceAtTick(0));
        (bool ok, bytes memory ret) = _deployGraph(initialBuyWei);
        assertFalse(ok, "the graph authorization cannot be replayed");
        _recBool("replayRejected", ret.length > 0);
        _recBool("initializeOnlyByGraphFactoryOnce", true);
        _recBool("tokenStartOnlyByInitializer", true);
        _recBool("poolCannotBeReinitializedOrCloned", true);
        _end();
    }

    function test_exact_P06_openingTaxAtLaunchSecond() public {
        if (!forked) return;
        _launch();
        _begin("P06-opening-tax-at-launch-second");
        uint256 taxPpm = _taxPpmAt(0);
        assertEq(module.additionalTaxPpmForBuyer(alice), taxPpm);
        assertEq(taxPpm + NORMAL_PPM, OPENING_TOTAL_PPM, "99% total at the first second");
        Trade memory t = _measuredUr(alice, 0.01 ether);
        uint256 g = _checkTrade(t, true, true, taxPpm);
        _recTrade("buyAtLaunchSecond", t, g);
        _rec("totalBuyFeePpm", taxPpm + NORMAL_PPM);
        assertEq(taxVault.creatorAccrued(), 0, "opening tax is platform-only");
        assertEq(taxVault.creatorRecipient(), TREASURY, "opening tax vault pays only the treasury");
        _end();
    }

    function _measuredUr(address who, uint256 amountIn) internal returns (Trade memory t) {
        uint256 eth0 = who.balance;
        uint256 p0 = fees.platformAccrued();
        uint256 c0 = fees.creatorAccrued();
        uint256 x0 = taxVault.platformAccrued();
        (bool ok, bytes memory ret, uint256 out) = _urBuy(who, amountIn);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        t.nativeIn = eth0 - who.balance;
        t.tokensOut = out;
        t.platform = fees.platformAccrued() - p0;
        t.creator = fees.creatorAccrued() - c0;
        t.openingTax = taxVault.platformAccrued() - x0;
    }

    function test_exact_P07_openingTaxDecaysToNormal() public {
        if (!forked) return;
        _launch();
        _begin("P07-opening-tax-decay");
        uint256[5] memory at = [uint256(1), 10, 20, 29, 30];
        address[5] memory who = [alice, bob, carol, dave, stranger];
        for (uint256 i; i < 5; ++i) {
            vm.warp(launchTime + at[i]);
            uint256 taxPpm = _taxPpmAt(at[i]);
            assertEq(module.additionalTaxPpmForBuyer(who[i]), taxPpm, "linear decay");
            Trade memory t = _measuredUr(who[i], 0.01 ether);
            uint256 g = _checkTrade(t, true, true, taxPpm);
            _recTrade(string.concat("buyAtSecond", vm.toString(at[i])), t, g);
        }
        assertEq(module.additionalTaxPpmForBuyer(alice), 0, "normal fees from second 30");
        _end();
    }

    function test_exact_P08_developerTaxExemptButCapped() public {
        if (!forked) return;
        _launch();
        _begin("P08-developer-tax-exempt-but-capped");
        vm.deal(developer, 10 ether);
        vm.warp(launchTime + 1);
        assertEq(module.additionalTaxPpmForBuyer(developer), 0, "developer pays no opening surcharge");
        Trade memory t = _measuredUr(developer, 0.01 ether);
        uint256 g = _checkTrade(t, true, true, 0);
        _recTrade("developerBuyAtSecond1", t, g);
        (bool ok, bytes memory ret,) = _urBuy(developer, 1 ether);
        assertFalse(ok, "developer is still capped at 2%");
        assertTrue(_contains(ret, bytes4(keccak256("BuyerLimitExceeded(address,uint256,uint256)"))), "BuyerLimitExceeded");
        _recBool("developerOverCapBuyReverts", true);
        _rec("developerBoughtDuringProtection", hook.boughtDuringProtection(developer));
        _end();
    }

    function test_exact_P09_buyerCapIsCumulativeAndSellsDoNotRestore() public {
        if (!forked) return;
        _launch();
        _begin("P09-buyer-cap-cumulative");
        vm.warp(launchTime + 31);
        Trade memory first = _measuredUr(alice, 0.1 ether);
        _checkTrade(first, true, true, 0);
        uint256 limit = kmd.walletTokenLimit();
        assertEq(hook.boughtDuringProtection(alice), first.tokensOut);
        // Selling half does not restore the purchase budget.
        Trade memory sell = _measured(alice, false, -int256(first.tokensOut / 2), 0);
        _checkTrade(sell, false, false, 0);
        assertEq(hook.boughtDuringProtection(alice), first.tokensOut, "sell does not refill");
        (bool ok, bytes memory ret,) = _urBuy(alice, 0.1 ether);
        assertFalse(ok, "second 0.1 ETH buy would pass 2% cumulative");
        assertTrue(_contains(ret, bytes4(keccak256("BuyerLimitExceeded(address,uint256,uint256)"))), "BuyerLimitExceeded");
        Trade memory small = _measuredUr(alice, 0.01 ether);
        _checkTrade(small, true, true, 0);
        assertLe(hook.boughtDuringProtection(alice), limit);
        _rec("firstBuyTokens", first.tokensOut);
        _rec("budgetRemainingAfterSell", limit - first.tokensOut);
        _recBool("overBudgetBuyReverts", true);
        _recBool("sellsDoNotRefill", true);
        _end();
    }

    function test_exact_P10_recipientCapOnTransfers() public {
        if (!forked) return;
        _launch();
        _begin("P10-recipient-cap-on-transfers");
        vm.warp(launchTime + 31);
        (,, uint256 aliceOut) = _urBuy(alice, 0.1 ether);
        (,, uint256 bobOut) = _urBuy(bob, 0.1 ether);
        uint256 limit = kmd.walletTokenLimit();
        assertGt(aliceOut + bobOut, limit, "together above 2%");
        vm.prank(alice);
        kmd.transfer(carol, aliceOut);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("WalletLimitExceeded(address,uint256,uint256)")), carol, aliceOut + bobOut, limit));
        kmd.transfer(carol, bobOut);
        // Forwarding tokens out does not refill the receiving budget.
        vm.prank(carol);
        kmd.transfer(dave, aliceOut / 2);
        vm.prank(bob);
        vm.expectRevert();
        kmd.transfer(carol, limit - aliceOut + 1);
        // Self-transfers neither mint headroom nor consume it; transfers into the pool (sells) are unrestricted.
        uint256 before = kmd.receivedDuringProtection(bob);
        vm.prank(bob);
        kmd.transfer(bob, bobOut);
        assertEq(kmd.receivedDuringProtection(bob), before);
        _rec("aliceBought", aliceOut);
        _rec("bobBought", bobOut);
        _recBool("overCapTransferReverts", true);
        _recBool("forwardingDoesNotRefill", true);
        _recBool("selfTransferNeutral", true);
        _end();
    }

    function test_exact_P11_canonicalRouterOnlyBuysSellsAnyRoute() public {
        if (!forked) return;
        _launch();
        _begin("P11-canonical-router-only-buys");
        DirectSwapper direct = new DirectSwapper(PM);
        vm.deal(address(direct), 0);
        vm.warp(launchTime + 10);
        (bool ok, bytes memory ret) = _testSwap(alice, true, -0.01 ether, 0.01 ether);
        assertFalse(ok);
        assertTrue(_contains(ret, bytes4(keccak256("UnsupportedRouter()"))), "test router rejected in the tax window");
        vm.warp(launchTime + 100);
        (ok, ret) = _testSwap(alice, true, -0.01 ether, 0.01 ether);
        assertFalse(ok);
        assertTrue(_contains(ret, bytes4(keccak256("UnsupportedRouter()"))), "test router rejected in the cap window");
        vm.prank(alice);
        (ok, ret) = address(direct).call{value: 0.01 ether}(abi.encodeCall(DirectSwapper.buy, (key, 0.01 ether, bytes(""))));
        assertFalse(ok);
        assertTrue(_contains(ret, bytes4(keccak256("UnsupportedRouter()"))), "direct PoolManager buyer rejected");
        Trade memory b = _measuredUr(alice, 0.05 ether);
        _checkTrade(b, true, true, 0);
        Trade memory s = _measured(alice, false, -int256(b.tokensOut / 3), 0);
        uint256 g = _checkTrade(s, false, false, 0);
        _recTrade("sellThroughNonCanonicalRouterInWindow", s, g);
        _recBool("nonCanonicalBuysRejectedFor300s", true);
        _recBool("sellsAllowedWithNormalFees", true);
        _end();
    }

    function test_exact_P12_protectionExpiresAt300s() public {
        if (!forked) return;
        _launch();
        _begin("P12-protection-expires-at-300s");
        vm.warp(launchTime + 299);
        (bool ok,) = _testSwap(alice, true, -1 ether, 1 ether);
        assertFalse(ok, "still protected at second 299");
        vm.warp(launchTime + 300);
        Trade memory t = _measured(alice, true, -3 ether, 3 ether);
        uint256 g = _checkTrade(t, true, true, 0);
        assertGt(t.tokensOut, kmd.walletTokenLimit(), "above 2% in one buy after the window");
        assertEq(hook.boughtDuringProtection(alice), 0, "no budget tracking after the window");
        vm.prank(alice);
        kmd.transfer(carol, t.tokensOut);
        _recTrade("largeBuyAtSecond300", t, g);
        _recBool("capsLiftedAtSecond300", true);
        _end();
    }

    // ================================================================== four swap quadrants, multi-size

    function test_exact_S01_fourQuadrantsMultiSize() public {
        if (!forked) return;
        _launch();
        _begin("S01-four-quadrants-multi-size");
        vm.warp(launchTime + 301);
        uint256[3] memory buyIn = [uint256(0.001 ether), 0.25 ether, 3 ether];
        uint256[3] memory buyOut = [uint256(1_000e18), 5_000_000e18, 40_000_000e18];
        uint256[3] memory sellIn = [uint256(1_000e18), 1_000_000e18, 10_000_000e18];
        uint256[3] memory sellOut = [uint256(0.0001 ether), 0.01 ether, 0.5 ether];
        for (uint256 i; i < 3; ++i) {
            Trade memory t = _measured(alice, true, -int256(buyIn[i]), buyIn[i]);
            _recTrade(string.concat("buyExactIn_", vm.toString(i)), t, _checkTrade(t, true, true, 0));
        }
        for (uint256 i; i < 3; ++i) {
            Trade memory t = _measured(bob, true, int256(buyOut[i]), 20 ether);
            assertEq(t.tokensOut, buyOut[i], "exact tokens out");
            _recTrade(string.concat("buyExactOut_", vm.toString(i)), t, _checkTrade(t, true, false, 0));
        }
        for (uint256 i; i < 3; ++i) {
            Trade memory t = _measured(bob, false, -int256(sellIn[i]), 0);
            assertEq(t.tokensIn, sellIn[i], "exact tokens in");
            _recTrade(string.concat("sellExactIn_", vm.toString(i)), t, _checkTrade(t, false, false, 0));
        }
        for (uint256 i; i < 3; ++i) {
            Trade memory t = _measured(alice, false, int256(sellOut[i]), 0);
            assertEq(t.nativeOut, sellOut[i], "exact native out");
            _recTrade(string.concat("sellExactOut_", vm.toString(i)), t, _checkTrade(t, false, true, 0));
        }
        _end();
    }

    // ================================================================== second user and time

    function test_exact_S02_secondUserAndTime() public {
        if (!forked) return;
        _launch();
        _begin("S02-second-user-and-time");
        vm.warp(launchTime + 400);
        Trade memory a = _measured(alice, true, -1 ether, 1 ether);
        _recTrade("aliceBuy", a, _checkTrade(a, true, true, 0));
        Trade memory b = _measured(bob, true, -0.5 ether, 0.5 ether);
        _recTrade("bobBuyAfterAlice", b, _checkTrade(b, true, true, 0));
        vm.warp(block.timestamp + 30 days);
        Trade memory c = _measured(alice, false, -int256(a.tokensOut / 2), 0);
        _recTrade("aliceSellAfter30Days", c, _checkTrade(c, false, false, 0));
        vm.warp(block.timestamp + 365 days);
        Trade memory d = _measured(bob, true, 1_000_000e18, 5 ether);
        _recTrade("bobExactOutBuyAfterOneYear", d, _checkTrade(d, true, false, 0));
        Trade memory e = _measured(bob, false, -int256(kmd.balanceOf(bob)), 0);
        _recTrade("bobSellsEverything", e, _checkTrade(e, false, false, 0));
        _recBool("noOracleOrTimeDependenceAfterLaunch", true);
        _end();
    }

    // ================================================================== liquidity custody and withdrawal

    function test_exact_L01_liquidityCustodyAndWithdrawal() public {
        if (!forked) return;
        _launch();
        _begin("L01-liquidity-custody-and-withdrawal");
        PoolId id = key.toId();
        int24 lower = TickMath.minUsableTick(60);
        bytes32 seedPos = Position.calculatePositionKey(address(initializer), lower, startTick, bytes32(0));
        uint128 locked = initializer.lockedLiquidity();
        assertEq(PM.getPositionLiquidity(id, seedPos), locked, "the seed position belongs to the initializer");
        _rec("lockedLiquidity", locked);
        _rec("initializerTokenDust", kmd.balanceOf(address(initializer)));
        _rec("seededTokens", 1_000_000_000e18 - kmd.balanceOf(address(initializer)));
        // A third party can add and fully withdraw its own liquidity; the hook has no liquidity callbacks.
        vm.warp(launchTime + 301);
        _measured(lp, true, -2 ether, 2 ether);
        (, int24 tick,,) = PM.getSlot0(id);
        int24 lo = (tick / 60) * 60 - 600;
        int24 hi = (tick / 60) * 60 + 600;
        PoolModifyLiquidityTest liq = new PoolModifyLiquidityTest(PM);
        vm.deal(address(liq), 0);
        vm.prank(lp);
        kmd.approve(address(liq), type(uint256).max);
        uint256 eth0 = lp.balance;
        uint256 tok0 = kmd.balanceOf(lp);
        vm.prank(lp);
        liq.modifyLiquidity{value: 5 ether}(key, ModifyLiquidityParams(lo, hi, 1e20, bytes32("lp")), "");
        uint256 ethIn = eth0 - lp.balance;
        uint256 tokIn = tok0 - kmd.balanceOf(lp);
        vm.prank(lp);
        liq.modifyLiquidity(key, ModifyLiquidityParams(lo, hi, -1e20, bytes32("lp")), "");
        assertApproxEqAbs(lp.balance, eth0, 2, "LP gets its ETH back (rounding <= 2 wei)");
        assertApproxEqAbs(kmd.balanceOf(lp), tok0, 2, "LP gets its tokens back (rounding <= 2 wei)");
        _rec("thirdPartyEthDeposited", ethIn);
        _rec("thirdPartyTokensDeposited", tokIn);
        _rec("thirdPartyEthRoundingLoss", eth0 - lp.balance);
        _rec("thirdPartyTokenRoundingLoss", tok0 - kmd.balanceOf(lp));
        // Nobody can reach the seed position: it is keyed to the initializer, which has no withdrawal entry point.
        vm.prank(address(PM));
        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        initializer.unlockCallback(abi.encode(key, startTick, address(kmd), stranger, uint256(1), uint256(1)));
        vm.warp(block.timestamp + 3650 days);
        _measured(alice, true, -1 ether, 1 ether);
        assertEq(PM.getPositionLiquidity(id, seedPos), locked, "seed liquidity unchanged after ten years of trading");
        _recBool("seedLiquidityPermanentlyLocked", true);
        _recBool("thirdPartyLiquidityFullyWithdrawable", true);
        _end();
    }

    // ================================================================== callback authentication

    function test_exact_C01_callbackAuthentication() public {
        if (!forked) return;
        _launch();
        _begin("C01-callback-authentication");
        SwapParams memory sp = SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1);
        bytes4 notPm = bytes4(keccak256("NotPoolManager()"));
        vm.prank(stranger);
        vm.expectRevert(notPm);
        IHooks(address(hook)).beforeSwap(stranger, key, sp, "");
        vm.prank(stranger);
        vm.expectRevert(notPm);
        IHooks(address(hook)).afterSwap(stranger, key, sp, BalanceDelta.wrap(0), "");
        vm.prank(stranger);
        vm.expectRevert(notPm);
        IHooks(address(hook)).beforeInitialize(stranger, key, 1);
        // Even the PoolManager cannot complete a swap that the hook did not open.
        vm.prank(address(PM));
        vm.expectRevert(bytes4(keccak256("InvalidSwapContext()")));
        IHooks(address(hook)).afterSwap(stranger, key, sp, BalanceDelta.wrap(0), "");
        vm.expectRevert(bytes4(keccak256("OnlyKernel()")));
        module.openingTaxPpmForSender(stranger);
        vm.expectRevert(bytes4(keccak256("OnlyKernel()")));
        module.protectedBuyer(stranger);
        vm.prank(stranger);
        vm.expectRevert(bytes4(keccak256("UnauthorizedKernel()")));
        fees.recordFees(1, 1);
        vm.prank(address(PM));
        vm.expectRevert(bytes4(keccak256("InvalidClaim()")));
        fees.unlockCallback(abi.encode(stranger, uint256(1)));
        vm.prank(stranger);
        vm.expectRevert(bytes4(keccak256("InvalidClaim()")));
        taxVault.unlockCallback(abi.encode(stranger, uint256(1)));
        vm.prank(address(PM));
        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        initializer.unlockCallback("");
        _recBool("hookCallbacksPoolManagerOnly", true);
        _recBool("afterSwapBoundToActiveSwap", true);
        _recBool("moduleKernelOnly", true);
        _recBool("feeVaultsKernelAndClaimBound", true);
        _recBool("initializerCallbackBoundToItsOwnUnlock", true);
        _end();
    }

    // ================================================================== custom accounting: solvency, inventory, refund, withdrawal

    function test_exact_A01_customAccountingSolvencyRefundWithdrawal() public {
        if (!forked) return;
        _launch();
        _begin("A01-custom-accounting");
        vm.warp(launchTime + 5);
        _measuredUr(alice, 0.02 ether); // opening tax accrues to the separate vault
        vm.warp(launchTime + 301);
        _measured(alice, true, -2 ether, 2 ether);
        // Refund: an exact-output buy funded with far more ETH pays exactly gross and gets the rest back.
        Trade memory r = _measured(bob, true, 3_000_000e18, 10 ether);
        uint256 g = _checkTrade(r, true, false, 0);
        assertEq(r.nativeIn, g, "excess msg.value refunded to the wei");
        _recTrade("exactOutputBuyWith10EthSent", r, g);
        _measured(bob, false, int256(0.01 ether), 0);
        _measured(alice, false, -int256(kmd.balanceOf(alice) / 3), 0);
        // Solvency: every recorded fee is backed one-to-one by PoolManager ERC-6909 native claims.
        uint256 p = fees.platformAccrued();
        uint256 c = fees.creatorAccrued();
        uint256 x = taxVault.platformAccrued();
        assertEq(PM.balanceOf(address(fees), 0), p + c, "fee vault backing");
        assertEq(PM.balanceOf(address(taxVault), 0), x, "opening tax vault backing");
        assertEq(address(hook).balance, 0, "hook holds no ETH");
        assertEq(kmd.balanceOf(address(hook)), 0, "hook holds no tokens");
        assertEq(PM.balanceOf(address(hook), 0), 0, "hook holds no claims");
        // Inventory: fixed supply, nothing minted, every token accounted for.
        assertEq(kmd.totalSupply(), 1_000_000_000e18);
        uint256 held = kmd.balanceOf(address(PM)) + kmd.balanceOf(developer) + kmd.balanceOf(alice) + kmd.balanceOf(bob)
            + kmd.balanceOf(address(initializer));
        assertEq(held, kmd.totalSupply(), "inventory conserved");
        _rec("platformAccrued", p);
        _rec("creatorAccrued", c);
        _rec("openingTaxAccrued", x);
        // Withdrawal: anyone may trigger; funds only reach the fixed recipients.
        uint256 t0 = TREASURY.balance;
        uint256 s0 = stranger.balance;
        vm.prank(stranger);
        assertEq(fees.claimCreator(), c);
        assertEq(vault.balance, c, "creator fees reach KeymindVault");
        assertEq(fees.platformAccrued(), p, "creator claim leaves the platform ledger untouched");
        vm.prank(stranger);
        assertEq(fees.claimPlatform(), p);
        vm.prank(stranger);
        assertEq(taxVault.claimPlatform(), x);
        assertEq(TREASURY.balance - t0, p + x, "platform fee and opening tax reach the treasury");
        assertEq(stranger.balance, s0, "the caller receives nothing");
        assertEq(PM.balanceOf(address(fees), 0), 0);
        assertEq(PM.balanceOf(address(taxVault), 0), 0);
        vm.expectRevert(bytes4(keccak256("NothingToClaim()")));
        fees.claimCreator();
        vm.expectRevert(bytes4(keccak256("NothingToClaim()")));
        fees.claimPlatform();
        vm.expectRevert(bytes4(keccak256("NothingToClaim()")));
        taxVault.claimCreator();
        // KeymindVault: 80% project treasury, 20% Agent Grants pool kept in the vault.
        address projectTreasury = IKeymindVault(vault).treasury();
        uint256 pt0 = projectTreasury.balance;
        IKeymindVault(vault).distribute();
        uint256 paid = projectTreasury.balance - pt0;
        assertEq(paid, c * 8000 / 10_000, "treasury share");
        assertEq(vault.balance, c - paid, "the rewards share stays in the vault");
        assertEq(IKeymindVault(vault).grantsPool(), vault.balance, "booked as the Agent Grants pool");
        _rec("vaultPaidOut", paid);
        _rec("vaultGrantsPool", vault.balance);
        _recBool("solvent", true);
        _recBool("inventoryConserved", true);
        _recBool("refundExact", true);
        _recBool("claimsIsolatedAndCallerIndependent", true);
        _end();
    }

    // ================================================================== KeymindVault Agent Grants (exact deployed vault)

    function test_exact_G01_keymindVaultAgentGrants() public {
        if (!forked) return;
        _launch();
        _begin("G01-keymind-vault-agent-grants");
        vm.warp(launchTime + 301);
        _measured(alice, true, -3 ether, 3 ether);
        _measured(bob, true, -2 ether, 2 ether);
        fees.claimCreator();
        IKeymindVault kv = IKeymindVault(vault);
        kv.distribute();
        uint256 pool = kv.grantsPool();
        assertGt(pool, 0, "grants pool funded by creator fees");
        address grd = kv.guardian();
        bytes32 grantId = keccak256("KMD-GRANT-0001");
        bytes32 desc = keccak256("TypeScript SDK: identity and encrypted messaging");
        uint128 amount = uint128(pool * 2500 / 10_000);
        vm.prank(stranger);
        vm.expectRevert(bytes4(keccak256("NotGuardian()")));
        kv.proposeGrant(grantId, carol, amount, desc);
        vm.prank(grd);
        vm.expectRevert(bytes4(keccak256("GrantTooLarge()")));
        kv.proposeGrant(grantId, carol, amount + 1, desc);
        address projectTreasury = kv.treasury();
        vm.prank(grd);
        vm.expectRevert(bytes4(keccak256("RecipientNotAllowed()")));
        kv.proposeGrant(grantId, projectTreasury, amount, desc);
        vm.prank(grd);
        kv.proposeGrant(grantId, carol, amount, desc);
        vm.prank(stranger);
        vm.expectRevert(bytes4(keccak256("InReview()")));
        kv.executeGrant(grantId);
        vm.warp(block.timestamp + 24 hours);
        uint256 c0 = carol.balance;
        vm.prank(stranger); // anyone can execute after the review
        kv.executeGrant(grantId);
        assertEq(carol.balance - c0, amount, "builder paid in ETH");
        assertEq(kv.grantsPool(), pool - amount, "paid from the grants pool only");
        vm.expectRevert(bytes4(keccak256("GrantAlreadyPaid()")));
        kv.executeGrant(grantId);
        bytes32 cancelled = keccak256("KMD-GRANT-0002");
        vm.prank(grd);
        kv.proposeGrant(cancelled, dave, 1, desc);
        vm.prank(grd);
        kv.cancelGrant(cancelled);
        vm.warp(block.timestamp + 24 hours);
        vm.expectRevert(bytes4(keccak256("GrantIsCancelled()")));
        kv.executeGrant(cancelled);
        _rec("grantsPoolFunded", pool);
        _rec("grantPaid", amount);
        _recBool("onlyGuardianProposes", true);
        _recBool("grantAtMostQuarterOfPool", true);
        _recBool("treasuryCannotReceiveGrant", true);
        _recBool("payoutOnlyAfter24hReview", true);
        _recBool("anyoneExecutesAfterReview", true);
        _recBool("cancelledGrantsNeverPaid", true);
        _end();
    }

    // ================================================================== platform fee: exact 0.3%, no bypass, no overcharge

    function test_exact_F01_platformFeeExactNoBypassNoOvercharge() public {
        if (!forked) return;
        _launch();
        _begin("F01-platform-fee-exact");
        vm.warp(launchTime + 301);
        DirectSwapper direct = new DirectSwapper(PM);
        vm.deal(address(direct), 0);
        uint256 grossSum;
        uint256 platformSum;
        uint256[5] memory sizes = [uint256(1 gwei), 333_333_333_333, 0.0123 ether, 0.7 ether, 4.2 ether];
        for (uint256 i; i < 5; ++i) {
            // Same trade three ways: canonical Universal Router, a v4 test router, a raw PoolManager integration with hookData.
            Trade memory u = _measuredUr(alice, sizes[i]);
            _checkTrade(u, true, true, 0);
            Trade memory t = _measured(bob, true, -int256(sizes[i]), sizes[i]);
            _checkTrade(t, true, true, 0);
            uint256 p0 = fees.platformAccrued();
            uint256 c0 = fees.creatorAccrued();
            uint256 e0 = carol.balance;
            vm.prank(carol);
            direct.buy{value: sizes[i]}(key, sizes[i], abi.encode("arbitrary hook data", i));
            assertEq(e0 - carol.balance, sizes[i]);
            (, uint256 ep, uint256 ec,) = _expect(sizes[i], false, 0);
            assertEq(fees.platformAccrued() - p0, ep, "no bypass through a raw integration");
            assertEq(fees.creatorAccrued() - c0, ec);
            assertEq(u.platform, t.platform, "same fee on every route");
            assertEq(u.platform, ep);
            grossSum += 3 * sizes[i];
            platformSum += 3 * ep;
            _rec(string.concat("platformFeeOnGross_", vm.toString(sizes[i])), ep);
        }
        // Sells: platform share is ceil(gross * 30 / 10000), never more.
        Trade memory s = _measured(alice, false, -int256(kmd.balanceOf(alice) / 2), 0);
        uint256 gs = _checkTrade(s, false, false, 0);
        grossSum += gs;
        platformSum += s.platform;
        assertLe(platformSum * 10_000, grossSum * 30 + 16 * 10_000, "no overcharge beyond one wei of rounding per trade");
        assertGe(platformSum * 10_000, grossSum * 30, "never under 0.30%");
        assertEq(hook.PLATFORM_FEE_BPS(), 30);
        _rec("grossNativeTotal", grossSum);
        _rec("platformFeeTotal", platformSum);
        _rec("platformFeePpmOfGross", platformSum * 1e6 / grossSum);
        _recBool("sameFeeOnEveryRoute", true);
        _recBool("ceilPerTradeNoOvercharge", true);
        _end();
    }
}
