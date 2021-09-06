//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "./IERC20.sol";

/**
 * Exempt Surge Interface
 */
interface INativeSurge is IERC20 {
    function sell(uint256 amount) external;
    function getUnderlyingAsset() external returns(address);
}
