// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IPermapool {
    function collectFees() external ;
    function upgradeGovernance(address governance) external;
}
