// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./IWETH.sol";

interface IPermapool {
    function withdrawFees() external;
    function upgradeGovernance(address newContract) external;
}

contract Governance {
    using EnumerableMap for EnumerableMap.AddressToUintMap;
    using EnumerableSet for EnumerableSet.AddressSet;

    struct Proposal {
        address target;
        uint weight;
        bool guardian;
        bool governance;
        uint expiration;
        EnumerableSet.AddressSet voters;
    }

    address public constant WETH = 0x4200000000000000000000000000000000000006;
    uint public constant FEE_WITHDRAWAL_DELAY = 7 * 86400; // 1 Week
    uint public constant FEE_DISTRIBUTION_DELAY = 86400; // 1 Day
    uint public constant PROPOSAL_DURATION = 7 * 86400; // 1 Week
    uint public constant MIN_SQUAD_WEIGHT = 1;
    uint public constant MAX_SQUAD_WEIGHT = 3;

    address public immutable TOKEN;
    address private immutable PERMAPOOL;

    EnumerableMap.AddressToUintMap _squadMemberWeights;
    EnumerableSet.AddressSet private _guardians;
    Proposal[] private _proposals;

    uint private _lastFeeWithdrawTime;
    uint private _totalSquadWeight;

    modifier onlySquad {
        require(_squadMemberWeights.contains(msg.sender), "Not a squad member");
        _;
    }

    constructor(
        address token,
        address permapool,
        address[] memory guardians,
        address[] memory squadMembers,
        uint[] memory squadWeights
    ) {
        TOKEN = token;
        PERMAPOOL = permapool;

        // Add the initial guardians
        for (uint i = 0; i < guardians.length; i++) {
            require(_guardians.add(guardians[i]), "Duplicate guardian");
        }

        // Add the initial squad members and associated weights
        uint totalSquadWeight = 0;
        for (uint i = 0; i < squadMembers.length; i++) {
            require(_squadMemberWeights.set(squadMembers[i], squadWeights[i]), "Duplicate squad member");
            require(
                squadWeights[i] >= MIN_SQUAD_WEIGHT &&
                squadWeights[i] <= MAX_SQUAD_WEIGHT,
                "Invalid squad weight"
            );
            totalSquadWeight += squadWeights[i];
        }
        require(totalSquadWeight > 0, "Squad weight cannot be zero");
        _totalSquadWeight = totalSquadWeight;
    }

    receive() external payable {}

    // Withdraw fees from the LP position after a minimum delay
    function withdrawFees() external {
        require(block.timestamp >= _lastFeeWithdrawTime + FEE_WITHDRAWAL_DELAY, "Minimum withdraw delay not observed");
        IPermapool(PERMAPOOL).withdrawFees();
        _lastFeeWithdrawTime = block.timestamp;
    }

    // Distribute fees to squad members after a minimum delay
    function distributeFees() external {
        require(block.timestamp >= _lastFeeWithdrawTime + FEE_DISTRIBUTION_DELAY, "Minimum distribute delay not observed");

        uint wethBalance = IERC20(WETH).balanceOf(address(this));
        if (wethBalance > 0) {
            IWETH(WETH).withdraw(wethBalance);
        }

        uint ethBalance = address(this).balance;
        if (ethBalance > 0) {
            uint totalSquadWeight = _totalSquadWeight;
            EnumerableMap.AddressToUintMap storage squadMemberWeights = _squadMemberWeights;
            address[] memory squadMembers = squadMemberWeights.keys();
            for (uint i = 0; i < squadMembers.length; i++) {
                uint amountToSend = ethBalance * squadMemberWeights.get(squadMembers[i]) / totalSquadWeight;
                (bool transferred,) = squadMembers[i].call{value: amountToSend}("");
                require(transferred, "Transfer failed");
            }
        }

        IERC20 token = IERC20(TOKEN);
        uint tokenBalance = token.balanceOf(address(this));
        if (tokenBalance > 0) {
            address[] memory guardians = _guardians.values();
            for (uint i = 0; i < guardians.length; i++) {
                require(token.transfer(guardians[i], tokenBalance / guardians.length), "Unable to transfer token");
            }
        }
    }

    function decreaseSquadWeight(uint newWeight) external {
        uint currentWeight = _squadMemberWeights.get(msg.sender);
        require(newWeight < currentWeight, "New weight exceeds current weight");
        if (newWeight == 0) {
            _squadMemberWeights.remove(msg.sender);
        } else {
            _squadMemberWeights.set(msg.sender, newWeight);
        }
    }

    function removeGuardianRole() external {
        require(_guardians.remove(msg.sender), "Not a guardian currently");
    }

    function proposeSquadWeightIncrease(address target) external onlySquad {
        (, uint currentWeight) = _squadMemberWeights.tryGet(target);
        require(currentWeight < MAX_SQUAD_WEIGHT, "Already at max squad weight");
        _proposals.push();
        uint proposalId = _proposals.length - 1;
        Proposal storage proposal = _proposals[proposalId];
        proposal.target = target;
        proposal.weight = currentWeight + 1;
        proposal.expiration = block.timestamp + PROPOSAL_DURATION;
        vote(proposalId);
    }

    function proposeSquadWeightDecrease(address target, uint newWeight) external onlySquad {
        (, uint currentWeight) = _squadMemberWeights.tryGet(target);
        require(currentWeight > newWeight, "Not a decrease");
        _proposals.push();
        uint proposalId = _proposals.length - 1;
        Proposal storage proposal = _proposals[proposalId];
        proposal.target = target;
        proposal.weight = newWeight;
        proposal.expiration = block.timestamp + PROPOSAL_DURATION;
        vote(proposalId);
    }

    function proposeGuardianAddition(address target) external onlySquad {
        _proposals.push();
        uint proposalId = _proposals.length - 1;
        Proposal storage proposal = _proposals[proposalId];
        proposal.target = target;
        proposal.weight = 1;
        proposal.guardian = true;
        proposal.expiration = block.timestamp + PROPOSAL_DURATION;
        vote(proposalId);
    }

    function proposeGuardianRemoval(address target) external onlySquad {
        _proposals.push();
        uint proposalId = _proposals.length - 1;
        Proposal storage proposal = _proposals[proposalId];
        proposal.target = target;
        proposal.weight = 0;
        proposal.guardian = true;
        proposal.expiration = block.timestamp + PROPOSAL_DURATION;
        vote(proposalId);
    }

    function proposeGovernanceUpgrade(address target) external onlySquad {
        _proposals.push();
        uint proposalId = _proposals.length - 1;
        Proposal storage proposal = _proposals[proposalId];
        proposal.target = target;
        proposal.governance = true;
        proposal.expiration = block.timestamp + PROPOSAL_DURATION;
        vote(proposalId);
    }

    // Vote on a proposal. If the proposal reaces > 50%, execute it immediately
    function vote(uint proposalId) public {
        Proposal storage proposal = _proposals[proposalId];
        require(proposal.voters.add(msg.sender), "Already voted");
        require(proposal.expiration > block.timestamp, "Proposal expired");

        EnumerableMap.AddressToUintMap storage squadMemberWeights = _squadMemberWeights;
        require(squadMemberWeights.contains(msg.sender), "Not a squad member");

        uint totalVoteWeight = 0;
        address[] memory voters = proposal.voters.values();
        for (uint i = 0; i < voters.length; i++) {
            (,uint voteWeight) = squadMemberWeights.tryGet(voters[i]);
            totalVoteWeight += voteWeight;
        }
        if (2 * totalVoteWeight > _totalSquadWeight) { // VOTE PASSED
            if (proposal.governance) {
                // Upgrade the pool governance contract from this contract to a new contract
                IPermapool(PERMAPOOL).upgradeGovernance(proposal.target);
            } else if (proposal.guardian) {
                // Update guardian status
                if (proposal.weight > 0) {
                    _guardians.add(proposal.target);
                } else {
                    _guardians.remove(proposal.target);
                }
            } else {
                // Update squad member weight
                (, uint currentWeight) = _squadMemberWeights.tryGet(proposal.target);
                if (proposal.weight > currentWeight) {
                    _squadMemberWeights.set(proposal.target, currentWeight + 1);
                    _totalSquadWeight += 1;
                } else if (proposal.weight == 0) {
                    _squadMemberWeights.remove(proposal.target);
                } else {
                    _squadMemberWeights.set(proposal.target, proposal.weight);
                    _totalSquadWeight -= currentWeight - proposal.weight;
                }
            }
        }
    }

    function getGuardians() external view returns (address[] memory) {
        return _guardians.values();
    }

    function getSquadMembers() external view returns (address[] memory) {
        return _squadMemberWeights.keys();
    }

    function getSquadMembersAndWeights() external view returns (address[] memory, uint[] memory) {
        address[] memory members = _squadMemberWeights.keys();
        uint[] memory weights = new uint[](members.length);
        for (uint i = 0; i < members.length; i++) {
            weights[i] = _squadMemberWeights.get(members[i]);
        }
        return (members, weights);
    }

    function getSquadMemberWeight(address member) external view returns (uint) {
        return _squadMemberWeights.get(member);
    }

    function getNumProposals() external view returns (uint) {
        return _proposals.length;
    }
    function getProposalAt(uint index) external view returns (address, uint, bool, bool, uint) {
        Proposal storage proposal = _proposals[index];
        return (
            proposal.target,
            proposal.weight,
            proposal.guardian,
            proposal.governance,
            proposal.expiration
        );
    }
    function getProposalVoters(uint index) external view returns (address[] memory) {
        return _proposals[index].voters.values();
    }
    function getProposalVoteWeight(uint index) external view returns (uint) {
        address[] memory voters = _proposals[index].voters.values();
        uint totalVoteWeight = 0;
        for (uint i = 0; i < voters.length; i++) {
            (, uint voteWeight) = _squadMemberWeights.tryGet(voters[i]);
            totalVoteWeight += voteWeight;
        }
        return totalVoteWeight;
    }
    function getTotalSquadWeight() external view returns (uint) {
        return _totalSquadWeight;
    }
    function getlastFeeWithdrawTime() external view returns (uint) {
        return _lastFeeWithdrawTime;
    }
}
