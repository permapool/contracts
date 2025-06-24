// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./IGovernance.sol";
import "./IPermapool.sol";

contract Governance is IGovernance, Ownable {
    using EnumerableMap for EnumerableMap.AddressToUintMap;
    using EnumerableSet for EnumerableSet.AddressSet;

    struct Proposal {
        uint id;
        address target;
        address permapool;
        uint weight;
        uint expiration;
        bool passed;
    }
    mapping(uint => EnumerableSet.AddressSet) private _proposalVoters;

    uint public constant MIN_SQUAD_WEIGHT = 1;
    uint public constant MAX_SQUAD_WEIGHT = 3;

    uint public FEE_CLAIM_DELAY;
    uint public PROPOSAL_DURATION;

    EnumerableMap.AddressToUintMap _squadMemberWeights;
    EnumerableSet.AddressSet private _guardians;
    Proposal[] private _proposals;

    uint private _unclaimedSquadEth;
    uint private _lastFeeClaimTime;
    uint private _totalSquadWeight;

    modifier onlySquad {
        require(_squadMemberWeights.contains(msg.sender), "Only squad members can perform this action");
        _;
    }

    constructor(
        address[] memory squadMembers,
        uint[] memory squadWeights,
        uint feeClaimDelay,
        uint proposalDuration
    ) {
        FEE_CLAIM_DELAY = feeClaimDelay;
        PROPOSAL_DURATION = proposalDuration;

        // Add the initial squad members and associated weights
        uint totalSquadWeight = 0;
        for (uint i = 0; i < squadMembers.length; i++) {
            require(_squadMemberWeights.set(squadMembers[i], squadWeights[i]), "Duplicate squad member");
            require(
                squadWeights[i] >= MIN_SQUAD_WEIGHT &&
                squadWeights[i] <= MAX_SQUAD_WEIGHT,
                "Invalid squad weight"
            );
            if (squadWeights[i] == MAX_SQUAD_WEIGHT) {
                // Make them a guardian
                require(_guardians.add(squadMembers[i]), "Duplicate guardian");
            }
            totalSquadWeight += squadWeights[i];
        }
        require(totalSquadWeight > 0, "Squad weight cannot be zero");
        _totalSquadWeight = totalSquadWeight;
    }

    receive() external payable {}

    function getDonationFees(uint donation) external pure returns (uint) {
        // Simple 10%
        return donation / 10;
    }

    // Send all token LP fees to guardians
    // Save all eth LP fees for squad to claim
    function payLpFees(address token, uint amountToken) external payable {
        _unclaimedSquadEth += msg.value;

        address[] memory guardians = _guardians.values();
        uint tokenToSend = amountToken / guardians.length;
        bool allTransferred = true;
        if (tokenToSend > 0) {
            for (uint i = 0; i < guardians.length; i++) {
                allTransferred = allTransferred && IERC20(token).transfer(guardians[i], tokenToSend);
            }
        }
        require(allTransferred, "Unable to transfer tokens");
    }

    // Send all eth donation fees to guardians
    function payDonationFees() external payable {
        bool allTransferred = true;
        address[] memory guardians = _guardians.values();
        if (guardians.length == 0) {
            // Hold money in the contract
            return;
        }
        uint ethToSend = msg.value / guardians.length;
        if (ethToSend == 0) {
            return;
        }
        for (uint i = 0; i < guardians.length; i++)  {
            (bool transferred,) = guardians[i].call{value: ethToSend}("");
            allTransferred = allTransferred && transferred;
        }
        require(allTransferred, "Unable to transfer eth");
    }

    // Claim fees from the LP position after a minimum delay
    function claimFees(address permapool) external {
        require(block.timestamp >= _lastFeeClaimTime + FEE_CLAIM_DELAY, "Minimum claim delay not observed");
        _lastFeeClaimTime = block.timestamp;

        IPermapool(permapool).collectFees();

        uint unclaimedSquadEth = _unclaimedSquadEth;
        if (unclaimedSquadEth > 0) {
            _unclaimedSquadEth = 0;
            uint totalSquadWeight = _totalSquadWeight;
            address[] memory squadMembers = _squadMemberWeights.keys();
            bool allTransferred = true;
            for (uint i = 0; i < squadMembers.length; i++)  {
                address member = squadMembers[i];
                uint ethToSend = unclaimedSquadEth * _squadMemberWeights.get(member) / totalSquadWeight;
                if (ethToSend > 0) {
                    (bool transferred,) = member.call{value: ethToSend}("");
                    allTransferred = allTransferred && transferred;
                }
            }
            require(allTransferred, "Unable to transfer eth");
        }
    }

    function decreaseWeight(uint newWeight) external onlySquad {
        uint oldWeight = _squadMemberWeights.get(msg.sender);
        require(newWeight < oldWeight, "New squad weight must be less than current weight");
        if (newWeight == 0) {
            _squadMemberWeights.remove(msg.sender);
        } else {
            _squadMemberWeights.set(msg.sender, newWeight);
        }
        if (oldWeight == MAX_SQUAD_WEIGHT) {
            _guardians.remove(msg.sender);
        }
        _totalSquadWeight -= oldWeight - newWeight;
    }

    function proposeWeightChange(address member, uint weight) external onlySquad {
        (, uint currentWeight) = _squadMemberWeights.tryGet(member);
        require(currentWeight != weight, "Already at desired weight");
        _proposals.push();
        uint proposalId = _proposals.length - 1;
        Proposal storage proposal = _proposals[proposalId];
        proposal.id = proposalId;
        proposal.target = member;
        proposal.weight = weight;
        proposal.expiration = block.timestamp + PROPOSAL_DURATION;
        vote(proposalId);
    }

    function proposeGovernanceUpgrade(address permapool, address governance) external onlySquad {
        _proposals.push();
        uint proposalId = _proposals.length - 1;
        Proposal storage proposal = _proposals[proposalId];
        proposal.id = proposalId;
        proposal.target = governance;
        proposal.permapool = permapool;
        proposal.expiration = block.timestamp + PROPOSAL_DURATION;
        vote(proposalId);
    }

    // Vote on a proposal. If the proposal reaches > 50%, execute it immediately
    function vote(uint proposalId) public onlySquad {
        require(_proposalVoters[proposalId].add(msg.sender), "Already voted");

        tally(proposalId);
    }

    function tally(uint proposalId) public {
        Proposal storage proposal = _proposals[proposalId];
        require(proposal.expiration > block.timestamp, "Proposal expired");
        require(!proposal.passed, "Proposal already passed");
        if (2 * getProposalVoteWeight(proposalId) > _totalSquadWeight) {
            proposal.passed = true;
            // VOTE PASSED
            if (proposal.permapool != address(0)) {
                // Vote to upgrade permapool governance
                IPermapool(proposal.permapool).upgradeGovernance(proposal.target);
            } else {
                // Vote to update squad weights
                (, uint oldWeight) = _squadMemberWeights.tryGet(proposal.target);
                uint newWeight = proposal.weight;
                if (newWeight == MAX_SQUAD_WEIGHT) {
                    _squadMemberWeights.set(proposal.target, newWeight);
                    _guardians.add(proposal.target);
                } else if (newWeight > 0) {
                    _squadMemberWeights.set(proposal.target, newWeight);
                } else {
                    _squadMemberWeights.remove(proposal.target);
                    _guardians.remove(proposal.target);
                }

                if (newWeight > oldWeight) {
                    _totalSquadWeight += newWeight - oldWeight;
                } else if (newWeight < oldWeight) {
                    _totalSquadWeight -= oldWeight - newWeight;
                }
            }
        }
    }

    function getGuardians() external view returns (address[] memory) {
        return _guardians.values();
    }

    function isGuardian(address member) external view returns (bool) {
        return _guardians.contains(member);
    }

    function getSquadMembers() external view returns (address[] memory) {
        return _squadMemberWeights.keys();
    }

    function isSquadMember(address member) external view returns (bool) {
        return _squadMemberWeights.contains(member);
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
    function getProposals() external view returns (Proposal[] memory) {
        return _proposals;
    }
    function getProposal(uint proposalId) external view returns (Proposal memory) {
        return _proposals[proposalId];
    }
    function getProposalVoters(uint proposalId) external view returns (address[] memory) {
        return _proposalVoters[proposalId].values();
    }
    function hasVoted(address member, uint proposalId) external view returns (bool) {
        return _proposalVoters[proposalId].contains(member);
    }
    function getProposalVoteWeight(uint proposalId) public view returns (uint) {
        uint totalVoteWeight = 0;
        address[] memory voters = _proposalVoters[proposalId].values();
        for (uint i = 0; i < voters.length; i++) {
            (, uint voteWeight) = _squadMemberWeights.tryGet(voters[i]);
            totalVoteWeight += voteWeight;
        }
        return totalVoteWeight;
    }
    function getTotalSquadWeight() external view returns (uint) {
        return _totalSquadWeight;
    }
    function getLastFeeClaimTime() external view returns (uint) {
        return _lastFeeClaimTime;
    }
    function getUnclaimedSquadEth() external view returns (uint) {
        return _unclaimedSquadEth;
    }

    // Temporary; access will be renounced
    function setFeeClaimDelay(uint delay) external onlyOwner {
        FEE_CLAIM_DELAY = delay;
    }
    function setProposalDuration(uint duration) external onlyOwner {
        PROPOSAL_DURATION = duration;
    }
}
