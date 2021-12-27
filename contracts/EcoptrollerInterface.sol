// SPDX-License-Identifier: MIT

pragma solidity >=0.6.2;

abstract contract EcoptrollerInterface {
    /// @notice Indicator that this is a Ecoptroller contract (for inspection)
    bool public constant isEcoptroller = true;

    /*** Assets You Are In ***/

    function enterMarkets(address[] calldata eTokens) external virtual returns (uint[] memory);
    function exitMarket(address eToken) external virtual returns (uint);

    /*** Policy Hooks ***/

    function mintAllowed(address eToken, address minter, uint mintAmount) external virtual returns (uint);
    function mintVerify(address eToken, address minter, uint mintAmount, uint mintTokens) external virtual;

    function redeemAllowed(address eToken, address redeemer, uint redeemTokens) external virtual returns (uint);
    function redeemVerify(address eToken, address redeemer, uint redeemAmount, uint redeemTokens) external virtual;

    function borrowAllowed(address eToken, address borrower, uint borrowAmount) external virtual returns (uint);
    function borrowVerify(address eToken, address borrower, uint borrowAmount) external virtual;

    function repayBorrowAllowed(
        address eToken,
        address payer,
        address borrower,
        uint repayAmount) external virtual returns (uint);
    function repayBorrowVerify(
        address eToken,
        address payer,
        address borrower,
        uint repayAmount,
        uint borrowerIndex) external virtual;

    function liquidateBorrowAllowed(
        address eTokenBorrowed,
        address eTokenCollateral,
        address liquidator,
        address borrower,
        uint repayAmount) external virtual returns (uint);
    function liquidateBorrowVerify(
        address eTokenBorrowed,
        address eTokenCollateral,
        address liquidator,
        address borrower,
        uint repayAmount,
        uint seizeTokens) external virtual;

    function seizeAllowed(
        address eTokenCollateral,
        address eTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens) external virtual returns (uint);
    function seizeVerify(
        address eTokenCollateral,
        address eTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens) external virtual;

    function transferAllowed(address eToken, address src, address dst, uint transferTokens) external virtual returns (uint);
    function transferVerify(address eToken, address src, address dst, uint transferTokens) external virtual;

    /*** Liquidity/Liquidation Calculations ***/

    function liquidateCalculateSeizeTokens(
        address eTokenBorrowed,
        address eTokenCollateral,
        uint repayAmount) external virtual returns (uint, uint);
}
