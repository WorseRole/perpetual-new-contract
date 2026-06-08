// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../src/Perpetual.sol";

contract PerpetualTest {
    Perpetual perp;

    function setUp() public {
        perp = new Perpetual();
    }

    function testOpenAndClosePosition() public {
        perp.openPosition(1, 1);
        perp.closePosition();
        assert(address(perp).balance == 0);
    }
}
