// SPDX-License-Identifier: MIT

pragma solidity >=0.6.2;

import "./CErc20.sol";

/**
 * @title ECOP's CErc20Immutable Contract
 * @notice ETokens which wrap an EIP-20 underlying and are immutable
 * @author ECOP
 */
contract CErc20Immutable is CErc20 {
    /**
     * @notice Construct a new money market
     * @param underlying_ The address of the underlying asset
     * @param ecoptroller_ The address of the Ecoptroller
     * @param interestRateModel_ The address of the interest rate model
     * @param initialExchangeRateMantissa_ The initial exchange rate, scaled by 1e18
     * @param name_ ERC-20 name of this token
     * @param symbol_ ERC-20 symbol of this token
     * @param decimals_ ERC-20 decimal precision of this token
     * @param admin_ Address of the administrator of this token
     */
    constructor(address underlying_,
                EcoptrollerInterface ecoptroller_,
                InterestRateModel interestRateModel_,
                uint initialExchangeRateMantissa_,
                string memory name_,
                string memory symbol_,
                uint8 decimals_,
                address payable admin_) {
        // Creator of the contract is admin during initialization
        admin = payable(msg.sender);

        // Initialize the market
        initialize(underlying_, ecoptroller_, interestRateModel_, initialExchangeRateMantissa_, name_, symbol_, decimals_);

        // Set the proper admin now that initialization is done
        admin = admin_;
    }
}
