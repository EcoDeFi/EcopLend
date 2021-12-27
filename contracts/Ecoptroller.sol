// SPDX-License-Identifier: MIT

pragma solidity >=0.6.2;

import "./EToken.sol";
import "./ErrorReporter.sol";
import "./PriceOracle.sol";
import "./EcoptrollerInterface.sol";
import "./EcoptrollerStorage.sol";
import "./Unitroller.sol";
import "./Governance/Ecop.sol";

/**
 * @title ECOP's Ecoptroller Contract
 * @author ECOP
 */

contract Ecoptroller is EcoptrollerV5Storage, EcoptrollerInterface, EcoptrollerErrorReporter, ExponentialNoError {
    /// @notice Emitted when an admin supports a market
    event MarketListed(EToken eToken);

    /// @notice Emitted when an account enters a market
    event MarketEntered(EToken eToken, address account);

    /// @notice Emitted when an account exits a market
    event MarketExited(EToken eToken, address account);

    /// @notice Emitted when close factor is changed by admin
    event NewCloseFactor(uint oldCloseFactorMantissa, uint newCloseFactorMantissa);

    /// @notice Emitted when a collateral factor is changed by admin
    event NewCollateralFactor(EToken eToken, uint oldCollateralFactorMantissa, uint newCollateralFactorMantissa);

    /// @notice Emitted when liquidation incentive is changed by admin
    event NewLiquidationIncentive(uint oldLiquidationIncentiveMantissa, uint newLiquidationIncentiveMantissa);

    /// @notice Emitted when price oracle is changed
    event NewPriceOracle(PriceOracle oldPriceOracle, PriceOracle newPriceOracle);

    /// @notice Emitted when pause guardian is changed
    event NewPauseGuardian(address oldPauseGuardian, address newPauseGuardian);

    /// @notice Emitted when an action is paused globally
    event ActionPaused(string action, bool pauseState);

    /// @notice Emitted when an action is paused on a market
    event ActionPaused(EToken eToken, string action, bool pauseState);

    /// @notice Emitted when a new ECOP speed is calculated for a market
    event EcopSpeedUpdated(EToken indexed eToken, uint newSpeed);

    /// @notice Emitted when a new ECOP speed is set for a contributor
    event ContributorEcopSpeedUpdated(address indexed contributor, uint newSpeed);

    /// @notice Emitted when ECOP is distributed to a supplier
    event DistributedSupplierEcop(EToken indexed eToken, address indexed supplier, uint ecopDelta, uint ecopSupplyIndex);

    /// @notice Emitted when ECOP is distributed to a borrower
    event DistributedBorrowerEcop(EToken indexed eToken, address indexed borrower, uint ecopDelta, uint ecopBorrowIndex);

    /// @notice Emitted when borrow cap for a eToken is changed
    event NewBorrowCap(EToken indexed eToken, uint newBorrowCap);

    /// @notice Emitted when borrow cap guardian is changed
    event NewBorrowCapGuardian(address oldBorrowCapGuardian, address newBorrowCapGuardian);

    /// @notice Emitted when ECOP is granted by admin
    event EcopGranted(address recipient, uint amount);

    /// @notice The initial ECOP index for a market
    uint224 public constant ecopInitialIndex = 1e36;

    // closeFactorMantissa must be strictly greater than this value
    uint internal constant closeFactorMinMantissa = 0.05e18; // 0.05

    // closeFactorMantissa must not exceed this value
    uint internal constant closeFactorMaxMantissa = 0.9e18; // 0.9

    // No collateralFactorMantissa may exceed this value
    uint internal constant collateralFactorMaxMantissa = 0.9e18; // 0.9

    constructor() {
        admin = msg.sender;
    }

    /*** Assets You Are In ***/

    /**
     * @notice Returns the assets an account has entered
     * @param account The address of the account to pull assets for
     * @return A dynamic list with the assets the account has entered
     */
    function getAssetsIn(address account) external view returns (EToken[] memory) {
        EToken[] memory assetsIn = accountAssets[account];

        return assetsIn;
    }

    /**
     * @notice Returns whether the given account is entered in the given asset
     * @param account The address of the account to check
     * @param eToken The eToken to check
     * @return True if the account is in the asset, otherwise false.
     */
    function checkMembership(address account, EToken eToken) external view returns (bool) {
        return markets[address(eToken)].accountMembership[account];
    }

    /**
     * @notice Add assets to be included in account liquidity calculation
     * @param eTokens The list of addresses of the eToken markets to be enabled
     * @return Success indicator for whether each corresponding market was entered
     */
    function enterMarkets(address[] memory eTokens) external override returns (uint[] memory) {
        uint len = eTokens.length;

        uint[] memory results = new uint[](len);
        for (uint i = 0; i < len; i++) {
            EToken eToken = EToken(eTokens[i]);

            results[i] = uint(addToMarketInternal(eToken, msg.sender));
        }

        return results;
    }

    /**
     * @notice Add the market to the borrower's "assets in" for liquidity calculations
     * @param eToken The market to enter
     * @param borrower The address of the account to modify
     * @return Success indicator for whether the market was entered
     */
    function addToMarketInternal(EToken eToken, address borrower) internal returns (Error) {
        Market storage marketToJoin = markets[address(eToken)];

        if (!marketToJoin.isListed) {
            // market is not listed, cannot join
            return Error.MARKET_NOT_LISTED;
        }

        if (marketToJoin.accountMembership[borrower] == true) {
            // already joined
            return Error.NO_ERROR;
        }

        // survived the gauntlet, add to list
        // NOTE: we store these somewhat redundantly as a significant optimization
        //  this avoids having to iterate through the list for the most common use cases
        //  that is, only when we need to perform liquidity checks
        //  and not whenever we want to check if an account is in a particular market
        marketToJoin.accountMembership[borrower] = true;
        accountAssets[borrower].push(eToken);

        emit MarketEntered(eToken, borrower);

        return Error.NO_ERROR;
    }

    /**
     * @notice Removes asset from sender's account liquidity calculation
     * @dev Sender must not have an outstanding borrow balance in the asset,
     *  or be providing necessary collateral for an outstanding borrow.
     * @param eTokenAddress The address of the asset to be removed
     * @return Whether or not the account successfully exited the market
     */
    function exitMarket(address eTokenAddress) external override returns (uint) {
        EToken eToken = EToken(eTokenAddress);
        /* Get sender tokensHeld and amountOwed underlying from the eToken */
        (uint oErr, uint tokensHeld, uint amountOwed, ) = eToken.getAccountSnapshot(msg.sender);
        require(oErr == 0, "exitMarket: getAccountSnapshot failed"); // semi-opaque error code

        /* Fail if the sender has a borrow balance */
        if (amountOwed != 0) {
            return fail(Error.NONZERO_BORROW_BALANCE, FailureInfo.EXIT_MARKET_BALANCE_OWED);
        }

        /* Fail if the sender is not permitted to redeem all of their tokens */
        uint allowed = redeemAllowedInternal(eTokenAddress, msg.sender, tokensHeld);
        if (allowed != 0) {
            return failOpaque(Error.REJECTION, FailureInfo.EXIT_MARKET_REJECTION, allowed);
        }

        Market storage marketToExit = markets[address(eToken)];

        /* Return true if the sender is not already ‘in’ the market */
        if (!marketToExit.accountMembership[msg.sender]) {
            return uint(Error.NO_ERROR);
        }

        /* Set eToken account membership to false */
        delete marketToExit.accountMembership[msg.sender];

        /* Delete eToken from the account’s list of assets */
        // load into memory for faster iteration
        EToken[] memory userAssetList = accountAssets[msg.sender];
        uint len = userAssetList.length;
        uint assetIndex = len;
        for (uint i = 0; i < len; i++) {
            if (userAssetList[i] == eToken) {
                assetIndex = i;
                break;
            }
        }

        // We *must* have found the asset in the list or our redundant data structure is broken
        assert(assetIndex < len);

        // copy last item in list to location of item to be removed, reduce length by 1
        EToken[] storage storedList = accountAssets[msg.sender];
        storedList[assetIndex] = storedList[storedList.length - 1];
        delete(storedList[storedList.length - 1]);

        emit MarketExited(eToken, msg.sender);

        return uint(Error.NO_ERROR);
    }

    /*** Policy Hooks ***/

    /**
     * @notice Checks if the account should be allowed to mint tokens in the given market
     * @param eToken The market to verify the mint against
     * @param minter The account which would get the minted tokens
     * @param mintAmount The amount of underlying being supplied to the market in exchange for tokens
     * @return 0 if the mint is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function mintAllowed(address eToken, address minter, uint mintAmount) external override returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!mintGuardianPaused[eToken], "mint is paused");

        // Shh - currently unused
        minter;
        mintAmount;

        if (!markets[eToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        // Keep the flywheel moving
        updateEcopSupplyIndex(eToken);
        distributeSupplierEcop(eToken, minter);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates mint and reverts on rejection. May emit logs.
     * @param eToken Asset being minted
     * @param minter The address minting the tokens
     * @param actualMintAmount The amount of the underlying asset being minted
     * @param mintTokens The number of tokens being minted
     */
    function mintVerify(address eToken, address minter, uint actualMintAmount, uint mintTokens) external override {
        // Shh - currently unused
        eToken;
        minter;
        actualMintAmount;
        mintTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the account should be allowed to redeem tokens in the given market
     * @param eToken The market to verify the redeem against
     * @param redeemer The account which would redeem the tokens
     * @param redeemTokens The number of eTokens to exchange for the underlying asset in the market
     * @return 0 if the redeem is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function redeemAllowed(address eToken, address redeemer, uint redeemTokens) external override returns (uint) {
        uint allowed = redeemAllowedInternal(eToken, redeemer, redeemTokens);
        if (allowed != uint(Error.NO_ERROR)) {
            return allowed;
        }

        // Keep the flywheel moving
        updateEcopSupplyIndex(eToken);
        distributeSupplierEcop(eToken, redeemer);

        return uint(Error.NO_ERROR);
    }

    function redeemAllowedInternal(address eToken, address redeemer, uint redeemTokens) internal returns (uint) {
        if (!markets[eToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        /* If the redeemer is not 'in' the market, then we can bypass the liquidity check */
        if (!markets[eToken].accountMembership[redeemer]) {
            return uint(Error.NO_ERROR);
        }

        /* Otherwise, perform a hypothetical liquidity check to guard against shortfall */
        (Error err, , uint shortfall) = getHypotheticalAccountLiquidityInternal(redeemer, EToken(eToken), redeemTokens, 0);
        if (err != Error.NO_ERROR) {
            return uint(err);
        }
        if (shortfall > 0) {
            return uint(Error.INSUFFICIENT_LIQUIDITY);
        }

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates redeem and reverts on rejection. May emit logs.
     * @param eToken Asset being redeemed
     * @param redeemer The address redeeming the tokens
     * @param redeemAmount The amount of the underlying asset being redeemed
     * @param redeemTokens The number of tokens being redeemed
     */
    function redeemVerify(address eToken, address redeemer, uint redeemAmount, uint redeemTokens) external pure override {
        // Shh - currently unused
        eToken;
        redeemer;

        // Require tokens is zero or amount is also zero
        if (redeemTokens == 0 && redeemAmount > 0) {
            revert("redeemTokens zero");
        }
    }

    /**
     * @notice Checks if the account should be allowed to borrow the underlying asset of the given market
     * @param eToken The market to verify the borrow against
     * @param borrower The account which would borrow the asset
     * @param borrowAmount The amount of underlying the account would borrow
     * @return 0 if the borrow is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function borrowAllowed(address eToken, address borrower, uint borrowAmount) external override returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!borrowGuardianPaused[eToken], "borrow is paused");

        if (!markets[eToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        if (!markets[eToken].accountMembership[borrower]) {
            // only eTokens may call borrowAllowed if borrower not in market
            require(msg.sender == eToken, "sender must be eToken");

            // attempt to add borrower to the market
            Error err = addToMarketInternal(EToken(msg.sender), borrower);
            if (err != Error.NO_ERROR) {
                return uint(err);
            }

            // it should be impossible to break the important invariant
            assert(markets[eToken].accountMembership[borrower]);
        }

        if (oracle.getUnderlyingPrice(EToken(eToken)) == 0) {
            return uint(Error.PRICE_ERROR);
        }


        uint borrowCap = borrowCaps[eToken];
        // Borrow cap of 0 corresponds to unlimited borrowing
        if (borrowCap != 0) {
            uint totalBorrows = EToken(eToken).totalBorrows();
            uint nextTotalBorrows = add_(totalBorrows, borrowAmount);
            require(nextTotalBorrows < borrowCap, "market borrow cap reached");
        }

        (Error erro, , uint shortfall) = getHypotheticalAccountLiquidityInternal(borrower, EToken(eToken), 0, borrowAmount);
        if (erro != Error.NO_ERROR) {
            return uint(erro);
        }
        if (shortfall > 0) {
            return uint(Error.INSUFFICIENT_LIQUIDITY);
        }

        // Keep the flywheel moving
        Exp memory borrowIndex = Exp({mantissa: EToken(eToken).borrowIndex()});
        updateEcopBorrowIndex(eToken, borrowIndex);
        distributeBorrowerEcop(eToken, borrower, borrowIndex);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates borrow and reverts on rejection. May emit logs.
     * @param eToken Asset whose underlying is being borrowed
     * @param borrower The address borrowing the underlying
     * @param borrowAmount The amount of the underlying asset requested to borrow
     */
    function borrowVerify(address eToken, address borrower, uint borrowAmount) external override {
        // Shh - currently unused
        eToken;
        borrower;
        borrowAmount;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the account should be allowed to repay a borrow in the given market
     * @param eToken The market to verify the repay against
     * @param payer The account which would repay the asset
     * @param borrower The account which would borrowed the asset
     * @param repayAmount The amount of the underlying asset the account would repay
     * @return 0 if the repay is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function repayBorrowAllowed(
        address eToken,
        address payer,
        address borrower,
        uint repayAmount) external override returns (uint) {
        // Shh - currently unused
        payer;
        borrower;
        repayAmount;

        if (!markets[eToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        // Keep the flywheel moving
        Exp memory borrowIndex = Exp({mantissa: EToken(eToken).borrowIndex()});
        updateEcopBorrowIndex(eToken, borrowIndex);
        distributeBorrowerEcop(eToken, borrower, borrowIndex);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates repayBorrow and reverts on rejection. May emit logs.
     * @param eToken Asset being repaid
     * @param payer The address repaying the borrow
     * @param borrower The address of the borrower
     * @param actualRepayAmount The amount of underlying being repaid
     */
    function repayBorrowVerify(
        address eToken,
        address payer,
        address borrower,
        uint actualRepayAmount,
        uint borrowerIndex) external override{
        // Shh - currently unused
        eToken;
        payer;
        borrower;
        actualRepayAmount;
        borrowerIndex;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the liquidation should be allowed to occur
     * @param eTokenBorrowed Asset which was borrowed by the borrower
     * @param eTokenCollateral Asset which was used as collateral and will be seized
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param repayAmount The amount of underlying being repaid
     */
    function liquidateBorrowAllowed(
        address eTokenBorrowed,
        address eTokenCollateral,
        address liquidator,
        address borrower,
        uint repayAmount) external override returns (uint) {
        // Shh - currently unused
        liquidator;

        if (!markets[eTokenBorrowed].isListed || !markets[eTokenCollateral].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        uint borrowBalance = EToken(eTokenBorrowed).borrowBalanceStored(borrower);

        /* allow accounts to be liquidated if the market is deprecated */
        if (isDeprecated(EToken(eTokenBorrowed))) {
            require(borrowBalance >= repayAmount, "Can not repay more than the total borrow");
        } else {
            /* The borrower must have shortfall in order to be liquidatable */
            (Error err, , uint shortfall) = getAccountLiquidityInternal(borrower);
            if (err != Error.NO_ERROR) {
                return uint(err);
            }

            if (shortfall == 0) {
                return uint(Error.INSUFFICIENT_SHORTFALL);
            }

            /* The liquidator may not repay more than what is allowed by the closeFactor */
            uint maxClose = mul_ScalarTruncate(Exp({mantissa: closeFactorMantissa}), borrowBalance);
            if (repayAmount > maxClose) {
                return uint(Error.TOO_MUCH_REPAY);
            }
        }
        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates liquidateBorrow and reverts on rejection. May emit logs.
     * @param eTokenBorrowed Asset which was borrowed by the borrower
     * @param eTokenCollateral Asset which was used as collateral and will be seized
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param actualRepayAmount The amount of underlying being repaid
     */
    function liquidateBorrowVerify(
        address eTokenBorrowed,
        address eTokenCollateral,
        address liquidator,
        address borrower,
        uint actualRepayAmount,
        uint seizeTokens) external override {
        // Shh - currently unused
        eTokenBorrowed;
        eTokenCollateral;
        liquidator;
        borrower;
        actualRepayAmount;
        seizeTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the seizing of assets should be allowed to occur
     * @param eTokenCollateral Asset which was used as collateral and will be seized
     * @param eTokenBorrowed Asset which was borrowed by the borrower
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param seizeTokens The number of collateral tokens to seize
     */
    function seizeAllowed(
        address eTokenCollateral,
        address eTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens) external override returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!seizeGuardianPaused, "seize is paused");

        // Shh - currently unused
        seizeTokens;

        if (!markets[eTokenCollateral].isListed || !markets[eTokenBorrowed].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        if (EToken(eTokenCollateral).ecoptroller() != EToken(eTokenBorrowed).ecoptroller()) {
            return uint(Error.ECOPTROLLER_MISMATCH);
        }

        // Keep the flywheel moving
        updateEcopSupplyIndex(eTokenCollateral);
        distributeSupplierEcop(eTokenCollateral, borrower);
        distributeSupplierEcop(eTokenCollateral, liquidator);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates seize and reverts on rejection. May emit logs.
     * @param eTokenCollateral Asset which was used as collateral and will be seized
     * @param eTokenBorrowed Asset which was borrowed by the borrower
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param seizeTokens The number of collateral tokens to seize
     */
    function seizeVerify(
        address eTokenCollateral,
        address eTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens) external override{
        // Shh - currently unused
        eTokenCollateral;
        eTokenBorrowed;
        liquidator;
        borrower;
        seizeTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the account should be allowed to transfer tokens in the given market
     * @param eToken The market to verify the transfer against
     * @param src The account which sources the tokens
     * @param dst The account which receives the tokens
     * @param transferTokens The number of eTokens to transfer
     * @return 0 if the transfer is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function transferAllowed(address eToken, address src, address dst, uint transferTokens) external override returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!transferGuardianPaused, "transfer is paused");

        // Currently the only consideration is whether or not
        //  the src is allowed to redeem this many tokens
        uint allowed = redeemAllowedInternal(eToken, src, transferTokens);
        if (allowed != uint(Error.NO_ERROR)) {
            return allowed;
        }

        // Keep the flywheel moving
        updateEcopSupplyIndex(eToken);
        distributeSupplierEcop(eToken, src);
        distributeSupplierEcop(eToken, dst);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates transfer and reverts on rejection. May emit logs.
     * @param eToken Asset being transferred
     * @param src The account which sources the tokens
     * @param dst The account which receives the tokens
     * @param transferTokens The number of eTokens to transfer
     */
    function transferVerify(address eToken, address src, address dst, uint transferTokens) external override{
        // Shh - currently unused
        eToken;
        src;
        dst;
        transferTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /*** Liquidity/Liquidation Calculations ***/

    /**
     * @dev Local vars for avoiding stack-depth limits in calculating account liquidity.
     *  Note that `eTokenBalance` is the number of eTokens the account owns in the market,
     *  whereas `borrowBalance` is the amount of underlying that the account has borrowed.
     */
    struct AccountLiquidityLocalVars {
        uint sumCollateral;
        uint sumBorrowPlusEffects;
        uint eTokenBalance;
        uint borrowBalance;
        uint exchangeRateMantissa;
        uint oraclePriceMantissa;
        Exp collateralFactor;
        Exp exchangeRate;
        Exp oraclePrice;
        Exp tokensToDenom;
    }

    /**
     * @notice Determine the current account liquidity wrt collateral requirements
     * @return (possible error code (semi-opaque),
                account liquidity in excess of collateral requirements,
     *          account shortfall below collateral requirements)
     */
    function getAccountLiquidity(address account) external returns (uint, uint, uint) {
        (Error err, uint liquidity, uint shortfall) = getHypotheticalAccountLiquidityInternal(account, EToken(address(0)), 0, 0);

        return (uint(err), liquidity, shortfall);
    }

    /**
     * @notice Determine the current account liquidity wrt collateral requirements
     * @return (possible error code,
                account liquidity in excess of collateral requirements,
     *          account shortfall below collateral requirements)
     */
    function getAccountLiquidityInternal(address account) internal returns (Error, uint, uint) {
        return getHypotheticalAccountLiquidityInternal(account, EToken(address(0)), 0, 0);
    }

    /**
     * @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed
     * @param eTokenModify The market to hypothetically redeem/borrow in
     * @param account The account to determine liquidity for
     * @param redeemTokens The number of tokens to hypothetically redeem
     * @param borrowAmount The amount of underlying to hypothetically borrow
     * @return (possible error code (semi-opaque),
                hypothetical account liquidity in excess of collateral requirements,
     *          hypothetical account shortfall below collateral requirements)
     */
    function getHypotheticalAccountLiquidity(
        address account,
        address eTokenModify,
        uint redeemTokens,
        uint borrowAmount) external returns (uint, uint, uint) {
        (Error err, uint liquidity, uint shortfall) = getHypotheticalAccountLiquidityInternal(account, EToken(eTokenModify), redeemTokens, borrowAmount);
        return (uint(err), liquidity, shortfall);
    }

    /**
     * @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed
     * @param eTokenModify The market to hypothetically redeem/borrow in
     * @param account The account to determine liquidity for
     * @param redeemTokens The number of tokens to hypothetically redeem
     * @param borrowAmount The amount of underlying to hypothetically borrow
     * @dev Note that we calculate the exchangeRateStored for each collateral eToken using stored data,
     *  without calculating accumulated interest.
     * @return (possible error code,
                hypothetical account liquidity in excess of collateral requirements,
     *          hypothetical account shortfall below collateral requirements)
     */
    function getHypotheticalAccountLiquidityInternal(
        address account,
        EToken eTokenModify,
        uint redeemTokens,
        uint borrowAmount) internal returns (Error, uint, uint) {

        AccountLiquidityLocalVars memory vars; // Holds all our calculation results
        uint oErr;

        // For each asset the account is in
        EToken[] memory assets = accountAssets[account];
        for (uint i = 0; i < assets.length; i++) {
            EToken asset = assets[i];

            // Read the balances and exchange rate from the eToken
            (oErr, vars.eTokenBalance, vars.borrowBalance, vars.exchangeRateMantissa) = asset.getAccountSnapshot(account);
            if (oErr != 0) { // semi-opaque error code, we assume NO_ERROR == 0 is invariant between upgrades
                return (Error.SNAPSHOT_ERROR, 0, 0);
            }
            vars.collateralFactor = Exp({mantissa: markets[address(asset)].collateralFactorMantissa});
            vars.exchangeRate = Exp({mantissa: vars.exchangeRateMantissa});

            // Get the normalized price of the asset
            vars.oraclePriceMantissa = oracle.getUnderlyingPrice(asset);
            if (vars.oraclePriceMantissa == 0) {
                return (Error.PRICE_ERROR, 0, 0);
            }
            vars.oraclePrice = Exp({mantissa: vars.oraclePriceMantissa});

            // Pre-ecopute a conversion factor from tokens -> ether (normalized price value)
            vars.tokensToDenom = mul_(mul_(vars.collateralFactor, vars.exchangeRate), vars.oraclePrice);

            // sumCollateral += tokensToDenom * eTokenBalance
            vars.sumCollateral = mul_ScalarTruncateAddUInt(vars.tokensToDenom, vars.eTokenBalance, vars.sumCollateral);

            // sumBorrowPlusEffects += oraclePrice * borrowBalance
            vars.sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(vars.oraclePrice, vars.borrowBalance, vars.sumBorrowPlusEffects);

            // Calculate effects of interacting with eTokenModify
            if (asset == eTokenModify) {
                // redeem effect
                // sumBorrowPlusEffects += tokensToDenom * redeemTokens
                vars.sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(vars.tokensToDenom, redeemTokens, vars.sumBorrowPlusEffects);

                // borrow effect
                // sumBorrowPlusEffects += oraclePrice * borrowAmount
                vars.sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(vars.oraclePrice, borrowAmount, vars.sumBorrowPlusEffects);
            }
        }

        // These are safe, as the underflow condition is checked first
        if (vars.sumCollateral > vars.sumBorrowPlusEffects) {
            return (Error.NO_ERROR, vars.sumCollateral - vars.sumBorrowPlusEffects, 0);
        } else {
            return (Error.NO_ERROR, 0, vars.sumBorrowPlusEffects - vars.sumCollateral);
        }
    }

    /**
     * @notice Calculate number of tokens of collateral asset to seize given an underlying amount
     * @dev Used in liquidation (called in eToken.liquidateBorrowFresh)
     * @param eTokenBorrowed The address of the borrowed eToken
     * @param eTokenCollateral The address of the collateral eToken
     * @param actualRepayAmount The amount of eTokenBorrowed underlying to convert into eTokenCollateral tokens
     * @return (errorCode, number of eTokenCollateral tokens to be seized in a liquidation)
     */
    function liquidateCalculateSeizeTokens(address eTokenBorrowed, address eTokenCollateral, uint actualRepayAmount) external override returns (uint, uint) {
        /* Read oracle prices for borrowed and collateral markets */
        uint priceBorrowedMantissa = oracle.getUnderlyingPrice(EToken(eTokenBorrowed));
        uint priceCollateralMantissa = oracle.getUnderlyingPrice(EToken(eTokenCollateral));
        if (priceBorrowedMantissa == 0 || priceCollateralMantissa == 0) {
            return (uint(Error.PRICE_ERROR), 0);
        }

        /*
         * Get the exchange rate and calculate the number of collateral tokens to seize:
         *  seizeAmount = actualRepayAmount * liquidationIncentive * priceBorrowed / priceCollateral
         *  seizeTokens = seizeAmount / exchangeRate
         *   = actualRepayAmount * (liquidationIncentive * priceBorrowed) / (priceCollateral * exchangeRate)
         */
        uint exchangeRateMantissa = EToken(eTokenCollateral).exchangeRateStored(); // Note: reverts on error
        uint seizeTokens;
        Exp memory numerator;
        Exp memory denominator;
        Exp memory ratio;

        numerator = mul_(Exp({mantissa: liquidationIncentiveMantissa}), Exp({mantissa: priceBorrowedMantissa}));
        denominator = mul_(Exp({mantissa: priceCollateralMantissa}), Exp({mantissa: exchangeRateMantissa}));
        ratio = div_(numerator, denominator);

        seizeTokens = mul_ScalarTruncate(ratio, actualRepayAmount);

        return (uint(Error.NO_ERROR), seizeTokens);
    }

    /*** Admin Functions ***/

    /**
      * @notice Sets a new price oracle for the ecoptroller
      * @dev Admin function to set a new price oracle
      * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
      */
    function _setPriceOracle(PriceOracle newOracle) external returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_PRICE_ORACLE_OWNER_CHECK);
        }

        // Track the old oracle for the ecoptroller
        PriceOracle oldOracle = oracle;

        // Set ecoptroller's oracle to newOracle
        oracle = newOracle;

        // Emit NewPriceOracle(oldOracle, newOracle)
        emit NewPriceOracle(oldOracle, newOracle);

        return uint(Error.NO_ERROR);
    }

    /**
      * @notice Sets the closeFactor used when liquidating borrows
      * @dev Admin function to set closeFactor
      * @param newCloseFactorMantissa New close factor, scaled by 1e18
      * @return uint 0=success, otherwise a failure
      */
    function _setCloseFactor(uint newCloseFactorMantissa) external returns (uint) {
        // Check caller is admin
    	require(msg.sender == admin, "only admin can set close factor");

        uint oldCloseFactorMantissa = closeFactorMantissa;
        closeFactorMantissa = newCloseFactorMantissa;
        emit NewCloseFactor(oldCloseFactorMantissa, closeFactorMantissa);

        return uint(Error.NO_ERROR);
    }

    /**
      * @notice Sets the collateralFactor for a market
      * @dev Admin function to set per-market collateralFactor
      * @param eToken The market to set the factor on
      * @param newCollateralFactorMantissa The new collateral factor, scaled by 1e18
      * @return uint 0=success, otherwise a failure. (See ErrorReporter for details)
      */
    function _setCollateralFactor(EToken eToken, uint newCollateralFactorMantissa) external returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_COLLATERAL_FACTOR_OWNER_CHECK);
        }

        // Verify market is listed
        Market storage market = markets[address(eToken)];
        if (!market.isListed) {
            return fail(Error.MARKET_NOT_LISTED, FailureInfo.SET_COLLATERAL_FACTOR_NO_EXISTS);
        }

        Exp memory newCollateralFactorExp = Exp({mantissa: newCollateralFactorMantissa});

        // Check collateral factor <= 0.9
        Exp memory highLimit = Exp({mantissa: collateralFactorMaxMantissa});
        if (lessThanExp(highLimit, newCollateralFactorExp)) {
            return fail(Error.INVALID_COLLATERAL_FACTOR, FailureInfo.SET_COLLATERAL_FACTOR_VALIDATION);
        }

        // If collateral factor != 0, fail if price == 0
        if (newCollateralFactorMantissa != 0 && oracle.getUnderlyingPrice(eToken) == 0) {
            return fail(Error.PRICE_ERROR, FailureInfo.SET_COLLATERAL_FACTOR_WITHOUT_PRICE);
        }

        // Set market's collateral factor to new collateral factor, remember old value
        uint oldCollateralFactorMantissa = market.collateralFactorMantissa;
        market.collateralFactorMantissa = newCollateralFactorMantissa;

        // Emit event with asset, old collateral factor, and new collateral factor
        emit NewCollateralFactor(eToken, oldCollateralFactorMantissa, newCollateralFactorMantissa);

        return uint(Error.NO_ERROR);
    }

    /**
      * @notice Sets liquidationIncentive
      * @dev Admin function to set liquidationIncentive
      * @param newLiquidationIncentiveMantissa New liquidationIncentive scaled by 1e18
      * @return uint 0=success, otherwise a failure. (See ErrorReporter for details)
      */
    function _setLiquidationIncentive(uint newLiquidationIncentiveMantissa) external returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_LIQUIDATION_INCENTIVE_OWNER_CHECK);
        }

        // Save current value for use in log
        uint oldLiquidationIncentiveMantissa = liquidationIncentiveMantissa;

        // Set liquidation incentive to new incentive
        liquidationIncentiveMantissa = newLiquidationIncentiveMantissa;

        // Emit event with old incentive, new incentive
        emit NewLiquidationIncentive(oldLiquidationIncentiveMantissa, newLiquidationIncentiveMantissa);

        return uint(Error.NO_ERROR);
    }

    /**
      * @notice Add the market to the markets mapping and set it as listed
      * @dev Admin function to set isListed and add support for the market
      * @param eToken The address of the market (token) to list
      * @return uint 0=success, otherwise a failure. (See enum Error for details)
      */
    function _supportMarket(EToken eToken) external returns (uint) {
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SUPPORT_MARKET_OWNER_CHECK);
        }

        if (markets[address(eToken)].isListed) {
            return fail(Error.MARKET_ALREADY_LISTED, FailureInfo.SUPPORT_MARKET_EXISTS);
        }

        eToken.isEToken(); // Sanity check to make sure its really a EToken

        // Note that isEcoped is not in active use anymore
       // markets[address(eToken)] = Market({isListed: true, isEcoped: false, collateralFactorMantissa: 0});
        Market storage market = markets[address(eToken)];
        market.isListed = true;
        market.isEcoped = false;
        market.collateralFactorMantissa = 0;

        _addMarketInternal(address(eToken));

        emit MarketListed(eToken);

        return uint(Error.NO_ERROR);
    }

    function _addMarketInternal(address eToken) internal {
        for (uint i = 0; i < allMarkets.length; i ++) {
            require(allMarkets[i] != EToken(eToken), "market already added");
        }
        allMarkets.push(EToken(eToken));
    }


    /**
      * @notice Set the given borrow caps for the given eToken markets. Borrowing that brings total borrows to or above borrow cap will revert.
      * @dev Admin or borrowCapGuardian function to set the borrow caps. A borrow cap of 0 corresponds to unlimited borrowing.
      * @param eTokens The addresses of the markets (tokens) to change the borrow caps for
      * @param newBorrowCaps The new borrow cap values in underlying to be set. A value of 0 corresponds to unlimited borrowing.
      */
    function _setMarketBorrowCaps(EToken[] calldata eTokens, uint[] calldata newBorrowCaps) external {
    	require(msg.sender == admin || msg.sender == borrowCapGuardian, "only admin or borrow cap guardian can set borrow caps"); 

        uint numMarkets = eTokens.length;
        uint numBorrowCaps = newBorrowCaps.length;

        require(numMarkets != 0 && numMarkets == numBorrowCaps, "invalid input");

        for(uint i = 0; i < numMarkets; i++) {
            borrowCaps[address(eTokens[i])] = newBorrowCaps[i];
            emit NewBorrowCap(eTokens[i], newBorrowCaps[i]);
        }
    }

    /**
     * @notice Admin function to change the Borrow Cap Guardian
     * @param newBorrowCapGuardian The address of the new Borrow Cap Guardian
     */
    function _setBorrowCapGuardian(address newBorrowCapGuardian) external {
        require(msg.sender == admin, "only admin can set borrow cap guardian");

        // Save current value for inclusion in log
        address oldBorrowCapGuardian = borrowCapGuardian;

        // Store borrowCapGuardian with value newBorrowCapGuardian
        borrowCapGuardian = newBorrowCapGuardian;

        // Emit NewBorrowCapGuardian(OldBorrowCapGuardian, NewBorrowCapGuardian)
        emit NewBorrowCapGuardian(oldBorrowCapGuardian, newBorrowCapGuardian);
    }

    /**
     * @notice Admin function to change the Pause Guardian
     * @param newPauseGuardian The address of the new Pause Guardian
     * @return uint 0=success, otherwise a failure. (See enum Error for details)
     */
    function _setPauseGuardian(address newPauseGuardian) external returns (uint) {
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_PAUSE_GUARDIAN_OWNER_CHECK);
        }

        // Save current value for inclusion in log
        address oldPauseGuardian = pauseGuardian;

        // Store pauseGuardian with value newPauseGuardian
        pauseGuardian = newPauseGuardian;

        // Emit NewPauseGuardian(OldPauseGuardian, NewPauseGuardian)
        emit NewPauseGuardian(oldPauseGuardian, pauseGuardian);

        return uint(Error.NO_ERROR);
    }

    function _setMintPaused(EToken eToken, bool state) external returns (bool) {
        require(markets[address(eToken)].isListed, "cannot pause a market that is not listed");
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian and admin can pause");
        require(msg.sender == admin || state == true, "only admin can unpause");

        mintGuardianPaused[address(eToken)] = state;
        emit ActionPaused(eToken, "Mint", state);
        return state;
    }

    function _setBorrowPaused(EToken eToken, bool state) external returns (bool) {
        require(markets[address(eToken)].isListed, "cannot pause a market that is not listed");
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian and admin can pause");
        require(msg.sender == admin || state == true, "only admin can unpause");

        borrowGuardianPaused[address(eToken)] = state;
        emit ActionPaused(eToken, "Borrow", state);
        return state;
    }

    function _setTransferPaused(bool state) external returns (bool) {
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian and admin can pause");
        require(msg.sender == admin || state == true, "only admin can unpause");

        transferGuardianPaused = state;
        emit ActionPaused("Transfer", state);
        return state;
    }

    function _setSeizePaused(bool state) external returns (bool) {
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian and admin can pause");
        require(msg.sender == admin || state == true, "only admin can unpause");

        seizeGuardianPaused = state;
        emit ActionPaused("Seize", state);
        return state;
    }

    function _become(Unitroller unitroller) external {
        require(msg.sender == unitroller.admin(), "only unitroller admin can change brains");
        require(unitroller._acceptImplementation() == 0, "change not authorized");
    }

    /**
     * @notice Checks caller is admin, or this contract is becoming the new implementation
     */
    function adminOrInitializing() internal view returns (bool) {
        return msg.sender == admin || msg.sender == ecoptrollerImplementation;
    }

    /*** Ecop Distribution ***/

    /**
     * @notice Set ECOP speed for a single market
     * @param eToken The market whose ECOP speed to update
     * @param ecopSpeed New ECOP speed for market
     */
    function setEcopSpeedInternal(EToken eToken, uint ecopSpeed) internal {
        uint currentEcopSpeed = ecopSpeeds[address(eToken)];
        if (currentEcopSpeed != 0) {
            // note that ECOP speed could be set to 0 to halt liquidity rewards for a market
            Exp memory borrowIndex = Exp({mantissa: eToken.borrowIndex()});
            updateEcopSupplyIndex(address(eToken));
            updateEcopBorrowIndex(address(eToken), borrowIndex);
        } else if (ecopSpeed != 0) {
            // Add the ECOP market
            Market storage market = markets[address(eToken)];
            require(market.isListed == true, "ecop market is not listed");

            if (ecopSupplyState[address(eToken)].index == 0 && ecopSupplyState[address(eToken)].block == 0) {
                ecopSupplyState[address(eToken)] = EcopMarketState({
                    index: ecopInitialIndex,
                    block: safe32(getBlockNumber(), "block number exceeds 32 bits")
                });
            }

            if (ecopBorrowState[address(eToken)].index == 0 && ecopBorrowState[address(eToken)].block == 0) {
                ecopBorrowState[address(eToken)] = EcopMarketState({
                    index: ecopInitialIndex,
                    block: safe32(getBlockNumber(), "block number exceeds 32 bits")
                });
            }
        }

        if (currentEcopSpeed != ecopSpeed) {
            ecopSpeeds[address(eToken)] = ecopSpeed;
            emit EcopSpeedUpdated(eToken, ecopSpeed);
        }
    }

    /**
     * @notice Accrue ECOP to the market by updating the supply index
     * @param eToken The market whose supply index to update
     */
    function updateEcopSupplyIndex(address eToken) internal {
        EcopMarketState storage supplyState = ecopSupplyState[eToken];
        uint supplySpeed = ecopSpeeds[eToken];
        uint blockNumber = getBlockNumber();
        uint deltaBlocks = sub_(blockNumber, uint(supplyState.block));
        if (deltaBlocks > 0 && supplySpeed > 0) {
            uint supplyTokens = EToken(eToken).totalSupply();
            uint ecopAccrued = mul_(deltaBlocks, supplySpeed);
            Double memory ratio = supplyTokens > 0 ? fraction(ecopAccrued, supplyTokens) : Double({mantissa: 0});
            Double memory index = add_(Double({mantissa: supplyState.index}), ratio);
            ecopSupplyState[eToken] = EcopMarketState({
                index: safe224(index.mantissa, "new index exceeds 224 bits"),
                block: safe32(blockNumber, "block number exceeds 32 bits")
            });
        } else if (deltaBlocks > 0) {
            supplyState.block = safe32(blockNumber, "block number exceeds 32 bits");
        }
    }

    /**
     * @notice Accrue ECOP to the market by updating the borrow index
     * @param eToken The market whose borrow index to update
     */
    function updateEcopBorrowIndex(address eToken, Exp memory marketBorrowIndex) internal {
        EcopMarketState storage borrowState = ecopBorrowState[eToken];
        uint borrowSpeed = ecopSpeeds[eToken];
        uint blockNumber = getBlockNumber();
        uint deltaBlocks = sub_(blockNumber, uint(borrowState.block));
        if (deltaBlocks > 0 && borrowSpeed > 0) {
            uint borrowAmount = div_(EToken(eToken).totalBorrows(), marketBorrowIndex);
            uint ecopAccrued = mul_(deltaBlocks, borrowSpeed);
            Double memory ratio = borrowAmount > 0 ? fraction(ecopAccrued, borrowAmount) : Double({mantissa: 0});
            Double memory index = add_(Double({mantissa: borrowState.index}), ratio);
            ecopBorrowState[eToken] = EcopMarketState({
                index: safe224(index.mantissa, "new index exceeds 224 bits"),
                block: safe32(blockNumber, "block number exceeds 32 bits")
            });
        } else if (deltaBlocks > 0) {
            borrowState.block = safe32(blockNumber, "block number exceeds 32 bits");
        }
    }

    /**
     * @notice Calculate ECOP accrued by a supplier and possibly transfer it to them
     * @param eToken The market in which the supplier is interacting
     * @param supplier The address of the supplier to distribute ECOP to
     */
    function distributeSupplierEcop(address eToken, address supplier) internal {
        EcopMarketState storage supplyState = ecopSupplyState[eToken];
        Double memory supplyIndex = Double({mantissa: supplyState.index});
        Double memory supplierIndex = Double({mantissa: ecopSupplierIndex[eToken][supplier]});
        ecopSupplierIndex[eToken][supplier] = supplyIndex.mantissa;

        if (supplierIndex.mantissa == 0 && supplyIndex.mantissa > 0) {
            supplierIndex.mantissa = ecopInitialIndex;
        }

        Double memory deltaIndex = sub_(supplyIndex, supplierIndex);
        uint supplierTokens = EToken(eToken).balanceOf(supplier);
        uint supplierDelta = mul_(supplierTokens, deltaIndex);
        uint supplierAccrued = add_(ecopAccrued[supplier], supplierDelta);
        ecopAccrued[supplier] = supplierAccrued;
        emit DistributedSupplierEcop(EToken(eToken), supplier, supplierDelta, supplyIndex.mantissa);
    }

    /**
     * @notice Calculate ECOP accrued by a borrower and possibly transfer it to them
     * @dev Borrowers will not begin to accrue until after the first interaction with the protocol.
     * @param eToken The market in which the borrower is interacting
     * @param borrower The address of the borrower to distribute ECOP to
     */
    function distributeBorrowerEcop(address eToken, address borrower, Exp memory marketBorrowIndex) internal {
        EcopMarketState storage borrowState = ecopBorrowState[eToken];
        Double memory borrowIndex = Double({mantissa: borrowState.index});
        Double memory borrowerIndex = Double({mantissa: ecopBorrowerIndex[eToken][borrower]});
        ecopBorrowerIndex[eToken][borrower] = borrowIndex.mantissa;

        if (borrowerIndex.mantissa > 0) {
            Double memory deltaIndex = sub_(borrowIndex, borrowerIndex);
            uint borrowerAmount = div_(EToken(eToken).borrowBalanceStored(borrower), marketBorrowIndex);
            uint borrowerDelta = mul_(borrowerAmount, deltaIndex);
            uint borrowerAccrued = add_(ecopAccrued[borrower], borrowerDelta);
            ecopAccrued[borrower] = borrowerAccrued;
            emit DistributedBorrowerEcop(EToken(eToken), borrower, borrowerDelta, borrowIndex.mantissa);
        }
    }

    /**
     * @notice Calculate additional accrued ECOP for a contributor since last accrual
     * @param contributor The address to calculate contributor rewards for
     */
    function updateContributorRewards(address contributor) internal {
        uint ecopSpeed = ecopContributorSpeeds[contributor];
        uint blockNumber = getBlockNumber();
        uint deltaBlocks = sub_(blockNumber, lastContributorBlock[contributor]);
        if (deltaBlocks > 0 && ecopSpeed > 0) {
            uint newAccrued = mul_(deltaBlocks, ecopSpeed);
            uint contributorAccrued = add_(ecopAccrued[contributor], newAccrued);

            ecopAccrued[contributor] = contributorAccrued;
            lastContributorBlock[contributor] = blockNumber;
        }
    }

    /**
     * @notice Claim all the ecop accrued by holder in all markets
     * @param holder The address to claim ECOP for
     */
    function claimEcop(address holder) internal {
        return claimEcop(holder, allMarkets);
    }

    /**
     * @notice Claim all the ecop accrued by holder in the specified markets
     * @param holder The address to claim ECOP for
     * @param eTokens The list of markets to claim ECOP in
     */
    function claimEcop(address holder, EToken[] memory eTokens) internal {
        address[] memory holders = new address[](1);
        holders[0] = holder;
        claimEcop(holders, eTokens, true, true);
    }

    /**
     * @notice Claim all ecop accrued by the holders
     * @param holders The addresses to claim ECOP for
     * @param eTokens The list of markets to claim ECOP in
     * @param borrowers Whether or not to claim ECOP earned by borrowing
     * @param suppliers Whether or not to claim ECOP earned by supplying
     */
    function claimEcop(address[] memory holders, EToken[] memory eTokens, bool borrowers, bool suppliers) internal {
        for (uint i = 0; i < eTokens.length; i++) {
            EToken eToken = eTokens[i];
            require(markets[address(eToken)].isListed, "market must be listed");
            if (borrowers == true) {
                Exp memory borrowIndex = Exp({mantissa: eToken.borrowIndex()});
                updateEcopBorrowIndex(address(eToken), borrowIndex);
                for (uint j = 0; j < holders.length; j++) {
                    distributeBorrowerEcop(address(eToken), holders[j], borrowIndex);
                }
            }
            if (suppliers == true) {
                updateEcopSupplyIndex(address(eToken));
                for (uint j = 0; j < holders.length; j++) {
                    distributeSupplierEcop(address(eToken), holders[j]);
                }
            }
        }
        for (uint j = 0; j < holders.length; j++) {
            ecopAccrued[holders[j]] = grantEcopInternal(holders[j], ecopAccrued[holders[j]]);
        }
    }

    /**
     * @notice Transfer ECOP to the user
     * @dev Note: If there is not enough ECOP, we do not perform the transfer all.
     * @param user The address of the user to transfer ECOP to
     * @param amount The amount of ECOP to (possibly) transfer
     * @return The amount of ECOP which was NOT transferred to the user
     */
    function grantEcopInternal(address user, uint amount) internal returns (uint) {
        Ecop ecop = Ecop(getEcopAddress());
        uint ecopRemaining = ecop.balanceOf(address(this));
        if (amount > 0 && amount <= ecopRemaining) {
            ecop.transfer(user, amount);
            return 0;
        }
        return amount;
    }

    /*** Ecop Distribution Admin ***/

    /**
     * @notice Transfer ECOP to the recipient
     * @dev Note: If there is not enough ECOP, we do not perform the transfer all.
     * @param recipient The address of the recipient to transfer ECOP to
     * @param amount The amount of ECOP to (possibly) transfer
     */
    function _grantEcop(address recipient, uint amount) external {
        require(adminOrInitializing(), "only admin can grant ecop");
        uint amountLeft = grantEcopInternal(recipient, amount);
        require(amountLeft == 0, "insufficient ecop for grant");
        emit EcopGranted(recipient, amount);
    }

    /**
     * @notice Set ECOP speed for a single market
     * @param eToken The market whose ECOP speed to update
     * @param ecopSpeed New ECOP speed for market
     */
    function _setEcopSpeed(EToken eToken, uint ecopSpeed) external {
        require(adminOrInitializing(), "only admin can set ecop speed");
        setEcopSpeedInternal(eToken, ecopSpeed);
    }

    /**
     * @notice Set ECOP speed for a single contributor
     * @param contributor The contributor whose ECOP speed to update
     * @param ecopSpeed New ECOP speed for contributor
     */
    function _setContributorEcopSpeed(address contributor, uint ecopSpeed) external {
        require(adminOrInitializing(), "only admin can set ecop speed");

        // note that ECOP speed could be set to 0 to halt liquidity rewards for a contributor
        updateContributorRewards(contributor);
        if (ecopSpeed == 0) {
            // release storage
            delete lastContributorBlock[contributor];
        } else {
            lastContributorBlock[contributor] = getBlockNumber();
        }
        ecopContributorSpeeds[contributor] = ecopSpeed;

        emit ContributorEcopSpeedUpdated(contributor, ecopSpeed);
    }

    /**
     * @notice Return all of the markets
     * @dev The automatic getter may be used to access an individual market.
     * @return The list of market addresses
     */
    function getAllMarkets() external view returns (EToken[] memory) {
        return allMarkets;
    }

    /**
     * @notice Returns true if the given eToken market has been deprecated
     * @dev All borrows in a deprecated eToken market can be immediately liquidated
     * @param eToken The market to check if deprecated
     */
    function isDeprecated(EToken eToken) internal view returns (bool) {
        return
            markets[address(eToken)].collateralFactorMantissa == 0 && 
            borrowGuardianPaused[address(eToken)] == true && 
            eToken.reserveFactorMantissa() == 1e18
        ;
    }

    function getBlockNumber() internal view returns (uint) {
        return block.number;
    }

    /**
     * @notice Return the address of the ECOP token
     * @return The address of ECOP
     */
    function getEcopAddress() internal pure returns (address) {
        return 0x96a16178edAFF58736567Cfcaff570C06617F0Fd;
    }
}
