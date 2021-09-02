pragma solidity ^0.5.16;

contract EcoptrollerInterface {
    /// @notice Indicator that this is a Ecoptroller contract (for inspection)
    bool public constant isEcoptroller = true;

    /*** Assets You Are In ***/

    function enterMarkets(address[] calldata eTokens) external returns (uint[] memory);
    function exitMarket(address eToken) external returns (uint);

    /*** Policy Hooks ***/

    function mintAllowed(address eToken, address minter, uint mintAmount) external returns (uint);
    function mintVerify(address eToken, address minter, uint mintAmount, uint mintTokens) external;

    function redeemAllowed(address eToken, address redeemer, uint redeemTokens) external returns (uint);
    function redeemVerify(address eToken, address redeemer, uint redeemAmount, uint redeemTokens) external;

    function borrowAllowed(address eToken, address borrower, uint borrowAmount) external returns (uint);
    function borrowVerify(address eToken, address borrower, uint borrowAmount) external;

    function repayBorrowAllowed(
        address eToken,
        address payer,
        address borrower,
        uint repayAmount) external returns (uint);
    function repayBorrowVerify(
        address eToken,
        address payer,
        address borrower,
        uint repayAmount,
        uint borrowerIndex) external;

    function liquidateBorrowAllowed(
        address eTokenBorrowed,
        address eTokenCollateral,
        address liquidator,
        address borrower,
        uint repayAmount) external returns (uint);
    function liquidateBorrowVerify(
        address eTokenBorrowed,
        address eTokenCollateral,
        address liquidator,
        address borrower,
        uint repayAmount,
        uint seizeTokens) external;

    function seizeAllowed(
        address eTokenCollateral,
        address eTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens) external returns (uint);
    function seizeVerify(
        address eTokenCollateral,
        address eTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens) external;

    function transferAllowed(address eToken, address src, address dst, uint transferTokens) external returns (uint);
    function transferVerify(address eToken, address src, address dst, uint transferTokens) external;

    /*** Liquidity/Liquidation Calculations ***/

    function liquidateCalculateSeizeTokens(
        address eTokenBorrowed,
        address eTokenCollateral,
        uint repayAmount) external view returns (uint, uint);
}
