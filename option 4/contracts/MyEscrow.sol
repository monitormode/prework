// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract MyEscrow is AccessControl, ReentrancyGuard {
    //    :)
    address public goon;
    // 0.001 ether.   || 1 eth = 1e18
    uint256 speedUpProposal = 1e16; // fee

    //escrow and proposal counter
    using Counters for Counters.Counter;
    Counters.Counter private _escrowCounter;
    Counters.Counter private _proposalCounter;

    //instance roles
    bytes32 public constant ROLE_SENDER = keccak256("ROLE_SENDER");
    bytes32 public constant ROLE_PAUSER = keccak256("ROLE_PAUSER");

    //enum for resolving escrows
    enum EscrowBool {
        TIMELOCKED,
        UNLOCKED,
        IN_DISPUTE,
        TERMINATED
    }

    // Create an enum named Vote containing possible options for a vote
    enum Vote {
        YES, // YES = 0
        NO // NO = 1
    }

    //struct inicial
    struct Escrow {
        // wallets acting as unique senders for the escrow
        address[] senders;
        // wallets acting as unique receivers for the escrow
        address[] receivers;
        // totalshares, corresponding in number as receivers are
        // for 3 receivers: [50, 25, 25]   (total 100 shares, it's just basic mafhs)
        uint256[] totalShares;
        // keeping totalBalance acumulated
        uint256 balance;
        // UNIX future timestamp since created, acting as a marker for when timelock >= block.timestamp
        uint256 timelock;
        // Enum keeping state of the escrow
        EscrowBool locked;
    }

    //struct de Proposals
    struct Proposal {
        // escrow id;
        uint256 escrowId;
        // the UNIX timestamp until which this proposal is active.
        uint256 deadline;
        // number of YES votes for this proposal
        uint256 yesVotes;
        // number of NO votes for this proposal
        uint256 noVotes;
        // whether or not this proposal has been executed yet.
        bool executed;
        // a mapping of voters to booleans indicating is has been voted or not.
        mapping(address => bool) voters;
    }

    // arrrays.
    Escrow[] public escrowList;

    Proposal[] public proposals;

    // mappings.
    //
    // mapping containing all Proposals
    mapping(uint256 => bool) private isProposed;

    // for each address, first uint256 mapping represents the last mapping (to escrowID) relation.
    // and second uint256 is the individual accounting for each address for escrow.
    mapping(address => mapping(uint256 => uint256)) public _accountAccounting;

    // mapping for ban senders... if true the wallet is banned.
    mapping(address => bool) public permaWallets;

    //constructor
    constructor() {
        goon = msg.sender;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ROLE_SENDER, msg.sender);
        _grantRole(ROLE_PAUSER, msg.sender);
    }

    // modifiers
    //
    // check if caller is part of the escrow sender array
    modifier _isSender(uint256 _eId) {
        require(_isEscrowSender(_eId));
        _;
    }

    modifier _isFromAllSenders(address add) {
        require(_isSenderFromEscrowList(add));
        _;
    }

    // condition: wallet address is not banned
    modifier _isNotPerma() {
        require(permaWallets[msg.sender] == false);
        _;
    }

    // Create a modifier which only allows a function to be
    // called if the given proposal's deadline has not been exceeded yet
    modifier _activeProposalOnly(uint256 proposalIndex) {
        require(
            proposals[proposalIndex].deadline > block.timestamp,
            "DEADLINE_EXCEEDED"
        );
        _;
    }

    // Create a modifier which only allows a function to be
    // called if the given proposals' deadline HAS been exceeded
    // and if the proposal has not yet been executed
    modifier _inactiveProposalOnly(uint256 proposalIndex) {
        require(
            proposals[proposalIndex].deadline <= block.timestamp,
            "DEADLINE_NOT_EXCEEDED"
        );
        require(
            proposals[proposalIndex].executed == false,
            "PROPOSAL_ALREADY_EXECUTED"
        );
        _;
    }

    // events
    //
    //
    event EscrowCreated(
        uint256 id,
        address[] senders,
        address[] receivers,
        uint256[] totalShares,
        uint256 timelock,
        EscrowBool locked
    );

    event EscrowTerminated(uint256 id, EscrowBool terminated, uint256 timelock);

    event EscrowProposalInDispute(
        uint256 id,
        EscrowBool inDispute,
        uint256 deadline
    );

    event EscrowDeposit(uint256 eId, address depositor, uint256 value);

    event EscrowWithdraw(uint256 eId, uint256 totalBalance);

    event WalletPermaBan(address wall);

    event ProposalVoteOn(address sender, uint256 index, Vote vote);

    event ProposalVoteOnPickTheCopperProposal(
        address sender,
        uint256 index,
        Vote vote
    );

    event PickTheCoppersProposalCreated(
        uint256 index,
        EscrowBool inDisp,
        uint256 deadline
    );

    event PickTheCoppersProposalExecuted(bool exec, address addr);

    // contract functions
    //
    /// @dev creating a new escrow
    /// @param _senders is an array containing all allowed addresses that will contribute to the escrow.
    /// @param _receivers another array containing more addresses, this case the ones after the expiring
    /// escrow timelock  will receive the funds there.
    /// @param _totalShares an array with the payment splitment total. I.ej: "[50, 25, 25]"
    function createEscrow(
        address[] memory _senders,
        address[] memory _receivers,
        uint256[] memory _totalShares
    ) public _isNotPerma returns (uint256) {
        //instance an escrow
        Escrow memory _esc;

        //calling counter
        uint256 _count = _escrowCounter.current();

        // adding values to our new _esc
        _esc.senders = _senders;
        _esc.receivers = _receivers;
        _esc.totalShares = _totalShares;
        _esc.timelock = _setTimelock(); // this is arbitrary, could be better.
        _esc.locked = EscrowBool.TIMELOCKED; // def. value

        //push new escrow to the array
        escrowList.push(_esc);

        // grant ROLE_SENDER to all senders addresses
        for (uint256 i = 0; i < _senders.length; i++) {
            //grant ROLE_SENDER role for each one
            _grantRole(ROLE_SENDER, _senders[i]);
        }

        //emit event
        emit EscrowCreated(
            _count,
            _senders,
            _receivers,
            _totalShares,
            _esc.timelock,
            EscrowBool.TIMELOCKED
        );

        //para finalizar incrementamos el contador
        _escrowCounter.increment();

        //returns escrow id
        return _count;
    }

    /// @dev depositToEscrow - make a deposit
    /// @param _escrowId, value containing the exact id where to deposit
    /// this only will be executed if you're sender and not banned
    function depositToEscrow(uint256 _escrowId)
        public
        payable
        _isSender(_escrowId)
        _isNotPerma
    {
        //check if escrow is TIMELOCKED, so running.
        require(escrowList[_escrowId].locked == EscrowBool.TIMELOCKED);
        //aumentar balance global del escrow dentro del array
        escrowList[_escrowId].balance += msg.value;
        // update mapping value for the address caller
        _accountAccounting[msg.sender][_escrowId] += msg.value;

        //event
        emit EscrowDeposit(_escrowId, msg.sender, msg.value);
    }

    /// @dev hasVoted checks if address has voted already on a specific proposal.
    /// @param proposalIndex represents the proposalId.
    function hasVoted(uint256 proposalIndex) public view returns (bool) {
        return
            proposals[proposalIndex].voters[msg.sender] == true ||
            proposals[proposalIndex].voters[msg.sender] == false;
    }

    /// @dev _setTimelock is an internal autogenerated timelock
    /// just an arbitrary and easy method to return a future timestamp.
    function _setTimelock() internal view returns (uint256) {
        return block.timestamp + 4 hours;
    }

    /// @dev _isExpired checks is timelock has expired.
    /// If true changes EscrowBool to UNLOCKED
    /// @param _eId refers to escrow id.
    function _isExpired(uint256 _eId) internal returns (bool) {
        bool isOk = false;
        //if its expired, if not nothing happens
        if (escrowList[_eId].timelock <= block.timestamp) {
            isOk = true;
            escrowList[_eId].locked = EscrowBool.UNLOCKED;
        }
        return isOk;
    }

    // check enum functions
    //
    // check if locked
    function _isLocked(uint256 _eId) internal view returns (bool) {
        return escrowList[_eId].locked == EscrowBool.TIMELOCKED;
    }

    //check if unlocked
    function _isUnlocked(uint256 _eId) internal view returns (bool) {
        return escrowList[_eId].locked == EscrowBool.UNLOCKED;
    }

    //check if in dispute
    function _isInDispute(uint256 _eId) internal view returns (bool) {
        return escrowList[_eId].locked == EscrowBool.IN_DISPUTE;
    }

    //check if is terminated.
    function _isInTerminated(uint256 _eId) internal view returns (bool) {
        return escrowList[_eId].locked == EscrowBool.TERMINATED;
    }

    /// @dev _isEscrowSender checks if the sender is part of that Escrow list senders
    /// @param _eId represents the escrow id.
    function _isEscrowSender(uint256 _eId) internal view returns (bool) {
        bool isOk = false;
        for (uint256 i = 0; i < escrowList[_eId].senders.length; i++) {
            if (escrowList[_eId].senders[i] == msg.sender) {
                isOk = true;
            }
        }
        return isOk;
    }

    /// @dev _isSenderFromEscrowList checks if that address is sender from all escrowList escrows
    /// @param _sender refers to the address we want to check
    function _isSenderFromEscrowList(address _sender)
        internal
        view
        returns (bool)
    {
        bool isOk = false;
        for (uint256 i = 0; i < escrowList.length; i++) {
            for (uint256 j = 0; i < escrowList[i].senders.length; j++) {
                if (escrowList[i].senders[j] == _sender) {
                    isOk = true;
                }
            }
        }
        return isOk;
    }

    /// @dev _isEscrowReceiver checks if an address is receiver from any Escrow id
    /// @param _receiv is the address to check
    /// @param _eId represents the escrow id.
    function _isEscrowReceiver(address _receiv, uint256 _eId)
        internal
        view
        returns (bool)
    {
        // return escrowMapping[_receiv][_esc.id] == _esc;
        bool isOk = false;
        Escrow memory helper = escrowList[_eId];

        for (uint256 i = 0; i < helper.receivers.length; i++) {
            if (helper.receivers[i] == _receiv) {
                isOk = true;
            }
        }
        return isOk;
    }

    /// @dev withdrawEscrow has the modifier _isSender(_eId)
    /// only callable by senders [] included in that escrow id
    /// @param _eId represents the escrow id.
    function withdrawEscrow(uint256 _eId)
        public
        _isSender(_eId)
        nonReentrant
        returns (bool)
    {
        Escrow memory helper = escrowList[_eId];
        // check if escrow is unlocked and timestamp has expired
        require(
            _isExpired(_eId) && escrowList[_eId].locked == EscrowBool.UNLOCKED,
            "The escrow doen't have the conditions to be withdrawed."
        );

        require(escrowList[_eId].balance > 0, "This escrow is empty.");

        uint256 totalBalance = helper.balance;

        //for each receiver
        for (uint256 i = 0; i < helper.receivers.length; i++) {
            //get their address
            address payable to = payable(helper.receivers[i]);
            //send totalshares
            to.transfer(totalBalance / helper.totalShares[i]);
        }

        //update sender accounting
        for (uint256 i = 0; i < helper.senders.length; i++) {
            _accountAccounting[helper.senders[i]][_eId] = 0;
        }

        // //una vez hechas las transfer poner el contrato a 0 otra vez.
        // helper.balance = 0;

        //event
        emit EscrowWithdraw(_eId, totalBalance);
        return true;
    }

    /// @dev createTerminateEscrowproposal allows a sender of an escrow
    /// create a terminate escrow proposal
    /// @param _eId is the Escrow to be terminated
    function createTerminateEscrowproposal(uint256 _eId)
        public
        payable
        _isSender(_eId)
        _isNotPerma
        returns (uint256)
    {
        // to create an escrow cancel proposal you must pay 2% of total balance
        // that's life.
        require(msg.value >= twoPerCentOfBalanceEscrow(_eId));
        //require isProposed = false;  Only 1 proposal per ID
        require(!isProposed[_eId]);

        // we reserve proposalId = 0 to createPickTheCoppers() starting with proposalId = counter.current() + 1;
        uint256 numProposals = _proposalCounter.current() + 1;
        //instance of new proposal in the array.
        Proposal storage proposal = proposals[numProposals];
        //values
        proposal.escrowId = _eId;
        proposal.deadline = block.timestamp + 1 days;
        //increment counter
        _proposalCounter.increment();
        //add to mapping
        isProposed[_eId] = true;
        //change token status to in dispute
        escrowList[_eId].locked = EscrowBool.IN_DISPUTE;

        //event
        emit EscrowProposalInDispute(
            _eId,
            EscrowBool.IN_DISPUTE,
            proposal.deadline
        );
        //if all ok, return
        return numProposals;
    }

    /// @dev voteOnProposal allows a sender to cast their vote on an active proposal
    /// @param proposalIndex - the index of the proposal to vote on in the proposals array
    /// @param vote - the type of vote they want to cast
    function voteOnProposal(uint256 proposalIndex, Vote vote)
        public
        _isSender(proposalIndex)
        _activeProposalOnly(proposalIndex)
        _isNotPerma
    {
        // if hasn't voted yet
        require(!hasVoted(proposalIndex));

        Proposal storage proposal = proposals[proposalIndex];

        //suma los votos que ya llevan
        uint256 numVotes = proposal.noVotes + proposal.yesVotes;

        require(
            numVotes < escrowList[proposalIndex].senders.length,
            "Max votes reached. Votation is closed."
        );

        if (vote == Vote.YES) {
            // add vote result from msg.sender to proposal mapping
            proposals[proposalIndex].voters[msg.sender] = true;
            // add vote to yesVotes
            proposal.yesVotes += numVotes;
        } else {
            // add vote result from msg.sender to proposal mapping
            proposals[proposalIndex].voters[msg.sender] = false;
            proposal.noVotes += numVotes;
        }

        emit ProposalVoteOn(msg.sender, proposalIndex, vote);
    }

    /// @dev voteOnPickTheCoppersProposal allows a sender to cast their vote on an active proposal
    /// @param vote - the type of vote they want to cast
    function voteOnPickTheCoppersProposal(Vote vote)
        public
        _isFromAllSenders(msg.sender)
        _isNotPerma
    {
        uint256 proposalIndex = 0;
        // if hasn't voted yet
        require(!hasVoted(proposalIndex));

        Proposal storage proposal = proposals[proposalIndex];

        //suma los votos que ya llevan
        uint256 numVotes = proposal.noVotes + proposal.yesVotes;

        require(
            numVotes < escrowList[proposalIndex].senders.length,
            "Max votes reached. Votation is closed."
        );

        if (vote == Vote.YES) {
            // add vote result from msg.sender to proposal mapping
            proposals[proposalIndex].voters[msg.sender] = true;
            // add vote to yesVotes
            proposal.yesVotes += numVotes;
        } else {
            // add vote result from msg.sender to proposal mapping
            proposals[proposalIndex].voters[msg.sender] = false;
            proposal.noVotes += numVotes;
        }

        emit ProposalVoteOnPickTheCopperProposal(
            msg.sender,
            proposalIndex,
            vote
        );
    }

    /// @dev speedUpInactiveProposal: any of the senders want to speed up the deadline...
    /// @param _prop refers to the proposalIndex.
    function speedUpInactiveProposalDeadline(uint256 _prop)
        public
        payable
        _isSender(_prop)
        _activeProposalOnly(_prop)
    {
        //require pay fee
        require(msg.value >= speedUpProposal);
        //change deadline just 1 before timestamp. what else?
        proposals[_prop].deadline = block.timestamp - 1;
    }

    /// @dev speedUpEscrowTimelock: FOR TESTING PURPOSES, ONLY ROLE_PAUSER!
    /// with no fees ^^
    /// @param _prop refers to the proposalIndex.
    function speedUpEscrowTimelock(uint256 _prop)
        public
        onlyRole(ROLE_PAUSER)
        _activeProposalOnly(_prop)
    {
        // //require pay fee
        // require(msg.value >= speedUpProposal);
        //change deadline just 1 before timestamp. what else?
        escrowList[_prop].timelock = block.timestamp - 1;
    }

    /// @dev executePickTheCoppersProposal allows
    function executePickTheCoppersProposal(address payable _addr)
        public
        onlyRole(ROLE_SENDER)
    {
        Proposal storage proposal = proposals[0];

        if (proposal.yesVotes > proposal.noVotes) {
            //exec = true
            proposal.executed = true;
            //set escrowList locked to .TERMINATED if voting is OK
            escrowList[0].locked = EscrowBool.TERMINATED;
            //after changing enum state we can claim the tokens
            pickTheCoppers(_addr);
        }
    }

    /// @dev executeCancelProposal allows any CryptoDevsNFT holder to execute a proposal after it's deadline has been exceeded
    /// @param _proposalIndex - the index of the proposal to execute in the proposals array
    /// @dev _isNotPerma()
    function executeCancelProposal(uint256 _proposalIndex)
        public
        _inactiveProposalOnly(_proposalIndex)
        _isNotPerma
    {
        Proposal storage proposal = proposals[_proposalIndex];

        if (proposal.yesVotes > proposal.noVotes) {
            //exec before check votation results
            proposal.executed = true;

            //pasar el escrow a terminated.
            escrowList[_proposalIndex].locked = EscrowBool.TERMINATED;
            //devolver lo que ha aportado cada uno, madremía vaya follón
            _withdrawToSenders(_proposalIndex);
        } else {
            //pasar el escrow a terminated.
            escrowList[_proposalIndex].locked = EscrowBool.TERMINATED;
        }

        emit EscrowTerminated(
            _proposalIndex,
            EscrowBool.TERMINATED,
            proposals[_proposalIndex].deadline
        );
    }

    /// @dev _withdrawToSenders as the modifier _isSender(_eId)
    /// only callable by senders [] included in that escrow id
    /// @param _eId represent the escrowId pointer.
    function _withdrawToSenders(uint256 _eId)
        internal
        _isSender(_eId)
        nonReentrant
        returns (bool)
    {
        // required the proposal had being passed.
        require(
            proposals[_eId].executed == true &&
                escrowList[_eId].locked == EscrowBool.TERMINATED
        );

        Escrow memory helper = escrowList[_eId];
        // check if escrow is unlocked and timestamp has expired
        require(
            _isExpired(_eId) && helper.locked == EscrowBool.UNLOCKED,
            "The escrow doen't have the conditions to be withdrawed."
        );

        require(helper.balance > 0, "This escrow is empty.");

        uint256 totalBalance = helper.balance;

        //for each sender
        for (uint256 i = 0; i < helper.senders.length; i++) {
            //get their address
            address payable to = payable(helper.senders[i]);
            //send their shares
            to.transfer(_accountAccounting[helper.senders[i]][_eId]);

            //update mapping. ??
            // escrowMapping[to][_eId].balance = 0;
        }

        // //una vez hechas las transfer poner el contrato a 0 otra vez.  ??
        // helper.balance = 0;

        //event
        emit EscrowWithdraw(_eId, totalBalance);
        return true;
    }

    /// @dev twoPerCentOfBalanceEscrow is the Pujol function.
    /// keeps a 2% of the escrow total, for cancelling purposes.
    /// @param _eId represent the escrowId pointer.
    function twoPerCentOfBalanceEscrow(uint256 _eId)
        internal
        view
        returns (uint256)
    {
        return (escrowList[_eId].balance / 100) * 2;
    }

    /// @dev totalEscrows returns an uint256 reading escrowList length
    function totalEscrows() public view returns (uint256) {
        return escrowList.length;
    }

    // ROLE_PAUSER functions
    //
    /// @dev setEscrowBool, ROLE_PAUSER is able to assing a new EscrowBool to the Escrow
    /// @param _eId represents the Escrow id
    /// @param _newBool inserted as uint8, the enum start at 0 for first element, 1 for 2nd...
    function setEscrowBool(uint256 _eId, EscrowBool _newBool)
        public
        onlyRole(ROLE_PAUSER)
    {
        escrowList[_eId].locked = _newBool;
    }

    /// @dev revokeSenderRole, ROLE_PAUSER is able to revoke ROLE_SENDER to any address
    /// @param _revoke is the address to be revoked.
    function revokeSenderRole(address _revoke) public onlyRole(ROLE_PAUSER) {
        revokeRole(ROLE_SENDER, _revoke);
        //emit event
        emit RoleRevoked(ROLE_SENDER, _revoke, goon);
    }

    /// @dev banWallet, ROLE_PAUSER can blacklist addresses.
    /// @param _wallet is the address to be blacklisted.
    function banWallet(address _wallet) public onlyRole(ROLE_PAUSER) {
        permaWallets[_wallet] = true;
        emit WalletPermaBan(_wallet);
    }

    /// @dev isRoleSender FOR TESTING PURPOSES
    /// @param sender represent the address to check
    function isRoleSender(address sender) public view returns (bool) {
        return hasRole(ROLE_SENDER, sender);
    }

    /// @dev pickTheCoopers is a function supposed to exec after all escrow withdraws are executed
    /// and all shares are with their receivers. This is thought in case there's any Eth remaining.
    /// This is only callable by the ROLE_PAUSER in this case only the owner
    /// @param _to address receiver
    function pickTheCoppers(address payable _to)
        public
        payable
        onlyRole(ROLE_PAUSER)
    {
        //require check if proposals[0].executed == true means that this proposal has to be passed
        // before executing this
        require(proposals[0].executed == true);
        // Call returns a boolean value indicating success or failure.
        // This is the current recommended method to use.
        (bool sent, bytes memory data) = _to.call{value: address(this).balance}(
            ""
        );
        require(sent, "Failed to send Ether");
    }

    function createPickTheCoppersProposal() public onlyRole(ROLE_PAUSER) {
        // check first if all escrows have Escrowbool.TERMINATED enum
        require(_areTerminated());
        // continues..
        uint256 coppersIndex = 0;
        //instance of new proposal in the array.
        Proposal storage proposal = proposals[coppersIndex];
        //values
        proposal.escrowId = coppersIndex;
        proposal.deadline = block.timestamp + 1 days;

        //set escrowList locked to .IN_DISPUTE
        escrowList[coppersIndex].locked = EscrowBool.IN_DISPUTE;

        //add to mapping
        isProposed[coppersIndex] = true;

        //adding all senders to the proposal and allow them to vote, if not escrowList[0].senders
        //would be empty per se.
        _addAllSendersToProposal(coppersIndex);

        //event
        emit PickTheCoppersProposalCreated(
            0,
            EscrowBool.IN_DISPUTE,
            proposal.deadline
        );
        //if all ok, return
    }

    function _addAllSendersToProposal(uint256 _prop) internal {
        for (uint256 i = 1; i < escrowList.length; i++) {
            for (uint256 j = 0; i < escrowList[i].senders.length; j++) {
                // if(escrowList[i].senders[j] == _sender){
                //     isOk = true;
                // }
                escrowList[_prop].senders[i + j] = escrowList[i].senders[j];
            }
        }
    }

    /// @dev _areExecuted is a function acting as a modifier that checks if all escrows are executed
    /// before calling pickTheCoopers.
    function _areTerminated() internal view returns (bool) {
        uint256 counter;
        for (uint256 i = 0; i < escrowList.length; i++) {
            if (escrowList[i].locked == EscrowBool.TERMINATED) {
                counter++;
            }
        }

        return counter == escrowList.length;
    }

    // Function to receive Ether. msg.data must be empty
    receive() external payable {}

    // Fallback function is called when msg.data is not empty
    fallback() external payable {}
}
