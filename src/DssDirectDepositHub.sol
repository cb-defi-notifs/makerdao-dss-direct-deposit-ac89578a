// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2021-2022 Dai Foundation
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

pragma solidity 0.6.12;

interface VatLike {
    function hope(address) external;
    function ilks(bytes32) external view returns (uint256, uint256, uint256, uint256, uint256);
    function urns(bytes32, address) external view returns (uint256, uint256);
    function gem(bytes32, address) external view returns (uint256);
    function live() external view returns (uint256);
    function slip(bytes32, address, int256) external;
    function move(address, address, uint256) external;
    function frob(bytes32, address, address, address, int256, int256) external;
    function grab(bytes32, address, address, address, int256, int256) external;
    function fork(bytes32, address, address, int256, int256) external;
    function suck(address, address, uint256) external;
}

interface EndLike {
    function debt() external view returns (uint256);
    function skim(bytes32, address) external;
}

interface D3MPoolLike {
    function validTarget() external view returns (bool);
    function deposit(uint256) external;
    function withdraw(uint256) external;
    function transferShares(address, uint256) external returns (bool);
    function transferAllShares(address) external returns (bool);
    function accrueIfNeeded() external;
    function assetBalance() external returns (uint256);
    function maxWithdraw() external view returns (uint256);
    function cage() external;
}

interface D3MPlanLike {
    function getTargetAssets(uint256) external view returns (uint256);
}

interface DaiJoinLike {
    function dai() external view returns (address);
    function join(address, uint256) external;
    function exit(address, uint256) external;
}

interface TokenLike {
    function approve(address, uint256) external returns (bool);
}

