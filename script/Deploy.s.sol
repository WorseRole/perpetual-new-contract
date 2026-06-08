// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../src/Perpetual.sol";

contract DeployPerpetual {
    function deploy() external {
        new Perpetual();
    }
}
