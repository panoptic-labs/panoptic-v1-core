// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

// OpenZeppelin libraries
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

/// @title Minimalist ERC1155 implementation without metadata.
/// @author Axicon Labs Limited
/// @author Modified from Solmate (https://github.com/transmissions11/solmate/blob/v7/src/tokens/ERC1155.sol)
abstract contract ERC1155 {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when only a single token is transferred
    /// @param operator the user who initiated the transfer
    /// @param from the user who sent the tokens
    /// @param to the user who received the tokens
    /// @param id the ERC1155 token id
    /// @param amount the amount of tokens transferred
    event TransferSingle(
        address indexed operator,
        address indexed from,
        address indexed to,
        uint256 id,
        uint256 amount
    );

    /// @notice Emitted when multiple tokens are transferred from one user to another
    /// @param operator the user who initiated the transfer
    /// @param from the user who sent the tokens
    /// @param to the user who received the tokens
    /// @param ids the ERC1155 token ids
    /// @param amounts the amounts of tokens transferred
    event TransferBatch(
        address indexed operator,
        address indexed from,
        address indexed to,
        uint256[] ids,
        uint256[] amounts
    );

    /// @notice Emitted when an operator is approved to transfer all tokens on behalf of a user
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    // emitted when a user attempts to transfer tokens they do not own nor are approved to transfer
    error NotAuthorized();

    // emitted when an attempt is made to initiate a transfer to a recipient that fails to signal support for ERC1155
    error UnsafeRecipient();

    /*//////////////////////////////////////////////////////////////
                             ERC1155 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Token balances for each user
    /// @dev indexed by user, then by token id
    mapping(address account => mapping(uint256 tokenId => uint256 balance)) public balanceOf;

    /// @notice Approved addresses for each user
    /// @dev indexed by user, then by operator
    /// @dev operator is approved to transfer all tokens on behalf of user
    mapping(address owner => mapping(address operator => bool approvedForAll))
        public isApprovedForAll;

    /*//////////////////////////////////////////////////////////////
                              ERC1155 LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Approve or revoke approval for an operator to transfer all tokens on behalf of the caller
    /// @param operator the address to approve or revoke approval for
    /// @param approved true to approve, false to revoke approval
    function setApprovalForAll(address operator, bool approved) public {
        isApprovedForAll[msg.sender][operator] = approved;

        emit ApprovalForAll(msg.sender, operator, approved);
    }

    /// @notice Transfer a single token from one user to another
    /// @dev supports token approvals
    /// @param from the user to transfer tokens from
    /// @param to the user to transfer tokens to
    /// @param id the ERC1155 token id to transfer
    /// @param amount the amount of tokens to transfer
    /// @param data optional data to include in the receive hook
    function safeTransferFrom(
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes calldata data
    ) public {
        if (!(msg.sender == from || isApprovedForAll[from][msg.sender])) revert NotAuthorized();

        balanceOf[from][id] -= amount;

        // balance will never overflow
        unchecked {
            balanceOf[to][id] += amount;
        }

        afterTokenTransfer(from, to, id, amount);

        emit TransferSingle(msg.sender, from, to, id, amount);

        if (to.code.length != 0) {
            if (
                ERC1155Holder(to).onERC1155Received(msg.sender, from, id, amount, data) !=
                ERC1155Holder.onERC1155Received.selector
            ) {
                revert UnsafeRecipient();
            }
        }
    }

    /// @notice Transfer multiple tokens from one user to another
    /// @dev supports token approvals
    /// @dev ids and amounts must be of equal length
    /// @param from the user to transfer tokens from
    /// @param to the user to transfer tokens to
    /// @param ids the ERC1155 token ids to transfer
    /// @param amounts the amounts of tokens to transfer
    /// @param data optional data to include in the receive hook
    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata data
    ) public virtual {
        if (!(msg.sender == from || isApprovedForAll[from][msg.sender])) revert NotAuthorized();

        // Storing these outside the loop saves ~15 gas per iteration.
        uint256 id;
        uint256 amount;

        for (uint256 i = 0; i < ids.length; ) {
            id = ids[i];
            amount = amounts[i];

            balanceOf[from][id] -= amount;

            // balance will never overflow
            unchecked {
                balanceOf[to][id] += amount;
            }

            // An array can't have a total length
            // larger than the max uint256 value.
            unchecked {
                ++i;
            }
        }

        afterTokenTransfer(from, to, ids, amounts);

        emit TransferBatch(msg.sender, from, to, ids, amounts);

        if (to.code.length != 0) {
            if (
                ERC1155Holder(to).onERC1155BatchReceived(msg.sender, from, ids, amounts, data) !=
                ERC1155Holder.onERC1155BatchReceived.selector
            ) {
                revert UnsafeRecipient();
            }
        }
    }

    /// @notice Query balances for multiple users and tokens at once
    /// @dev owners and ids must be of equal length
    /// @param owners the users to query balances for
    /// @param ids the ERC1155 token ids to query
    /// @return balances the balances for each user-token pair in the same order as the input
    function balanceOfBatch(
        address[] calldata owners,
        uint256[] calldata ids
    ) public view returns (uint256[] memory balances) {
        balances = new uint256[](owners.length);

        // Unchecked because the only math done is incrementing
        // the array index counter which cannot possibly overflow.
        unchecked {
            for (uint256 i = 0; i < owners.length; ++i) {
                balances[i] = balanceOf[owners[i]][ids[i]];
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                              ERC165 LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Signal support for ERC165 and ERC1155
    /// @param interfaceId the interface to check for support
    /// @return supported true if the interface is supported
    function supportsInterface(bytes4 interfaceId) public pure returns (bool) {
        return
            interfaceId == 0x01ffc9a7 || // ERC165 Interface ID for ERC165
            interfaceId == 0xd9b67a26; // ERC165 Interface ID for ERC1155
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL MINT/BURN LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Internal utility to mint tokens to a user's account
    /// @param to the user to mint tokens to
    /// @param id the ERC1155 token id to mint
    /// @param amount the amount of tokens to mint
    function _mint(address to, uint256 id, uint256 amount) internal {
        // balance will never overflow
        unchecked {
            balanceOf[to][id] += amount;
        }

        emit TransferSingle(msg.sender, address(0), to, id, amount);

        if (to.code.length != 0) {
            if (
                ERC1155Holder(to).onERC1155Received(msg.sender, address(0), id, amount, "") !=
                ERC1155Holder.onERC1155Received.selector
            ) {
                revert UnsafeRecipient();
            }
        }
    }

    /// @notice Internal utility to burn tokens from a user's account
    /// @param from the user to burn tokens from
    /// @param id the ERC1155 token id to mint
    /// @param amount the amount of tokens to burn
    function _burn(address from, uint256 id, uint256 amount) internal {
        balanceOf[from][id] -= amount;

        emit TransferSingle(msg.sender, from, address(0), id, amount);
    }

    /*//////////////////////////////////////////////////////////////
                            TRANSFER HOOKS
    //////////////////////////////////////////////////////////////*/

    /// @notice Internal hook to be called after a batch token transfer
    /// @dev this can be implemented in a child contract to add additional logic
    /// @param from the user to transfer tokens from
    /// @param to the user to transfer tokens to
    /// @param ids the ERC1155 token ids being transferred
    /// @param amounts the amounts of tokens to transfer
    function afterTokenTransfer(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts
    ) internal virtual;

    /// @notice Internal hook to be called after a single token transfer
    /// @dev this can be implemented in a child contract to add additional logic
    /// @param from the user to transfer tokens from
    /// @param to the user to transfer tokens to
    /// @param id the ERC1155 token id being transferred
    /// @param amount the amount of tokens to transfer
    function afterTokenTransfer(
        address from,
        address to,
        uint256 id,
        uint256 amount
    ) internal virtual;
}