contract DssDirectDepositHub {

    // --- Auth ---
    mapping (address => uint256) public wards;
    function rely(address usr) external auth {
        wards[usr] = 1;
        emit Rely(usr);
    }
    function deny(address usr) external auth {
        wards[usr] = 0;
        emit Deny(usr);
    }
    modifier auth {
        require(wards[msg.sender] == 1, "DssDirectDepositHub/not-authorized");
        _;
    }

    enum Mode{ NORMAL, MODULE_CULLED, MCD_CAGED }
    uint256             constant  RAY  = 10 ** 27;

    VatLike      public immutable vat;
    DaiJoinLike  public immutable daiJoin;
    address      public           vow;
    EndLike      public           end;

    struct Ilk {
        D3MPoolLike pool;   // Access external pool and holds balances
        D3MPlanLike plan;   // How we calculate target debt
        uint256     tau;    // Time until you can write off the debt [sec]
        uint256     culled; // Debt write off triggered
        uint256     tic;    // Timestamp when the pool is caged
    }
    mapping (bytes32 => Ilk) public ilks;
    uint256                  public live = 1;

    // --- Events ---
    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event File(bytes32 indexed ilk, bytes32 indexed what, address data);
    event File(bytes32 indexed ilk, bytes32 indexed what, uint256 data);
    event File(bytes32 indexed what, address data);
    event Wind(bytes32 indexed ilk, uint256 amount);
    event Unwind(bytes32 indexed ilk, uint256 amount);
    event Reap(bytes32 indexed ilk, uint256 amt);
    event Cage();
    event Cage(bytes32 indexed ilk);
    event Cull(bytes32 indexed ilk);
    event Uncull(bytes32 indexed ilk);
    event Quit(bytes32 indexed ilk, address indexed usr);
    event Exit(bytes32 indexed ilk, address indexed usr, uint256 amt);

    constructor(address vat_, address daiJoin_) public {
        vat = VatLike(vat_);
        daiJoin = DaiJoinLike(daiJoin_);
        TokenLike(DaiJoinLike(daiJoin_).dai()).approve(daiJoin_, type(uint256).max);
        VatLike(vat_).hope(daiJoin_);

        wards[msg.sender] = 1;
        emit Rely(msg.sender);
    }

    // --- Math ---
    function _add(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x + y) >= x, "DssDirectDepositHub/overflow");
    }
    function _sub(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x - y) <= x, "DssDirectDepositHub/underflow");
    }
    function _mul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require(y == 0 || (z = x * y) / y == x, "DssDirectDepositHub/overflow");
    }
    function _min(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = x <= y ? x : y;
    }

    // --- Administration ---
    function file(bytes32 what, address data) external auth {
        require(vat.live() == 1, "DssDirectDepositHub/no-file-during-shutdown");

        if (what == "vow") vow = data;
        else if (what == "end") end = EndLike(data);
        else revert("DssDirectDepositHub/file-unrecognized-param");
        emit File(what, data);
    }

    function file(bytes32 ilk, bytes32 what, uint256 data) external auth {
        require(live == 1, "DssDirectDepositHub/hub-not-live");
        require(ilks[ilk].tic == 0, "DssDirectDepositHub/pool-not-live");

        if (what == "tau" ) {
            ilks[ilk].tau = data;
        } else revert("DssDirectDepositHub/file-unrecognized-param");

        emit File(ilk, what, data);
    }

    function file(bytes32 ilk, bytes32 what, address data) external auth {
        require(live == 1, "DssDirectDepositHub/hub-not-live");
        require(vat.live() == 1, "DssDirectDepositHub/no-file-during-shutdown");
        require(ilks[ilk].tic == 0, "DssDirectDepositHub/pool-not-live");

        if (what == "pool") ilks[ilk].pool = D3MPoolLike(data);
        else if (what == "plan") ilks[ilk].plan = D3MPlanLike(data);
        else revert("DssDirectDepositHub/file-unrecognized-param");
        emit File(ilk, what, data);
    }

    // --- Deposit controls ---
    function _wind(bytes32 ilk, D3MPoolLike pool, uint256 amount) internal {
        // IMPORTANT: this function assumes Vat rate of this ilk will always be == 1 * RAY (no fees).
        // That's why this module converts normalized debt (art) to Vat DAI generated with a simple RAY multiplication or division
        // This module will have an unintended behaviour if rate is changed to some other value.
        if (amount == 0) {
            emit Wind(ilk, 0);
            return;
        }

        require(int256(amount) >= 0, "DssDirectDepositHub/overflow");

        vat.slip(ilk, address(pool), int256(amount));
        vat.frob(ilk, address(pool), address(pool), address(this), int256(amount), int256(amount));
        // normalized debt == erc20 DAI (Vat rate for this ilk fixed to 1 RAY)
        daiJoin.exit(address(pool), amount);
        pool.deposit(amount);

        emit Wind(ilk, amount);
    }

    function _unwind(bytes32 ilk, D3MPoolLike pool, uint256 supplyReduction, uint256 availableLiquidity, Mode mode, uint256 assetBalance) internal {
        // IMPORTANT: this function assumes Vat rate of this ilk will always be == 1 * RAY (no fees).
        // That's why it converts normalized debt (art) to Vat DAI generated with a simple RAY multiplication or division
        // This module will have an unintended behaviour if rate is changed to some other value.

        EndLike end_;
        uint256 daiDebt;
        if (mode == Mode.NORMAL) {
            // Normal mode or module just caged (no culled)
            // debt is obtained from CDP art
            (,daiDebt) = vat.urns(ilk, address(pool));
        } else if (mode == Mode.MODULE_CULLED) {
            // Module shutdown and culled
            // debt is obtained from free collateral owned by this contract
            daiDebt = vat.gem(ilk, address(pool));
        } else {
            // MCD caged
            // debt is obtained from free collateral owned by the End module
            end_ = end;
            end_.skim(ilk, address(pool));
            daiDebt = vat.gem(ilk, address(end_));
        }

        // Unwind amount is limited by how much:
        // - max reduction desired
        // - liquidity available
        // - gem we have to withdraw
        // - dai debt tracked in vat (CDP or free)
        uint256 amount = _min(
                            _min(
                                _min(
                                    supplyReduction,
                                    availableLiquidity
                                ),
                                assetBalance
                            ),
                            daiDebt
                        );

        // Determine the amount of fees to bring back
        uint256 fees = 0;
        if (assetBalance > daiDebt) {
            fees = assetBalance - daiDebt;

            if (_add(amount, fees) > availableLiquidity) {
                // Don't need safe-math because this is constrained above
                fees = availableLiquidity - amount;
            }
        }

        if (amount == 0 && fees == 0) {
            emit Unwind(ilk, 0);
            return;
        }

        require(amount <= 2 ** 255, "DssDirectDepositHub/overflow");

        // To save gas you can bring the fees back with the unwind
        uint256 total = _add(amount, fees);
        pool.withdraw(total);
        daiJoin.join(address(this), total);

        // normalized debt == erc20 DAI to pool (Vat rate for this ilk fixed to 1 RAY)

        if (mode == Mode.NORMAL) {
            vat.frob(ilk, address(pool), address(pool), address(this), -int256(amount), -int256(amount));
            vat.slip(ilk, address(pool), -int256(amount));
            vat.move(address(this), vow, _mul(fees, RAY));
        } else if (mode == Mode.MODULE_CULLED) {
            vat.slip(ilk, address(pool), -int256(amount));
            vat.move(address(this), vow, _mul(total, RAY));
        } else {
            // This can be done with the assumption that the price of 1 aDai equals 1 DAI.
            // That way we know that the prev End.skim call kept its gap[ilk] emptied as the CDP was always collateralized.
            // Otherwise we couldn't just simply take away the collateral from the End module as the next line will be doing.
            vat.slip(ilk, address(end_), -int256(amount));
            vat.move(address(this), vow, _mul(total, RAY));
        }

        emit Unwind(ilk, amount);
    }

    function exec(bytes32 ilk_) external {
        D3MPoolLike pool = ilks[ilk_].pool;

        pool.accrueIfNeeded();
        uint256 availableAssets = pool.maxWithdraw();
        uint256 currentAssets = pool.assetBalance();

        if (vat.live() == 0) {
            // MCD caged
            require(end.debt() == 0, "DssDirectDepositHub/end-debt-already-set");
            require(ilks[ilk_].culled == 0, "DssDirectDepositHub/module-has-to-be-unculled-first");
            _unwind(
                ilk_,
                pool,
                type(uint256).max,
                availableAssets,
                Mode.MCD_CAGED,
                currentAssets
            );
        } else if (live == 0) {
            // This module caged
            _unwind(
                ilk_,
                pool,
                type(uint256).max,
                availableAssets,
                ilks[ilk_].culled == 1
                ? Mode.MODULE_CULLED
                : Mode.NORMAL,
                currentAssets
            );
        } else {
            // Normal path
            uint256 targetAssets = ilks[ilk_].plan.getTargetAssets(currentAssets);

            if (targetAssets > currentAssets) {
                // Amount is limited by the debt ceiling
                (uint256 Art,,, uint256 line,) = vat.ilks(ilk_);
                uint256 lineWad = line / RAY; // Round down to always be under the actual limit

                if(Art > lineWad) { // Our debt is greater than our debt ceiling, we need to unwind
                    _unwind(
                        ilk_,
                        pool,
                        Art - lineWad,
                        availableAssets,
                        Mode.NORMAL,
                        currentAssets
                    );
                } else {
                    uint256 amount = targetAssets - currentAssets;
                    if (_add(Art, amount) > lineWad) { // we do not have enough room in the debt ceiling to fully wind
                        amount = lineWad - Art;
                    }
                    _wind(ilk_, pool, amount);
                }
            } else if (targetAssets < currentAssets) {
                _unwind(
                    ilk_,
                    pool,
                    currentAssets - targetAssets,
                    availableAssets,
                    Mode.NORMAL,
                    currentAssets
                );
            }
        }
    }

    // --- Collect Interest ---
    function reap(bytes32 ilk_) external {
        D3MPoolLike pool = ilks[ilk_].pool;

        require(vat.live() == 1, "DssDirectDepositHub/no-reap-during-shutdown");
        require(live == 1, "DssDirectDepositHub/no-reap-during-cage");

        pool.accrueIfNeeded();
        uint256 assetBalance = pool.assetBalance();
        (, uint256 daiDebt) = vat.urns(ilk_, address(pool));
        if (assetBalance > daiDebt) {
            uint256 fees = assetBalance - daiDebt;
            uint256 availableAssets = pool.maxWithdraw();
            if (fees > availableAssets) {
                fees = availableAssets;
            }
            pool.withdraw(fees);
            daiJoin.join(vow, fees);
            emit Reap(ilk_, fees);
        }
    }

    // --- Allow DAI holders to exit during global settlement ---
    // wad: should be amount of gems, this could be different than the share tokens
    function exit(bytes32 ilk_, address usr, uint256 wad) external {
        require(wad <= 2 ** 255, "DssDirectDepositHub/overflow");
        vat.slip(ilk_, msg.sender, -int256(wad));
        D3MPoolLike pool = ilks[ilk_].pool;
        require(pool.transferShares(usr, wad), "DssDirectDepositHub/failed-transfer");
        emit Exit(ilk_, usr, wad);
    }

    // --- Shutdown ---
    function cage(bytes32 ilk_) external {
        require(vat.live() == 1, "DssDirectDepositHub/no-cage-during-shutdown");

        D3MPoolLike pool = ilks[ilk_].pool;

        // Can shut pools down if we are authed
        // or if the interest rate strategy changes
        // or if the main module is caged
        require(
            wards[msg.sender] == 1 ||
            live == 0 ||
            !pool.validTarget()
        , "DssDirectDepositHub/not-authorized");

        pool.cage();
        ilks[ilk_].tic = block.timestamp;
        emit Cage(ilk_);
    }

    function cage() external auth {
        require(vat.live() == 1, "DssDirectDepositHub/no-cage-during-shutdown");

        live = 0;
        emit Cage();
    }

    // --- Write-off ---
    function cull(bytes32 ilk_) external {
        require(vat.live() == 1, "DssDirectDepositHub/no-cull-during-shutdown");
        require(live == 0, "DssDirectDepositHub/live");

        uint256     tic     = ilks[ilk_].tic;
        uint256     culled  = ilks[ilk_].culled;
        uint256     tau     = ilks[ilk_].tau;
        D3MPoolLike pool    = ilks[ilk_].pool;

        require(tic > 0, "DssDirectDepositHub/pool-live");
        require(_add(tic, tau) <= block.timestamp || wards[msg.sender] == 1, "DssDirectDepositHub/unauthorized-cull");
        require(culled == 0, "DssDirectDepositHub/already-culled");

        (uint256 ink, uint256 art) = vat.urns(ilk_, address(pool));
        require(ink <= 2 ** 255, "DssDirectDepositHub/overflow");
        require(art <= 2 ** 255, "DssDirectDepositHub/overflow");
        vat.grab(ilk_, address(pool), address(pool), vow, -int256(ink), -int256(art));

        ilks[ilk_].culled = 1;
        emit Cull(ilk_);
    }

    // --- Rollback Write-off (only if General Shutdown happened) ---
    // This function is required to have the collateral back in the vault so it can be taken by End module
    // and eventually be shared to DAI holders (as any other collateral) or maybe even unwinded
    function uncull(bytes32 ilk_) external {
        D3MPoolLike pool = ilks[ilk_].pool;

        require(ilks[ilk_].culled == 1, "DssDirectDepositHub/not-prev-culled");
        require(vat.live() == 0, "DssDirectDepositHub/no-uncull-normal-operation");

        address vow_ = vow;
        uint256 wad = vat.gem(ilk_, address(pool));
        require(wad < 2 ** 255, "DssDirectDepositHub/overflow");
        vat.suck(vow_, vow_, _mul(wad, RAY)); // This needs to be done to make sure we can deduct sin[vow] and vice in the next call
        vat.grab(ilk_, address(pool), address(pool), vow_, int256(wad), int256(wad));

        ilks[ilk_].culled = 0;
        emit Uncull(ilk_);
    }

    // --- Emergency Quit Everything ---
    function quit(bytes32 ilk_, address who) external auth {
        require(vat.live() == 1, "DssDirectDepositHub/no-quit-during-shutdown");

        D3MPoolLike pool = ilks[ilk_].pool;

        // Send all gem in the contract to who
        require(pool.transferAllShares(who), "DssDirectDepositHub/failed-transfer");

        if (ilks[ilk_].culled == 1) {
            // Culled - just zero out the gems
            uint256 wad = vat.gem(ilk_, address(pool));
            require(wad <= 2 ** 255, "DssDirectDepositHub/overflow");
            vat.slip(ilk_, address(pool), -int256(wad));
        } else {
            // Regular operation - transfer the debt position (requires who to accept the transfer)
            (uint256 ink, uint256 art) = vat.urns(ilk_, address(pool));
            require(ink < 2 ** 255, "DssDirectDepositHub/overflow");
            require(art < 2 ** 255, "DssDirectDepositHub/overflow");
            vat.fork(ilk_, address(pool), who, int256(ink), int256(art));
        }
        emit Quit(ilk_, who);
    }
}
