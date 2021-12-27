// SPDX-License-Identifier: MIT

pragma solidity >=0.6.2;

import "./EToken.sol";

abstract contract PriceOracle {
    /// @notice Indicator that this is a PriceOracle contract (for inspection)
    bool public constant isPriceOracle = true;

    /**
      * @notice Get the underlying price of a eToken asset
      * @param eToken The eToken to get the underlying price of
      * @return The underlying asset price mantissa (scaled by 1e18).
      *  Zero means the price is unavailable.
      */
    function getUnderlyingPrice(EToken eToken) external  virtual returns (uint);
}
