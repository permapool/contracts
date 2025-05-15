// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./IPermapool.sol";
import "./IWETH.sol";

contract Governance {
    using EnumerableMap for EnumerableMap.AddressToUintMap;
    using EnumerableSet for EnumerableSet.AddressSet;

    struct Proposal {
        uint id;
        address target;
        uint weight;
        bool governance;
        uint expiration;
        bool passed;
    }
    mapping(uint => EnumerableSet.AddressSet) private _proposalVoters;

    IWETH public constant WETH = IWETH(0x4200000000000000000000000000000000000006);
    uint public constant MIN_SQUAD_WEIGHT = 1;
    uint public constant MAX_SQUAD_WEIGHT = 3;

    uint public immutable FEE_CLAIM_DELAY;
    uint public immutable FEE_SEND_DELAY;
    uint public immutable PROPOSAL_DURATION;
    IERC20 public immutable TOKEN;
    IPermapool private immutable PERMAPOOL;

    EnumerableMap.AddressToUintMap _squadMemberWeights;
    EnumerableSet.AddressSet private _guardians;
    Proposal[] private _proposals;

    uint private _lastFeeClaimTime;
    uint private _totalSquadWeight;

    modifier onlySquad {
        require(_squadMemberWeights.contains(msg.sender), "Only squad members can perform this action");
        _;
    }

    constructor(
        address permapool,
        address[] memory squadMembers,
        uint[] memory squadWeights,
        uint feeClaimDelay,
        uint feeSendDelay,
        uint proposalDuration
    ) {
        PERMAPOOL = IPermapool(permapool);
        TOKEN = IERC20(PERMAPOOL.TOKEN());
        FEE_CLAIM_DELAY = feeClaimDelay;
        FEE_SEND_DELAY = feeSendDelay;
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

    // Claim fees from the LP position after a minimum delay
    function claimFees() external onlySquad {
        require(block.timestamp >= _lastFeeClaimTime + FEE_CLAIM_DELAY, "Minimum claim delay not observed");
        PERMAPOOL.collectFees();
        uint wethBalance = WETH.balanceOf(address(this));
        if (wethBalance > 0) {
            WETH.withdraw(wethBalance);
        }
        _lastFeeClaimTime = block.timestamp;
    }

    // Send fees to squad members after a minimum delay
    function sendFees() external onlySquad {
        require(block.timestamp >= _lastFeeClaimTime + FEE_SEND_DELAY, "Minimum send delay not observed");

        uint ethBalance = address(this).balance;
        uint tokenBalance = TOKEN.balanceOf(address(this));
        uint totalSquadWeight = _totalSquadWeight;
        address[] memory squadMembers = _squadMemberWeights.keys();
        for (uint i = 0; i < squadMembers.length; i++) {
            address member = squadMembers[i];
            uint weight = _squadMemberWeights.get(member);
            uint ethToSend = ethBalance * weight / totalSquadWeight;
            uint tokenToSend = tokenBalance * weight / totalSquadWeight;
            if (ethToSend > 0) {
                (bool transferred,) = member.call{value: ethToSend}("");
                require(transferred, "Transfer failed");
            }
            if (tokenToSend > 0) {
                require(TOKEN.transfer(member, tokenToSend), "Unable to transfer token");
            }
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

    function proposeGovernanceUpgrade(address target) external onlySquad {
        _proposals.push();
        uint proposalId = _proposals.length - 1;
        Proposal storage proposal = _proposals[proposalId];
        proposal.id = proposalId;
        proposal.target = target;
        proposal.governance = true;
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
            if (proposal.governance) {
                // Vote to upgrade permapool governance
                PERMAPOOL.upgradeGovernance(proposal.target);
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
}
