// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IGovernance {
    function getGuardians() external returns (address[] memory);
}
