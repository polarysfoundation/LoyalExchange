// SPDX-License-Identifier: MIT 

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol"; // Consider AccessControl for finer-grained roles

// --- DAO Structure ---
struct Proposal {
    address targetWallet;
    uint256 amount;
    uint256 votesFor;
    uint256 votesAgainst;
    bool executed;
}

// --- Contract ---
contract ERC20Test is ERC20, ERC20Burnable, Pausable, Ownable {

    mapping(address => bool) public daoMembers;
    Proposal[] public proposals;

    // --- Constructor ---
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    // --- Admin Functions ---
    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }

    function pause() public onlyOwner {
        _pause();
    }

    function unpause() public onlyOwner {
        _unpause();
    }

    // --- DAO Functions ---
    function addDaoMember(address member) public onlyOwner {
        daoMembers[member] = true;
    }

    function createBurnProposal(address targetWallet, uint256 amount) public {
        require(daoMembers[msg.sender], "Not a DAO member");
        proposals.push(Proposal({
            targetWallet: targetWallet,
            amount: amount,
            votesFor: 0,
            votesAgainst: 0,
            executed: false
        }));
    }

    function voteOnProposal(uint256 proposalId, bool support) public {
        require(daoMembers[msg.sender], "Not a DAO member");
        Proposal storage proposal = proposals[proposalId];
        require(!proposal.executed, "Proposal already executed");

        if (support) {
            proposal.votesFor++;
        } else {
            proposal.votesAgainst++;
        }
    }
    function executeProposal(uint256 proposalId) public {
        // Logic to check if the proposal has sufficient votes
        Proposal storage proposal = proposals[proposalId];
        require(!proposal.executed, "Proposal already executed");

        // Add vote threshold check
        require(
            proposal.votesFor > proposal.votesAgainst,
            "Proposal does not have sufficient votes to pass"
        );

        proposal.executed = true;
        _burn(proposal.targetWallet, proposal.amount);
    }
}
