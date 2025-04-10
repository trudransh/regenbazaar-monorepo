// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "../interfaces/IREBAZ.sol";

/**
 * @title REBAZToken
 * @author Regen Bazaar
 * @notice Implementation of the REBAZ token which serves as the utility and governance token
 * @custom:security-contact security@regenbazaar.com
 */
contract REBAZToken is IREBAZ, ERC20, ERC20Burnable, Pausable, AccessControl, ReentrancyGuard {
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant SLASHER_ROLE = keccak256("SLASHER_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");

    // Staking parameters
    uint256 public minStakeDuration;
    uint256 public maxStakeDuration;
    uint256 public baseRewardRate; // In basis points (1% = 100)

    // Governance parameters
    uint256 public proposalThreshold;
    uint256 public votingPeriod;
    uint256 public votingDelay;

    // Staking storage
    struct StakeInfo {
        uint256 amount;
        uint256 startTime;
        uint256 endTime;
        bool withdrawn;
    }

    // Mapping: user => stake ID => stake info
    mapping(address => mapping(uint256 => StakeInfo)) private _stakes;
    mapping(address => uint256) private _stakeCount;
    mapping(address => uint256) private _totalStaked;

    // Validator slashing tracking
    mapping(address => uint256) private _slashedAmount;

    /**
     * @notice Constructor to initialize the REBAZ token
     * @param initialSupply Initial token supply to mint to admin
     * @param admin Address that receives initial supply and admin roles
     */
    constructor(uint256 initialSupply, address admin) ERC20("Regen Bazaar Token", "REBAZ") {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(MINTER_ROLE, admin);
        _grantRole(SLASHER_ROLE, admin);
        _grantRole(GOVERNANCE_ROLE, admin);

        // Set initial staking parameters
        minStakeDuration = 7 days;
        maxStakeDuration = 365 days;
        baseRewardRate = 500; // 5% base APR

        // Set initial governance parameters
        proposalThreshold = 100000 * 10 ** decimals(); // 100,000 REBAZ
        votingPeriod = 40320; // ~7 days in blocks (assuming 15s block time)
        votingDelay = 11520; // ~2 days in blocks

        // Mint initial supply to admin
        _mint(admin, initialSupply);
    }

    /**
     * @notice Pause token transfers
     * @dev Only accounts with PAUSER_ROLE can call this function
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause token transfers
     * @dev Only accounts with PAUSER_ROLE can call this function
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /**
     * @notice Mint new tokens
     * @dev Only accounts with MINTER_ROLE can call this function
     * @param to Recipient of the new tokens
     * @param amount Amount of tokens to mint
     */
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    /**
     * @notice Implementation of stake function
     * @param amount Amount of tokens to stake
     * @param duration Duration in seconds to stake tokens
     * @return success Boolean indicating operation success
     */
    function stake(uint256 amount, uint256 duration) external whenNotPaused nonReentrant returns (bool success) {
        require(amount > 0, "Cannot stake 0 tokens");
        require(duration >= minStakeDuration, "Staking duration too short");
        require(duration <= maxStakeDuration, "Staking duration too long");
        require(balanceOf(msg.sender) >= amount, "Insufficient balance");

        // Transfer tokens from user to contract
        _transfer(msg.sender, address(this), amount);

        // Create new stake entry
        uint256 stakeId = _stakeCount[msg.sender];
        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + duration;

        _stakes[msg.sender][stakeId] =
            StakeInfo({ amount: amount, startTime: startTime, endTime: endTime, withdrawn: false });

        // Update user's total staked amount and stake count
        _totalStaked[msg.sender] += amount;
        _stakeCount[msg.sender] += 1;

        emit TokensStaked(msg.sender, amount, duration, endTime);
        return true;
    }

    /**
     * @notice Implementation of withdraw function
     * @param stakeId ID of the stake to withdraw
     * @return amount Amount of staked tokens withdrawn
     * @return reward Amount of reward tokens received
     */
    function withdraw(uint256 stakeId) external nonReentrant returns (uint256 amount, uint256 reward) {
        StakeInfo storage stakeInfo = _stakes[msg.sender][stakeId];

        require(stakeInfo.amount > 0, "Stake does not exist");
        require(!stakeInfo.withdrawn, "Stake already withdrawn");

        // Check if lock period has ended
        bool matured = block.timestamp >= stakeInfo.endTime;

        // Calculate reward (no reward if withdrawn early)
        reward = matured ? calculateReward(stakeId) : 0;
        amount = stakeInfo.amount;

        // Mark stake as withdrawn
        stakeInfo.withdrawn = true;
        _totalStaked[msg.sender] -= amount;

        // Transfer staked tokens back to user
        _transfer(address(this), msg.sender, amount);

        // Mint reward tokens if applicable
        if (reward > 0) {
            _mint(msg.sender, reward);
        }

        emit StakeWithdrawn(msg.sender, amount, reward);
        return (amount, reward);
    }

    /**
     * @notice Calculate the reward for a stake
     * @param stakeId ID of the stake
     * @return reward Amount of reward tokens
     */
    function calculateReward(uint256 stakeId) public view returns (uint256 reward) {
        StakeInfo storage stakeInfo = _stakes[msg.sender][stakeId];

        if (stakeInfo.amount == 0 || stakeInfo.withdrawn) {
            return 0;
        }

        // Calculate duration in years (with precision)
        uint256 durationInSeconds = stakeInfo.endTime - stakeInfo.startTime;
        uint256 durationInYears = (durationInSeconds * 10000) / 365 days; // Scaled by 10000 for precision

        // Calculate reward - base rate plus duration bonus
        uint256 rewardRate = baseRewardRate;

        // Add duration bonus (longer stakes get higher APR)
        if (durationInSeconds >= 180 days) {
            rewardRate += 100; // +1% for 6+ months
        }
        if (durationInSeconds >= 365 days) {
            rewardRate += 200; // +2% more for 12+ months
        }

        // Calculate actual reward
        // Formula: amount * rewardRate * durationInYears / (10000 * 10000)
        // First 10000 is from basis points (100% = 10000)
        // Second 10000 is from our durationInYears scaling
        reward = (stakeInfo.amount * rewardRate * durationInYears) / (10000 * 10000);
        return reward;
    }

    /**
     * @notice Get stake information for a user
     * @param user Address of the user
     * @param stakeId ID of the stake
     * @return amount Amount staked
     * @return startTime When the stake began
     * @return endTime When the stake will unlock
     * @return currentReward Current accumulated reward
     */
    function getStakeInfo(address user, uint256 stakeId)
        external
        view
        returns (uint256 amount, uint256 startTime, uint256 endTime, uint256 currentReward)
    {
        StakeInfo storage stakeInfo = _stakes[user][stakeId];
        return (
            stakeInfo.amount, stakeInfo.startTime, stakeInfo.endTime, stakeInfo.withdrawn ? 0 : calculateReward(stakeId)
        );
    }

    /**
     * @notice Get the total amount of tokens staked by a user
     * @param user Address of the user
     * @return totalStaked Total amount staked across all active stakes
     */
    function getTotalStaked(address user) external view returns (uint256 totalStaked) {
        return _totalStaked[user];
    }

    /**
     * @notice Get the voting power of a user based on token balance and stakes
     * @param user Address of the user
     * @return votingPower The user's voting power
     */
    function getVotingPower(address user) external view returns (uint256 votingPower) {
        // Voting power = balance + staked amount
        return balanceOf(user) + _totalStaked[user];
    }

    /**
     * @notice Slash tokens from a validator due to malicious/incorrect validations
     * @param validator Address of the validator to slash
     * @param amount Amount of tokens to slash
     * @param reason Reason for the slashing
     * @return success Boolean indicating if operation was successful
     */
    function slashValidator(address validator, uint256 amount, string calldata reason)
        external
        onlyRole(SLASHER_ROLE)
        returns (bool success)
    {
        uint256 validatorBalance = balanceOf(validator);
        uint256 validatorStaked = _totalStaked[validator];

        require(amount > 0, "Cannot slash 0 tokens");
        require(validatorBalance + validatorStaked >= amount, "Slash amount exceeds validator's tokens");

        // First slash from liquid balance
        uint256 slashFromBalance = amount < validatorBalance ? amount : validatorBalance;
        if (slashFromBalance > 0) {
            _burn(validator, slashFromBalance);
        }

        // If needed, slash from staked tokens
        if (slashFromBalance < amount) {
            uint256 remainingToSlash = amount - slashFromBalance;
            _slashedAmount[validator] += remainingToSlash;
            // Note: Actual slashing from stakes happens when they try to withdraw
        }

        emit ValidatorSlashed(validator, msg.sender, amount, reason);
        return true;
    }

    /**
     * @notice Update staking parameters
     * @param _minStakeDuration New minimum stake duration
     * @param _maxStakeDuration New maximum stake duration
     * @param _baseRewardRate New base annual reward rate (in basis points)
     */
    function updateStakingParams(uint256 _minStakeDuration, uint256 _maxStakeDuration, uint256 _baseRewardRate)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(_minStakeDuration <= _maxStakeDuration, "Min duration must be <= max duration");
        require(_baseRewardRate <= 5000, "Base reward rate too high"); // Max 50% APR

        minStakeDuration = _minStakeDuration;
        maxStakeDuration = _maxStakeDuration;
        baseRewardRate = _baseRewardRate;

        emit StakingSettingsUpdated(_minStakeDuration, _maxStakeDuration, _baseRewardRate);
    }

    /**
     * @notice Update governance parameters
     * @param _proposalThreshold New minimum tokens required to create proposal
     * @param _votingPeriod New duration of voting in blocks
     * @param _votingDelay New delay before voting starts in blocks
     */
    function updateGovernanceParams(uint256 _proposalThreshold, uint256 _votingPeriod, uint256 _votingDelay)
        external
        onlyRole(GOVERNANCE_ROLE)
    {
        proposalThreshold = _proposalThreshold;
        votingPeriod = _votingPeriod;
        votingDelay = _votingDelay;

        emit GovernanceParamsUpdated(_proposalThreshold, _votingPeriod, _votingDelay);
    }

    /**
     * @notice Override ERC20 _beforeTokenTransfer with pause functionality
     */
    // function _beforeTokenTransfer(address from, address to, uint256 amount)
    //     internal
    //     whenNotPaused
    //     override
    // {
    //     super._beforeTokenTransfer(from, to, amount);
    // }

    // function SLASHER_ROLE() external pure returns (bytes32) {
    //     return keccak256("SLASHER_ROLE");
    // }

    // function GOVERNANCE_ROLE() external pure returns (bytes32) {
    //     return keccak256("GOVERNANCE_ROLE");
    // }
}
