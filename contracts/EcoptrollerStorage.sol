pragma solidity ^0.5.16;

import "./EToken.sol";
import "./PriceOracle.sol";

contract UnitrollerAdminStorage {
    /**
    * @notice Administrator for this contract
    */
    address public admin;

    /**
    * @notice Pending administrator for this contract
    */
    address public pendingAdmin;

    /**
    * @notice Active brains of Unitroller
    */
    address public ecoptrollerImplementation;

    /**
    * @notice Pending brains of Unitroller
    */
    address public pendingEcoptrollerImplementation;
}

contract EcoptrollerV1Storage is UnitrollerAdminStorage {

    /**
     * @notice Oracle which gives the price of any given asset
     */
    PriceOracle public oracle;

    /**
     * @notice Multiplier used to calculate the maximum repayAmount when liquidating a borrow
     */
    uint public closeFactorMantissa;

    /**
     * @notice Multiplier representing the discount on collateral that a liquidator receives
     */
    uint public liquidationIncentiveMantissa;

    /**
     * @notice Max number of assets a single account can participate in (borrow or use as collateral)
     */
    uint public maxAssets;

    /**
     * @notice Per-account mapping of "assets you are in", capped by maxAssets
     */
    mapping(address => EToken[]) public accountAssets;

}

contract EcoptrollerV2Storage is EcoptrollerV1Storage {
    struct Market {
        /// @notice Whether or not this market is listed
        bool isListed;

        /**
         * @notice Multiplier representing the most one can borrow against their collateral in this market.
         *  For instance, 0.9 to allow borrowing 90% of collateral value.
         *  Must be between 0 and 1, and stored as a mantissa.
         */
        uint collateralFactorMantissa;

        /// @notice Per-market mapping of "accounts in this asset"
        mapping(address => bool) accountMembership;

        /// @notice Whether or not this market receives COMP
        bool isEcoped;
    }

    /**
     * @notice Official mapping of eTokens -> Market metadata
     * @dev Used e.g. to determine if a market is supported
     */
    mapping(address => Market) public markets;


    /**
     * @notice The Pause Guardian can pause certain actions as a safety mechanism.
     *  Actions which allow users to remove their own assets cannot be paused.
     *  Liquidation / seizing / transfer can only be paused globally, not by market.
     */
    address public pauseGuardian;
    bool public _mintGuardianPaused;
    bool public _borrowGuardianPaused;
    bool public transferGuardianPaused;
    bool public seizeGuardianPaused;
    mapping(address => bool) public mintGuardianPaused;
    mapping(address => bool) public borrowGuardianPaused;
}

contract EcoptrollerV3Storage is EcoptrollerV2Storage {
    struct EcopMarketState {
        /// @notice The market's last updated ecopBorrowIndex or ecopSupplyIndex
        uint224 index;

        /// @notice The block number the index was last updated at
        uint32 block;
    }

    /// @notice A list of all markets
    EToken[] public allMarkets;

    /// @notice The rate at which the flywheel distributes COMP, per block
    uint public ecopRate;

    /// @notice The portion of ecopRate that each market currently receives
    mapping(address => uint) public ecopSpeeds;

    /// @notice The COMP market supply state for each market
    mapping(address => EcopMarketState) public ecopSupplyState;

    /// @notice The COMP market borrow state for each market
    mapping(address => EcopMarketState) public ecopBorrowState;

    /// @notice The COMP borrow index for each market for each supplier as of the last time they accrued COMP
    mapping(address => mapping(address => uint)) public ecopSupplierIndex;

    /// @notice The COMP borrow index for each market for each borrower as of the last time they accrued COMP
    mapping(address => mapping(address => uint)) public ecopBorrowerIndex;

    /// @notice The COMP accrued but not yet transferred to each user
    mapping(address => uint) public ecopAccrued;
}

contract EcoptrollerV4Storage is EcoptrollerV3Storage {
    // @notice The borrowCapGuardian can set borrowCaps to any number for any market. Lowering the borrow cap could disable borrowing on the given market.
    address public borrowCapGuardian;

    // @notice Borrow caps enforced by borrowAllowed for each eToken address. Defaults to zero which corresponds to unlimited borrowing.
    mapping(address => uint) public borrowCaps;
}

contract EcoptrollerV5Storage is EcoptrollerV4Storage {
    /// @notice The portion of COMP that each contributor receives per block
    mapping(address => uint) public ecopContributorSpeeds;

    /// @notice Last block at which a contributor's COMP rewards have been allocated
    mapping(address => uint) public lastContributorBlock;
}
