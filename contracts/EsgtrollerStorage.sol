pragma solidity >=0.5.16;

import "./EToken.sol";
import "./PriceOracle.sol";

contract UnitrollerEvents {
    /**
      * @notice Emitted when pendingEsgtrollerImplementation is accepted, which means esgtroller implementation is updated
      */
    event NewImplementation(address oldImplementation, address newImplementation);

    /**
      * @notice Emitted when pendingAdmin is changed
      */
    event NewPendingAdmin(address oldPendingAdmin, address newPendingAdmin);

    /**
      * @notice Emitted when pendingAdmin is accepted, which means admin is updated
      */
    event NewAdmin(address oldAdmin, address newAdmin);
}
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
    address public esgtrollerImplementation;
}

contract EsgtrollerV1Storage is UnitrollerAdminStorage {

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
    * @notice address of ESG
    */
    address public esg;

    /**
     * @notice Per-account mapping of "assets you are in", capped by maxAssets
     */
    mapping(address => EToken[]) public accountAssets;

}

contract EsgtrollerV2Storage is EsgtrollerV1Storage {
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

        /// @notice Whether or not this market receives ESG
        bool isEsged;
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

contract EsgtrollerV3Storage is EsgtrollerV2Storage {
    struct EsgMarketState {
        /// @notice The market's last updated esgBorrowIndex or esgupplyIndex
        uint224 index;

        /// @notice The block number the index was last updated at
        uint32 block;
    }

    /// @notice A list of all markets
    EToken[] public allMarkets;

    /// @notice The rate at which the flywheel distributes ESG, per block
    uint public esgRate;

    /// @notice The portion of esgRate that each market currently receives
    mapping(address => uint) public esgSpeeds;

    /// @notice The ESG market supply state for each market
    mapping(address => EsgMarketState) public esgSupplyState;

    /// @notice The ESG market borrow state for each market
    mapping(address => EsgMarketState) public esgBorrowState;

    /// @notice The ESG borrow index for each market for each supplier as of the last time they accrued ESG
    mapping(address => mapping(address => uint)) public esgSupplierIndex;

    /// @notice The ESG borrow index for each market for each borrower as of the last time they accrued ESG
    mapping(address => mapping(address => uint)) public esgBorrowerIndex;

    /// @notice The ESG accrued but not yet transferred to each user
    mapping(address => uint) public esgAccrued;
}

contract EsgtrollerV4Storage is EsgtrollerV3Storage {
    // @notice The borrowCapGuardian can set borrowCaps to any number for any market. Lowering the borrow cap could disable borrowing on the given market.
    address public borrowCapGuardian;

    // @notice Borrow caps enforced by borrowAllowed for each eToken address. Defaults to zero which corresponds to unlimited borrowing.
    mapping(address => uint) public borrowCaps;
}

contract EsgtrollerV5Storage is EsgtrollerV4Storage {
    /// @notice The portion of ESG that each contributor receives per block
    mapping(address => uint) public esgContributorSpeeds;

    /// @notice Last block at which a contributor's ESG rewards have been allocated
    mapping(address => uint) public lastContributorBlock;
}