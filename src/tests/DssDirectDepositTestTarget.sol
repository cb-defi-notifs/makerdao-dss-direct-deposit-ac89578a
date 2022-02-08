// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2021 Dai Foundation
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

contract DssDirectDepositTestTarget {
    // --- Auth ---
    mapping (address => uint) public wards;
    function rely(address usr) external auth {
        wards[usr] = 1;

        emit Rely(usr);
    }
    function deny(address usr) external auth {
        wards[usr] = 0;

        emit Deny(usr);
    }
    modifier auth {
        require(wards[msg.sender] == 1, "DssDirectDepositAaveDai/not-authorized");
        _;
    }

    address public immutable pool;
    address public immutable rewardsClaimer;

    // test helper variables
    uint256 maxBar;
    bool    isValidTarget;
    uint256 supplyAmount;
    uint256 targetSupply;

    uint256 public live = 1;

    // --- Events ---
    event Rely(address indexed usr);
    event Deny(address indexed usr);

    constructor(address dai_, address pool_, address _rewardsClaimer) public {

        pool = pool_;
        rewardsClaimer = _rewardsClaimer;

        wards[msg.sender] = 1;
        emit Rely(msg.sender);

        dai_;
    }

    function file(bytes32 what, uint256 data) external auth {
        if (what == "maxBar") {
            maxBar = data;
        } else if (what == "supplyAmount") {
            supplyAmount = data;
        } else if (what == "targetSupply") {
            targetSupply = data;
        }
    }

    function file(bytes32 what, bool data) external auth {
    if (what == "isValidTarget") {
        isValidTarget = data;
    }
    }

    function getMaxBar() external view returns (uint256) {
        return maxBar;
    }

    function validTarget(address wat) external view returns (bool) {
        return isValidTarget;
    }

    function calcSupplies(uint256 availableLiquidity, uint256 bar) external view returns (uint256, uint256) {
        availableLiquidity; bar;
        return (supplyAmount, targetSupply);
    }

    function supply(address, uint256) external;
    function withdraw(address, uint256) external;
    function getNormalizedBalanceOf(address) external view returns(uint256);
    function getNormalizedAmount(address, uint256) external view returns(uint256);
    function cage() external;

}