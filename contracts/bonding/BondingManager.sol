pragma solidity ^0.4.13;

import "./IBondingManager.sol";
import "./libraries/TranscoderPools.sol";
import "../Manager.sol";
import "../ContractRegistry.sol";
import "../LivepeerToken.sol";
import "../rounds/IRoundsManager.sol";
import "../jobs/IJobsManager.sol";

import "zeppelin-solidity/contracts/math/SafeMath.sol";

contract BondingManager is IBondingManager, Manager {
    using SafeMath for uint256;
    using TranscoderPools for TranscoderPools.TranscoderPools;

    // Token address
    LivepeerToken public token;

    // Start with 10M tokens. 1 LPT == 10^18th units
    uint256 public initialTokenSupply = 10000000 * (10 ** 18);

    // Upper bound inflation rate
    // Initially fixed at 26%
    uint8 public initialYearlyInflation = 26;

    // Time between unbonding and possible withdrawl in rounds
    uint64 public unbondingPeriod;

    // Represents a transcoder's current state
    struct Transcoder {
        uint256 delegatorWithdrawRound;                      // The round at which delegators to this transcoder can withdraw if this transcoder resigns
        uint256 lastRewardRound;                             // Last round that the transcoder called reward
        uint8 blockRewardCut;                                // % of block reward cut paid to transcoder by a delegator
        uint8 feeShare;                                      // % of fees paid to delegators by transcoder
        uint256 pricePerSegment;                             // Price per segment (denominated in LPT units) for a stream
        uint8 pendingBlockRewardCut;                         // Pending block reward cut for next round if the transcoder is active
        uint8 pendingFeeShare;                               // Pending fee share for next round if the transcoder is active
        uint256 pendingPricePerSegment;                      // Pending price per segment for next round if the transcoder is active
        mapping (uint256 => TokenPools) tokenPoolsPerRound;  // Mapping of round => token pools for the round
    }

    // The various states a transcoder can be in
    enum TranscoderStatus { NotRegistered, Registered, Resigned }

    // Represents rewards and fees to be distributed to delegators
    struct TokenPools {
        RewardPool rewardPool;
        ClaimFees[] feePool;
    }

    // Represents rewards to be distributed to delegators
    struct RewardPool {
        uint256 rewards;
        uint256 transcoderTotalStake;
    }

    // Represents fees to be distributed to delegators
    struct ClaimFees {
        uint256 claimBlock;
        uint256 fees;
        uint256 transcoderTotalStake;
    }

    // Represents a delegator's current state
    struct Delegator {
        uint256 bondedAmount;              // The amount of bonded tokens
        address delegateAddress;           // The address delegated to
        uint256 delegatedAmount;           // The amount of tokens delegated to the delegator
        uint256 startRound;                // The round the delegator transitions to bonded phase
        uint256 delegateBlock;             // The block the delegator bonds to somone
        uint256 withdrawRound;             // The round at which a delegator can withdraw
        uint256 lastStakeUpdateRound;      // The last round the delegator transitioned states
    }

    // The various states a delegator can be in
    enum DelegatorStatus { Pending, Bonded, Unbonding, Unbonded }

    // Keep track of the known transcoders and delegators
    // Note: Casper style implementation would have us using arrays and bitmaps to index these
    mapping (address => Delegator) public delegators;
    mapping (address => Transcoder) public transcoders;

    // Active and candidate transcoder pools
    TranscoderPools.TranscoderPools transcoderPools;

    // Current active transcoders for current round
    Node.Node[] activeTranscoders;
    // Mapping to track which addresses are in the current active transcoder set
    mapping (address => bool) public isActiveTranscoder;
    // Mapping to track the index position of an address in the current active transcoder set
    mapping (address => uint256) public activeTranscoderPositions;
    // Total stake of all active transcoders
    uint256 public totalActiveTranscoderStake;

    // Only the RoundsManager can call
    modifier onlyRoundsManager() {
        require(msg.sender == address(roundsManager()));
        _;
    }

    // Only the JobsManager can call
    modifier onlyJobsManager() {
        require(msg.sender == address(jobsManager()));
        _;
    }

    // Check if current round is initialized
    modifier currentRoundInitialized() {
        require(roundsManager().currentRoundInitialized());
        _;
    }

    // Update delegator stake with rewards and fees from past rounds
    modifier updateDelegatorStakeWithRewardsAndFees() {
        Delegator storage del = delegators[msg.sender];

        if (delegatorStatus(msg.sender) == DelegatorStatus.Bonded && transcoderStatus(del.delegateAddress) == TranscoderStatus.Registered) {
            uint256 rewardsAndFees = delegatorTokenPoolsShare(del);
            del.bondedAmount = del.bondedAmount.add(rewardsAndFees);
            delegators[del.delegateAddress].delegatedAmount = delegators[del.delegateAddress].delegatedAmount.add(rewardsAndFees);
        }

        del.lastStakeUpdateRound = roundsManager().currentRound();

        _;
    }

    /*
     * @dev BondingManager constructor. Sets a pre-existing address for the LivepeerToken contract
     * @param _token LivepeerToken contract address
     */
    function BondingManager(
        address _registry,
        address _token,
        uint256 _numActiveTranscoders,
        uint64 _unbondingPeriod
    )
        Manager(_registry)
    {
        // Set LivepeerToken address
        token = LivepeerToken(_token);
        // Set unbonding period
        unbondingPeriod = _unbondingPeriod;
        // Set up transcoder pools
        transcoderPools.init(_numActiveTranscoders, _numActiveTranscoders);
    }

    /*
     * @dev The sender is declaring themselves as a candidate for active transcoding.
     * @param _blockRewardCut % of block reward paid to transcoder by a delegator
     * @param _feeShare % of fees paid to delegators by a transcoder
     * @param _pricePerSegment Price per segment (denominated in LPT units) for a stream
     */
    function transcoder(uint8 _blockRewardCut, uint8 _feeShare, uint256 _pricePerSegment)
        external
        whenSystemNotPaused
        currentRoundInitialized
        returns (bool)
    {
        // Block reward cut must a valid percentage
        require(_blockRewardCut <= 100);
        // Fee share must be a valid percentage
        require(_feeShare <= 100);
        // Sender must not be a resigned transcoder
        require(transcoderStatus(msg.sender) != TranscoderStatus.Resigned);

        Transcoder storage t = transcoders[msg.sender];
        t.pendingBlockRewardCut = _blockRewardCut;
        t.pendingFeeShare = _feeShare;
        t.pendingPricePerSegment = _pricePerSegment;

        if (transcoderStatus(msg.sender) == TranscoderStatus.NotRegistered) {
            t.delegatorWithdrawRound = 0;

            transcoderPools.addTranscoder(msg.sender, delegators[msg.sender].delegatedAmount);
        }

        return true;
    }

    /*
     * @dev Remove the sender as a transcoder
     */
    function resignAsTranscoder() external whenSystemNotPaused currentRoundInitialized returns (bool) {
        // Sender must be registered transcoder
        require(transcoderStatus(msg.sender) == TranscoderStatus.Registered);
        // Remove transcoder from pools
        transcoderPools.removeTranscoder(msg.sender);
        // Set delegator withdraw round
        transcoders[msg.sender].delegatorWithdrawRound = roundsManager().currentRound().add(unbondingPeriod);

        return true;
    }

    /**
     * @dev Delegate stake towards a specific address.
     * @param _amount The amount of LPT to stake.
     * @param _to The address of the transcoder to stake towards.
     */
    function bond(
        uint256 _amount,
        address _to
    )
        external
        whenSystemNotPaused
        currentRoundInitialized
        updateDelegatorStakeWithRewardsAndFees
        returns (bool)
    {
        Delegator storage del = delegators[msg.sender];

        if (delegatorStatus(msg.sender) == DelegatorStatus.Unbonded) {
            // New delegate
            // Set start round
            del.startRound = roundsManager().currentRound().add(1);
            // Set delegate block
            del.delegateBlock = block.number;
        }

        // Amount to delegate
        uint256 delegationAmount = _amount;

        if (del.delegateAddress != address(0) && _to != del.delegateAddress) {
            // Changing delegate
            // Set start round
            del.startRound = roundsManager().currentRound().add(1);
            // Set delegate block
            del.delegateBlock = block.number;
            // Update amount to delegate with previous delegation amount
            delegationAmount = delegationAmount.add(del.bondedAmount);
            // Decrease old delegate's delegated amount
            delegators[del.delegateAddress].delegatedAmount = delegators[del.delegateAddress].delegatedAmount.sub(del.bondedAmount);

            if (transcoderStatus(del.delegateAddress) == TranscoderStatus.Registered) {
                // Previously delegated to a transcoder
                // Decrease old transcoder's total stake
                transcoderPools.decreaseTranscoderStake(del.delegateAddress, del.bondedAmount);
            }
        }

        del.delegateAddress = _to;
        del.bondedAmount = del.bondedAmount.add(_amount);

        // Update current delegate's delegated amount with delegation amount
        delegators[_to].delegatedAmount = delegators[_to].delegatedAmount.add(delegationAmount);

        if (transcoderStatus(_to) == TranscoderStatus.Registered) {
            // Delegated to a transcoder
            // Increase transcoder's total stake
            transcoderPools.increaseTranscoderStake(_to, delegationAmount);
        }

        if (_amount > 0) {
            // Only transfer tokens if _amount is greater than 0
            // Transfer the token. This call throws if it fails.
            token.transferFrom(msg.sender, this, _amount);
        }

        return true;
    }

    /*
     * @dev Unbond delegator's current stake. Delegator enters unbonding state
     * @param _amount Amount of tokens to unbond
     */
    function unbond()
        external
        whenSystemNotPaused
        currentRoundInitialized
        updateDelegatorStakeWithRewardsAndFees
        returns (bool)
    {
        // Sender must be in bonded state
        require(delegatorStatus(msg.sender) == DelegatorStatus.Bonded);

        Delegator storage del = delegators[msg.sender];

        // Transition to unbonding phase
        del.withdrawRound = roundsManager().currentRound().add(unbondingPeriod);
        // Decrease delegate's delegated amount
        delegators[del.delegateAddress].delegatedAmount = delegators[del.delegateAddress].delegatedAmount.sub(del.bondedAmount);

        if (transcoderStatus(del.delegateAddress) == TranscoderStatus.Registered) {
            // Previously delegated to a transcoder
            // Decrease old transcoder's total stake
            transcoderPools.decreaseTranscoderStake(del.delegateAddress, del.bondedAmount);
        }

        // Delegator no longer bonded to anyone
        del.delegateAddress = address(0);

        return true;
    }

    /**
     * @dev Withdraws withdrawable funds back to the caller after unbonding period.
     */
    function withdraw() external whenSystemNotPaused currentRoundInitialized returns (bool) {
        // Delegator must be unbonded
        require(delegatorStatus(msg.sender) == DelegatorStatus.Unbonded);

        token.transfer(msg.sender, delegators[msg.sender].bondedAmount);

        delete delegators[msg.sender];

        return true;
    }

    /*
     * @dev Set active transcoder set for the current round
     */
    function setActiveTranscoders() external whenSystemNotPaused onlyRoundsManager returns (bool) {
        if (activeTranscoders.length != transcoderPools.candidateTranscoders.nodes.length) {
            // Set length of array if it has not already been set
            activeTranscoders.length = transcoderPools.candidateTranscoders.nodes.length;
        }

        uint256 stake = 0;

        for (uint256 i = 0; i < transcoderPools.candidateTranscoders.nodes.length; i++) {
            if (activeTranscoders[i].initialized) {
                // Set address of old node to not be present in active transcoder set
                isActiveTranscoder[activeTranscoders[i].id] = false;
            }

            // Copy node
            activeTranscoders[i] = transcoderPools.candidateTranscoders.nodes[i];

            address activeTranscoder = activeTranscoders[i].id;

            // Set address of node to be present in active transcoder set
            isActiveTranscoder[activeTranscoder] = true;
            // Set index position of node in active transcoder set
            activeTranscoderPositions[activeTranscoder] = i;
            // Set pending rates as current rates
            transcoders[activeTranscoder].blockRewardCut = transcoders[activeTranscoder].pendingBlockRewardCut;
            transcoders[activeTranscoder].feeShare = transcoders[activeTranscoder].pendingFeeShare;
            transcoders[activeTranscoder].pricePerSegment = transcoders[activeTranscoder].pendingPricePerSegment;

            stake = stake.add(transcoderTotalStake(activeTranscoder));
        }

        // Update total stake of all active transcoders
        totalActiveTranscoderStake = stake;

        return true;
    }

    /*
     * @dev Distribute the token rewards to transcoder and delegates.
     * Active transcoders call this once per cycle when it is their turn.
     */
    function reward() external whenSystemNotPaused currentRoundInitialized returns (bool) {
        // Sender must be an active transcoder
        require(isActiveTranscoder[msg.sender]);

        uint256 currentRound = roundsManager().currentRound();

        // Transcoder must not have called reward for this round already
        require(transcoders[msg.sender].lastRewardRound != currentRound);
        // Set last round that transcoder called reward
        transcoders[msg.sender].lastRewardRound = currentRound;

        // Calculate number of tokens to mint
        uint256 mintedTokens = mintedTokensPerReward(msg.sender);
        // Mint token reward and allocate to this protocol contract
        token.mint(this, mintedTokens);

        updateTranscoderWithRewards(msg.sender, mintedTokens, currentRound);

        return true;
    }

    /*
     * @dev Update transcoder's fee pool
     * @param _transcoder Transcoder address
     * @param _fees Fees from verified job claims
     */
    function updateTranscoderFeePool(
        address _transcoder,
        uint256 _fees,
        uint256 _claimBlock,
        uint256 _transcoderTotalStake
    )
        external
        whenSystemNotPaused
        onlyJobsManager
        returns (bool)
    {
        // Transcoder must be registered
        require(transcoderStatus(_transcoder) == TranscoderStatus.Registered);

        updateTranscoderWithFees(_transcoder, _fees, roundsManager().currentRound(), _claimBlock, _transcoderTotalStake);

        return true;
    }

    /*
     * @dev Slash a transcoder. Slashing can be invoked by the protocol or a finder.
     * @param _transcoder Transcoder address
     * @param _finder Finder that proved a transcoder violated a slashing condition. Null address if there is no finder
     * @param _slashAmount Percentage of transcoder bond to be slashed
     * @param _finderFee Percentage of penalty awarded to finder. Zero if there is no finder
     */
    function slashTranscoder(
        address _transcoder,
        address _finder,
        uint64 _slashAmount,
        uint64 _finderFee
    )
        external
        whenSystemNotPaused
        onlyJobsManager
        returns (bool)
    {
        // Transcoder must be valid
        require(transcoderStatus(_transcoder) == TranscoderStatus.Registered);

        uint256 penalty = delegators[_transcoder].bondedAmount.mul(_slashAmount).div(100);

        decreaseTranscoderStake(_transcoder, penalty);

        // Set withdraw round for delegators
        transcoders[msg.sender].delegatorWithdrawRound = roundsManager().currentRound().add(unbondingPeriod);

        // Remove transcoder from pools
        transcoderPools.removeTranscoder(_transcoder);

        if (_finder != address(0)) {
            // Award finder fee
            token.transfer(_finder, penalty.mul(_finderFee).div(100));
        }

        return true;
    }

    /*
     * @dev Pseudorandomly elect a currently active transcoder that charges a price per segment less than or equal to the max price per segment for a job
     * Returns address of elected active transcoder and its price per segment
     * @param _maxPricePerSegment Max price (in LPT base units) per segment of a stream
     */
    function electActiveTranscoder(uint256 _maxPricePerSegment) external constant returns (address, uint256) {
        // Create array to store available transcoders charging an acceptable price per segment
        Node.Node[] memory availableTranscoders = new Node.Node[](activeTranscoders.length);
        // Keep track of the actual number of available transcoders
        uint256 numAvailableTranscoders = 0;
        // Keep track of total stake of available transcoders
        uint256 totalAvailableTranscoderStake = 0;

        for (uint256 i = 0; i < activeTranscoders.length; i++) {
            // If a transcoders charges an acceptable price per segment add it to the array of available transcoders
            if (transcoders[activeTranscoders[i].id].pricePerSegment <= _maxPricePerSegment) {
                availableTranscoders[numAvailableTranscoders] = activeTranscoders[i];
                numAvailableTranscoders++;
                totalAvailableTranscoderStake = totalAvailableTranscoderStake.add(activeTranscoders[i].key);
            }
        }

        if (numAvailableTranscoders == 0) {
            // There is no currently available transcoder that charges a price per segment less than or equal to the max price per segment for a job
            return (address(0), 0);
        } else {
            // Pseudorandomly pick an available transcoder weighted by its stake relative to the total stake of all available transcoders
            uint256 r = uint256(block.blockhash(block.number - 1)) % totalAvailableTranscoderStake;
            uint256 s = 0;

            for (uint256 j = 0; j < numAvailableTranscoders; j++) {
                s = s.add(availableTranscoders[j].key);

                if (s > r) {
                    return (availableTranscoders[j].id, transcoders[availableTranscoders[j].id].pricePerSegment);
                }
            }

            return (availableTranscoders[numAvailableTranscoders - 1].id, transcoders[availableTranscoders[numAvailableTranscoders - 1].id].pricePerSegment);
        }

        return (address(0), 0);
    }

    /*
     * @dev Returns bonded stake for a delegator. Accounts for token distribution since last state transition
     * @param _delegator Address of delegator
     */
    function delegatorStake(address _delegator) public constant returns (uint256) {
        Delegator storage del = delegators[_delegator];

        if (delegatorStatus(_delegator) == DelegatorStatus.Bonded && transcoderStatus(del.delegateAddress) == TranscoderStatus.Registered) {
            return del.bondedAmount.add(delegatorTokenPoolsShare(del));
        } else {
            return del.bondedAmount;
        }
    }

    /*
     * @dev Returns total bonded stake for an active transcoder
     * @param _transcoder Address of a transcoder
     */
    function activeTranscoderTotalStake(address _transcoder) public constant returns (uint256) {
        // Must be active transcoder
        require(isActiveTranscoder[_transcoder]);

        return activeTranscoders[activeTranscoderPositions[_transcoder]].key;
    }

    /*
     * @dev Returns total bonded stake for a transcoder
     * @param _transcoder Address of transcoder
     */
    function transcoderTotalStake(address _transcoder) public constant returns (uint256) {
        return transcoderPools.transcoderStake(_transcoder);
    }

    /*
     * @dev Computes transcoder status
     * @param _transcoder Address of transcoder
     */
    function transcoderStatus(address _transcoder) public constant returns (TranscoderStatus) {
        Transcoder storage t = transcoders[_transcoder];

        if (t.delegatorWithdrawRound > 0) {
            if (roundsManager().currentRound() >= t.delegatorWithdrawRound) {
                return TranscoderStatus.NotRegistered;
            } else {
                return TranscoderStatus.Resigned;
            }
        } else if (transcoderPools.isInPools(_transcoder)) {
            return TranscoderStatus.Registered;
        } else {
            return TranscoderStatus.NotRegistered;
        }
    }

    /*
     * @dev Computes delegator status
     * @param _delegator Address of delegator
     */
    function delegatorStatus(address _delegator) public constant returns (DelegatorStatus) {
        Delegator storage del = delegators[_delegator];

        if (del.withdrawRound > 0) {
            // Delegator called unbond
            if (roundsManager().currentRound() >= del.withdrawRound) {
                return DelegatorStatus.Unbonded;
            } else {
                return DelegatorStatus.Unbonding;
            }
        } else if (transcoderStatus(del.delegateAddress) == TranscoderStatus.NotRegistered && transcoders[del.delegateAddress].delegatorWithdrawRound > 0) {
            // Transcoder resigned
            if (roundsManager().currentRound() >= transcoders[del.delegateAddress].delegatorWithdrawRound) {
                return DelegatorStatus.Unbonded;
            } else {
                return DelegatorStatus.Unbonding;
            }
        } else if (del.startRound > roundsManager().currentRound()) {
            // Delegator round start is in the future
            return DelegatorStatus.Pending;
        } else if (del.startRound > 0 && del.startRound <= roundsManager().currentRound()) {
            // Delegator round start is now or in the past
            return DelegatorStatus.Bonded;
        } else {
            // Default to unbonded
            return DelegatorStatus.Unbonded;
        }
    }

    /*
     * @dev Return number of minted tokens for a reward call
     */
    function mintedTokensPerReward(address _transcoder) public constant returns (uint256) {
        uint256 transcoderActiveStake = activeTranscoders[activeTranscoderPositions[_transcoder]].key;
        return initialTokenSupply.mul(initialYearlyInflation).div(100).div(roundsManager().roundsPerYear()).mul(transcoderActiveStake).div(totalActiveTranscoderStake);
    }

    /*
     * @dev Return current size of candidate transcoder pool
     */
    function getCandidatePoolSize() public constant returns (uint256) {
        return transcoderPools.getCandidatePoolSize();
    }

    /*
     * @dev Return current size of reserve transcoder pool
     */
    function getReservePoolSize() public constant returns (uint256) {
        return transcoderPools.getReservePoolSize();
    }

    /*
     * @dev Return candidate transcoder at position in candidate pool
     * @param _position Position in candidate pool
     */
    function getCandidateTranscoderAtPosition(uint256 _position) public constant returns (address) {
        return transcoderPools.getCandidateTranscoderAtPosition(_position);
    }

    /*
     * @dev Return reserve transcoder at postiion in reserve pool
     * @param _position Position in reserve pool
     */
    function getReserveTranscoderAtPosition(uint256 _position) public constant returns (address) {
        return transcoderPools.getReserveTranscoderAtPosition(_position);
    }

    /*
     * @dev Increase a transcoder's stake as a delegator and its total stake in the transcoder pools
     * @param _transcoder Address of transcoder
     * @param _totalAmount Total amount to increase transcoder's total stake
     * @param _transcoderShare Transcoder's share of the total amount
     * @param _round Round that transcoder's stake is increased
     */
    function increaseTranscoderStake(address _transcoder, uint256 _totalAmount, uint256 _transcoderShare, uint256 _round) internal returns (bool) {
        delegators[_transcoder].bondedAmount = delegators[_transcoder].bondedAmount.add(_transcoderShare);

        if (delegatorStatus(_transcoder) == DelegatorStatus.Unbonded) {
            // Set delegator fields if transcoder is not a bonded delegator
            delegators[_transcoder].delegateAddress = _transcoder;
            delegators[_transcoder].startRound = _round;
            delegators[_transcoder].delegateBlock = block.number;
            delegators[_transcoder].withdrawRound = 0;
            delegators[_transcoder].lastStakeUpdateRound = _round;
        }

        transcoderPools.increaseTranscoderStake(_transcoder, _totalAmount);

        return true;
    }

    /*
     * @dev Decrease a transcoder's stake as a delegator and its total stake in the transcoder pools
     * @param _transcoder Address of transcoder
     * @param _totalAmount Total amount to decrease transcoder's total stake
     */
    function decreaseTranscoderStake(address _transcoder, uint256 _totalAmount) internal returns (bool) {
        Delegator storage del = delegators[_transcoder];

        if (_totalAmount > del.bondedAmount) {
            // Decrease transcoder's total stake by transcoder's stake
            transcoderPools.decreaseTranscoderStake(_transcoder, del.bondedAmount);
            // Set transcoder's bond to 0 since
            // the penalty is greater than its stake
            del.bondedAmount = 0;
        } else {
            // Decrease transcoder's total stake by the penalty
            transcoderPools.decreaseTranscoderStake(_transcoder, _totalAmount);
            // Decrease transcoder's stake
            del.bondedAmount = del.bondedAmount.sub(_totalAmount);
        }

        return true;
    }

    /*
     * @dev Update a transcoder with rewards
     * @param _transcoder Address of transcoder
     * @param _rewards Amount of rewards
     * @param _round Round that transcoder is updated
     */
    function updateTranscoderWithRewards(address _transcoder, uint256 _rewards, uint256 _round) internal returns (bool) {
        uint256 transcoderRewardShare = _rewards.mul(transcoders[_transcoder].blockRewardCut).div(100);

        // Update transcoder's reward pool for the round
        RewardPool storage rewardPool = transcoders[_transcoder].tokenPoolsPerRound[_round].rewardPool;
        rewardPool.rewards = rewardPool.rewards.add(_rewards.sub(transcoderRewardShare));

        if (rewardPool.transcoderTotalStake == 0) {
            rewardPool.transcoderTotalStake = transcoderTotalStake(_transcoder);
        }

        increaseTranscoderStake(_transcoder, _rewards, transcoderRewardShare, _round);

        return true;
    }

    /*
     * @dev Update a transcoder with fees
     * @param _transcoder Address of transcoder
     * @param _fees Amount of fees
     * @param _round Round that transcoder is updated
     * @param _claimBlock Block of the claim that fees are associated with
     * @param _transcoderTotalStake Transcoder's total stake at the claim block
     */
    function updateTranscoderWithFees(address _transcoder, uint256 _fees, uint256 _round, uint256 _claimBlock, uint256 _transcoderTotalStake) internal returns (bool) {
        uint256 delegatorsFeeShare = _fees.mul(transcoders[_transcoder].feeShare).div(100);

        // Update transcoder's fee pool for the round
        transcoders[_transcoder].tokenPoolsPerRound[_round].feePool.push(ClaimFees({
            claimBlock: _claimBlock,
            fees: delegatorsFeeShare,
            transcoderTotalStake: _transcoderTotalStake
        }));

        increaseTranscoderStake(_transcoder, _fees, _fees.sub(delegatorsFeeShare), _round);

        return true;
    }

     /*
     * @dev Computes token distribution for delegator since its last state transition
     * @param _delegator Address of delegator
     */
    function delegatorTokenPoolsShare(Delegator storage del) internal constant returns (uint256) {
        uint256 tokens = 0;
        // Iterate from round that delegator last transitioned states to current round
        // If the delegator is bonded to a transcoder, it has been bonded to the transcoder since lastStakeUpdateRound
        for (uint256 i = del.lastStakeUpdateRound; i <= roundsManager().currentRound(); i++) {
            tokens = tokens.add(delegatorRewardPoolShare(del, i)).add(delegatorFeePoolShare(del, i));
        }

        return tokens;
    }

    /*
     * @dev Computes delegator's share of reward pool for a round
     */
    function delegatorRewardPoolShare(Delegator storage del, uint256 _round) internal constant returns (uint256) {
        RewardPool storage rewardPool = transcoders[del.delegateAddress].tokenPoolsPerRound[_round].rewardPool;

        if (rewardPool.rewards == 0) {
            return 0;
        } else {
            return rewardPool.rewards.mul(del.bondedAmount).div(rewardPool.transcoderTotalStake);
        }
    }

    /*
     * @dev Computes delegator's share of fee pool for a round
     */
    function delegatorFeePoolShare(Delegator storage del, uint256 _round) internal constant returns (uint256) {
        ClaimFees[] storage feePool = transcoders[del.delegateAddress].tokenPoolsPerRound[_round].feePool;

        if (feePool.length == 0) {
            return 0;
        } else {
            uint256 feeShare = 0;

            for (uint256 i = 0; i < feePool.length; i++) {
                // Fees are only claimable if delegator bonded to transcoder before claim submission
                if (del.delegateBlock < feePool[i].claimBlock) {
                    feeShare = feeShare.add(feePool[i].fees.mul(del.bondedAmount).div(feePool[i].transcoderTotalStake));
                }
            }

            return feeShare;
        }
    }

    /*
     * @dev Return rounds manager
     */
    function roundsManager() internal constant returns (IRoundsManager) {
        return IRoundsManager(ContractRegistry(registry).registry(keccak256("RoundsManager")));
    }

    /*
     * @dev Return jobs manager
     */
    function jobsManager() internal constant returns (IJobsManager) {
        return IJobsManager(ContractRegistry(registry).registry(keccak256("JobsManager")));
    }
}
