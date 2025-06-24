// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IGovernance {
    function getDonationFees(uint amountEth) external returns (uint);
    function payLpFees(address token, uint amountToken) external payable;
    function payDonationFees() external payable;
}
