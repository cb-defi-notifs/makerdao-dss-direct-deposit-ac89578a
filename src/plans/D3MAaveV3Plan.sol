// SPDX-FileCopyrightText: © 2021 Dai Foundation <www.daifoundation.org>
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity ^0.8.14;

import "./ID3MPlan.sol";

interface TokenLike {
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
}

interface ATokenLike {
    function ATOKEN_REVISION() external view returns (uint256);
}

interface PoolLike {

    // Need to use a struct as too many variables to return on the stack
    struct ReserveData {
        //stores the reserve configuration
        uint256 configuration;
        //the liquidity index. Expressed in ray
        uint128 liquidityIndex;
        //the current supply rate. Expressed in ray
        uint128 currentLiquidityRate;
        //variable borrow index. Expressed in ray
        uint128 variableBorrowIndex;
        //the current variable borrow rate. Expressed in ray
        uint128 currentVariableBorrowRate;
        //the current stable borrow rate. Expressed in ray
        uint128 currentStableBorrowRate;
        //timestamp of last update
        uint40 lastUpdateTimestamp;
        //the id of the reserve. Represents the position in the list of the active reserves
        uint16 id;
        //aToken address
        address aTokenAddress;
        //stableDebtToken address
        address stableDebtTokenAddress;
        //variableDebtToken address
        address variableDebtTokenAddress;
        //address of the interest rate strategy
        address interestRateStrategyAddress;
        //the current treasury balance, scaled
        uint128 accruedToTreasury;
        //the outstanding unbacked aTokens minted through the bridging feature
        uint128 unbacked;
        //the outstanding debt borrowed against this asset in isolation mode
        uint128 isolationModeTotalDebt;
    }

    function getReserveData(address asset) external view returns (ReserveData memory);
}

interface InterestRateStrategyLike {
    function OPTIMAL_USAGE_RATIO() external view returns (uint256);
    function MAX_EXCESS_USAGE_RATIO() external view returns (uint256);
    function getVariableRateSlope1() external view returns (uint256);
    function getVariableRateSlope2() external view returns (uint256);
    function getBaseVariableBorrowRate() external view returns (uint256);
    function getMaxVariableBorrowRate() external view returns (uint256);
}

