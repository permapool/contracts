// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IPermapool {
    function collectFees() external returns (uint, uint);
    function upgradeGovernance(address governance) external;
    function TOKEN() external returns (address);
}