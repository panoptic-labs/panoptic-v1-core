// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

// Interfaces
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
// Libraries
import {PanopticMath} from "@libraries/PanopticMath.sol";

/// @title InteractionHelper - contains helper functions for select external interactions.
/// @notice This library contains helper functions for select external interactions.
/// @dev Generally employed when there is a need to save or reuse bytecode size
/// on a core contract.
/// @author Axicon Labs Limited
library InteractionHelper {
    /// @notice Computes the name of a CollateralTracker based on the token composition and fee of the underlying Uniswap Pool.
    /// @dev Some tokens do not have proper symbols so error handling is required - this logic takes up significant bytecode size, which is why it is in a library.
    /// @param currency0 The currency0 of the Uniswap Pool
    /// @param currency1 The currency1 of the Uniswap Pool
    /// @param isToken0 Whether the collateral token computing the name is for currency0 or currency1
    /// @param fee The fee of the Uniswap pool in hundredths of basis points
    /// @param prefix A constant string appended to the start of the token name
    /// @return The complete name of the collateral token calling this function
    function computeName(
        address currency0,
        address currency1,
        bool isToken0,
        uint24 fee,
        string memory prefix
    ) external view returns (string memory) {
        string memory symbol0 = PanopticMath.safeERC20Symbol(currency0);
        string memory symbol1 = PanopticMath.safeERC20Symbol(currency1);

        unchecked {
            return
                string.concat(
                    prefix,
                    " ",
                    isToken0 ? symbol0 : symbol1,
                    " LP on ",
                    symbol0,
                    "/",
                    symbol1,
                    " ",
                    PanopticMath.uniswapFeeToString(fee)
                );
        }
    }

    /// @notice Returns collateral token symbol as `prefix` + `underlying asset symbol`.
    /// @param token The address of the underlying asset used to compute the symbol (`address(0)` = native asset)
    /// @param prefix A constant string prepended to the symbol of the underlying asset to create the final symbol
    /// @return The symbol of the collateral token
    function computeSymbol(
        address token,
        string memory prefix
    ) external view returns (string memory) {
        return string.concat(prefix, PanopticMath.safeERC20Symbol(token));
    }

    /// @notice Returns decimals of underlying asset (0 if not present).
    /// @param token The address of the underlying asset used to compute the decimals (`address(0)` = native asset)
    /// @return The decimals of the token
    function computeDecimals(address token) external view returns (uint8) {
        // not guaranteed that token supports metadata extension
        // so we need to let call fail and return placeholder if not
        try IERC20Metadata(token).decimals() returns (uint8 _decimals) {
            return _decimals;
        } catch {
            return 0;
        }
    }
}