contract D3MAaveV3Plan is ID3MPlan {

    mapping (address => uint256) public wards;
    InterestRateStrategyLike     public tack;
    uint256                      public bar; // Target Interest Rate [ray]

    PoolLike  public immutable pool;
    TokenLike public immutable stableDebt;
    TokenLike public immutable variableDebt;
    TokenLike public immutable dai;
    address   public immutable adai;
    uint256   public immutable adaiRevision;

    // --- Events ---
    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event File(bytes32 indexed what, uint256 data);
    event File(bytes32 indexed what, address data);

    constructor(address dai_, address pool_) {
        dai = TokenLike(dai_);
        pool = PoolLike(pool_);

        // Fetch the reserve data from Aave
        PoolLike.ReserveData memory data = pool.getReserveData(dai_);
        require(data.aTokenAddress               != address(0), "D3MAaveV3Plan/invalid-adai");
        require(data.stableDebtTokenAddress      != address(0), "D3MAaveV3Plan/invalid-stableDebt");
        require(data.variableDebtTokenAddress    != address(0), "D3MAaveV3Plan/invalid-variableDebt");
        require(data.interestRateStrategyAddress != address(0), "D3MAaveV3Plan/invalid-interestStrategy");

        adai         = data.aTokenAddress;
        adaiRevision = ATokenLike(adai).ATOKEN_REVISION();
        stableDebt   = TokenLike(data.stableDebtTokenAddress);
        variableDebt = TokenLike(data.variableDebtTokenAddress);
        tack         = InterestRateStrategyLike(data.interestRateStrategyAddress);

        wards[msg.sender] = 1;
        emit Rely(msg.sender);
    }

    modifier auth {
        require(wards[msg.sender] == 1, "D3MAaveV3Plan/not-authorized");
        _;
    }

    // --- Math ---
    uint256 constant RAY = 10 ** 27;
    function _rmul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = (x * y) / RAY;
    }
    function _rdiv(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = (x * RAY) / y;
    }

    // --- Admin ---
    function rely(address usr) external auth {
        wards[usr] = 1;
        emit Rely(usr);
    }
    function deny(address usr) external auth {
        wards[usr] = 0;
        emit Deny(usr);
    }

    function file(bytes32 what, uint256 data) external auth {
        if (what == "bar") bar = data;
        else revert("D3MAaveV3Plan/file-unrecognized-param");
        emit File(what, data);
    }
    function file(bytes32 what, address data) external auth {
        if (what == "tack") tack = InterestRateStrategyLike(data);
        else revert("D3MAaveV3Plan/file-unrecognized-param");
        emit File(what, data);
    }

    // --- Automated Rate targeting ---
    function _calculateTargetSupply(uint256 targetInterestRate, uint256 totalDebt) internal view returns (uint256) {
        uint256 base = tack.getBaseVariableBorrowRate();
        if (targetInterestRate <= base || targetInterestRate > tack.getMaxVariableBorrowRate()) {
            return 0;
        }

        // Do inverse calculation of interestStrategy
        uint256 variableRateSlope1 = tack.getVariableRateSlope1();

        uint256 targetUtil;
        if (targetInterestRate > base + variableRateSlope1) {
            // Excess interest rate
            uint256 r;
            unchecked {
                r = targetInterestRate - base - variableRateSlope1;
            }
            targetUtil = _rdiv(
                            _rmul(
                                tack.MAX_EXCESS_USAGE_RATIO(),
                                r
                            ),
                            tack.getVariableRateSlope2()
                         ) + tack.OPTIMAL_USAGE_RATIO();
        } else {
            // Optimal interest rate
            unchecked {
                targetUtil = _rdiv(
                                _rmul(
                                    targetInterestRate - base,
                                    tack.OPTIMAL_USAGE_RATIO()
                                ),
                                variableRateSlope1
                             );
            }
        }

        return _rdiv(totalDebt, targetUtil);
    }

    // Note: This view function has no reentrancy protection.
    //       On chain integrations should consider verifying `hub.locked()` is zero before relying on it.
    function getTargetAssets(uint256 currentAssets) external override view returns (uint256) {
        uint256 targetInterestRate = bar;
        if (targetInterestRate == 0) return 0; // De-activated

        uint256 totalDebt = stableDebt.totalSupply() + variableDebt.totalSupply();
        uint256 totalPoolSize = dai.balanceOf(adai) + totalDebt;
        uint256 targetTotalPoolSize = _calculateTargetSupply(targetInterestRate, totalDebt);

        if (targetTotalPoolSize >= totalPoolSize) {
            // Increase debt (or same)
            return currentAssets + (targetTotalPoolSize - totalPoolSize);
        } else {
            // Decrease debt
            unchecked {
                uint256 decrease = totalPoolSize - targetTotalPoolSize;
                if (currentAssets >= decrease) {
                    return currentAssets - decrease;
                } else {
                    return 0;
                }
            }
        }
    }

    function active() public view override returns (bool) {
        if (bar == 0) return false;
        PoolLike.ReserveData memory data = pool.getReserveData(address(dai));
        uint256 adaiRevision_ = ATokenLike(data.aTokenAddress).ATOKEN_REVISION();
        return data.interestRateStrategyAddress  == address(tack)          &&
               data.aTokenAddress                == address(adai)          &&
               adaiRevision_                     == adaiRevision           &&
               data.stableDebtTokenAddress       == address(stableDebt)    &&
               data.variableDebtTokenAddress     == address(variableDebt);
    }

    function disable() external override {
        require(wards[msg.sender] == 1 || !active(), "D3MAaveV3Plan/not-authorized");
        bar = 0; // ensure deactivation even if active conditions return later
        emit Disable();
    }
}