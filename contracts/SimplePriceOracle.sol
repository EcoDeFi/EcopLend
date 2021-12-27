// SPDX-License-Identifier: MIT

pragma solidity >=0.6.2;

import "./PriceOracle.sol";
import "./CErc20.sol";

contract SimplePriceOracle is PriceOracle {
    mapping(address => uint) prices;
    event PricePosted(address asset, uint previousPriceMantissa, uint requestedPriceMantissa, uint newPriceMantissa);

    function getUnderlyingPrice(EToken eToken) external view override returns (uint) {
        if (compareStrings(eToken.symbol(), "eBNB")) {
            return 1e18;
        } else {
            return prices[address(CErc20(address(eToken)).underlying())];
        }
    }

    function setUnderlyingPrice(EToken eToken, uint underlyingPriceMantissa) external {
        address asset = address(CErc20(address(eToken)).underlying());
        emit PricePosted(asset, prices[asset], underlyingPriceMantissa, underlyingPriceMantissa);
        prices[asset] = underlyingPriceMantissa;
    }

    function setDirectPrice(address asset, uint price) external {
        emit PricePosted(asset, prices[asset], price, price);
        prices[asset] = price;
    }

    // v1 price oracle interface for use as backing of proxy
    function assetPrices(address asset) external view returns (uint) {
        return prices[asset];
    }

    function compareStrings(string memory a, string memory b) internal pure returns (bool) {
        return (keccak256(abi.encodePacked((a))) == keccak256(abi.encodePacked((b))));
    }
}
