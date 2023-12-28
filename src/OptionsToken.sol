// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import {OwnableUpgradeable} from "oz-upgradeable/access/OwnableUpgradeable.sol";
import {ERC20Upgradeable} from "oz-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {UUPSUpgradeable} from "oz-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {IOptionsToken} from "./interfaces/IOptionsToken.sol";
import {IOracle} from "./interfaces/IOracle.sol";
import {IExercise} from "./interfaces/IExercise.sol";

/// @title Options Token
/// @author zefram.eth
/// @notice Options token representing the right to perform an advantageous action,
/// such as purchasing the underlying token at a discount to the market price.
contract OptionsToken is IOptionsToken, ERC20Upgradeable, OwnableUpgradeable, UUPSUpgradeable {
    /// -----------------------------------------------------------------------
    /// Errors
    /// -----------------------------------------------------------------------

    error OptionsToken__NotTokenAdmin();
    error OptionsToken__NotExerciseContract();
    error Upgradeable__Unauthorized();

    /// -----------------------------------------------------------------------
    /// Events
    /// -----------------------------------------------------------------------

    event Exercise(
        address indexed sender,
        address indexed recipient,
        uint256 amount,
        address data0,
        uint256 data1,
        uint256 data2
    );
    event SetOracle(IOracle indexed newOracle);
    event SetTreasury(address indexed newTreasury);
    event SetExerciseContract(address indexed _address, bool _isExercise);

    /// -----------------------------------------------------------------------
    /// Constant parameters
    /// -----------------------------------------------------------------------

    uint256 public constant UPGRADE_TIMELOCK = 48 hours;
    uint256 public constant FUTURE_NEXT_PROPOSAL_TIME = 365 days * 100;

    /// -----------------------------------------------------------------------
    /// Storage variables
    /// -----------------------------------------------------------------------

    /// @notice The contract that has the right to mint options tokens
    address public tokenAdmin;

    /// @notice The address that can perform upgrades
    address public upgradeAdmin;

    mapping (address => bool) public isExerciseContract;
    uint256 public upgradeProposalTime;

    /// -----------------------------------------------------------------------
    /// Modifier
    /// -----------------------------------------------------------------------

    modifier onlyUpgradeAdmin() {
        if (msg.sender != upgradeAdmin) revert Upgradeable__Unauthorized();
        _;
    }

    /// -----------------------------------------------------------------------
    /// Initializer
    /// -----------------------------------------------------------------------

    function initialize(
        string memory name_,
        string memory symbol_,
        address owner_,
        address tokenAdmin_,
        address upgradeAdmin_
    ) external initializer {
        __UUPSUpgradeable_init();
        __ERC20_init(name_, symbol_);
        __Ownable_init(owner_);
        tokenAdmin = tokenAdmin_;
        upgradeAdmin = upgradeAdmin_;

        clearUpgradeCooldown();
    }

    /// -----------------------------------------------------------------------
    /// External functions
    /// -----------------------------------------------------------------------

    /// @notice Called by the token admin to mint options tokens
    /// @param to The address that will receive the minted options tokens
    /// @param amount The amount of options tokens that will be minted
    function mint(address to, uint256 amount) external virtual override {
        /// -----------------------------------------------------------------------
        /// Verification
        /// -----------------------------------------------------------------------

        if (msg.sender != tokenAdmin) revert OptionsToken__NotTokenAdmin();

        /// -----------------------------------------------------------------------
        /// State updates
        /// -----------------------------------------------------------------------

        // skip if amount is zero
        if (amount == 0) return;

        // mint options tokens
        _mint(to, amount);
    }

    /// @notice Exercises options tokens, giving the reward to the recipient.
    /// @dev WARNING: If `amount` is zero, the bytes returned will be empty and therefore, not decodable.
    /// @dev The options tokens are not burnt but sent to address(0) to avoid messing up the
    /// inflation schedule.
    /// @param amount The amount of options tokens to exercise
    /// @param recipient The recipient of the reward
    /// @param params Extra parameters to be used by the exercise function
    function exercise(uint256 amount, address recipient, address option, bytes calldata params)
        external
        virtual
        returns (uint256 paymentAmount, address, uint256, uint256) // misc data
    {
        return _exercise(amount, recipient, option, params);
    }

    /// -----------------------------------------------------------------------
    /// Owner functions
    /// -----------------------------------------------------------------------

    /// @notice Adds a new Exercise contract to the available options.
    /// @param _address Address of the Exercise contract, that implements BaseExercise.
    /// @param _isExercise Whether oToken holders should be allowed to exercise using this option.
    function setExerciseContract(address _address, bool _isExercise) external onlyOwner {
        isExerciseContract[_address] = _isExercise;
        emit SetExerciseContract(_address, _isExercise);
    }

    /// -----------------------------------------------------------------------
    /// Internal functions
    /// -----------------------------------------------------------------------

    function _exercise(uint256 amount, address recipient, address option, bytes calldata params)
        internal
        virtual
        returns (uint256 paymentAmount, address data0, uint256 data1, uint256 data2) // misc data
    {
        // skip if amount is zero
        if (amount == 0) return (0, address(0), 0, 0);

        // skip if option is not active
        if (!isExerciseContract[option]) revert OptionsToken__NotExerciseContract();

        // transfer options tokens from msg.sender to address(0)
        // we transfer instead of burn because TokenAdmin cares about totalSupply
        // which we don't want to change in order to follow the emission schedule
        transfer(address(0x1), amount);

        // give rewards to recipient
        (
            paymentAmount,
            data0,
            data1,
            data2
        ) = IExercise(option).exercise(msg.sender, amount, recipient, params);

        // emit event
        emit Exercise(
            msg.sender,
            recipient,
            amount,
            data0,
            data1,
            data2
        );
    }

    /// -----------------------------------------------------------------------
    /// UUPS functions
    /// -----------------------------------------------------------------------

    /**
     * @dev This function must be called prior to upgrading the implementation.
     *      It's required to wait UPGRADE_TIMELOCK seconds before executing the upgrade.
     *      Strategists and roles with higher privilege can initiate this cooldown.
     */
    function initiateUpgradeCooldown() onlyUpgradeAdmin() external {
        upgradeProposalTime = block.timestamp;
    }

    /**
     * @dev This function is called:
     *      - in initialize()
     *      - as part of a successful upgrade
     *      - manually to clear the upgrade cooldown.
     * Guardian and roles with higher privilege can clear this cooldown.
     */
    function clearUpgradeCooldown() public {
        if (msg.sender != upgradeAdmin && !(upgradeProposalTime == 0)) revert Upgradeable__Unauthorized();
        upgradeProposalTime = block.timestamp + FUTURE_NEXT_PROPOSAL_TIME;
    }

    /**
     * @dev This function must be overriden simply for access control purposes.
     *      Only DEFAULT_ADMIN_ROLE can upgrade the implementation once the timelock
     *      has passed.
     */
    function _authorizeUpgrade(address) onlyUpgradeAdmin internal override {
        require(
            upgradeProposalTime + UPGRADE_TIMELOCK < block.timestamp, "Upgrade cooldown not initiated or still ongoing"
        );
        clearUpgradeCooldown();
    }
}
