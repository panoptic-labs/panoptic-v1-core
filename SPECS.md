# Panoptic XHASH Specification

This document outlines the design, known vulnerabilities, and proposed remediations for Panoptic's XHASH position fingerprinting mechanism. Read the official [post-mortem](https://panoptic.xyz/blog/position-spoofing-post-mortem) for more details

---

## TokenId and Position Definition

- Each user position is defined by a `uint256` called a `tokenId`. Source: [types/TokenId.sol](https://github.com/panoptic-labs/panoptic-v1-core/blob/specs/homomorphic-hashing/contracts/types/TokenId.sol)
- This `tokenId` encodes all of the position's parameters (e.g., put/call, long/short, strike price, market identifier).
- The protocol tracks ownership of these positions as Semifungible NFTs using the ERC1155 interface.
- A user mints a position by supplying a `tokenId`, which the protocol then decodes to create a corresponding Liquidity Provider (LP) position in Uniswap.

---

## Collateral Requirements

- Each `tokenId` effectively represents a **debt position** and has an associated collateral requirement.
- A user's total portfolio collateral requirement must be less than or equal to their collateral balance.
- Liquidations are triggered when a user's `totalCollateralRequirements` exceed their `collateralBalance`.

---

## Position Tracking via XHASH for Homomorphic hashing

To save gas, the protocol does not store a list of every user's `tokenIds`. Instead, it tracks a single fingerprint (`H`) and the number of individual positions (legs) for each user.

- **Fingerprint Formula (XHASH):** The fingerprint `H` is the XOR sum of the `keccak256` hashes of each individual `tokenId`.
  ```
  XHASH = keccak256(abi.encode(tokenId_0)) ^ keccak256(abi.encode(tokenId_1)) ^ ... ^ keccak256(abi.encode(tokenId_n))
  ```
- **Operations:**
  - **Minting (Add):** The new `keccak256(abi.encode(tokenId))` is XORed with the user's existing `H`.
  - **Burning (Remove):** The `keccak256(abi.encode(tokenId))` of the burned position is XORed with the user's existing `H` to remove it.
  - **Reference:** [PanopticPool.sol:\_updatePositionsHash()](https://github.com/panoptic-labs/panoptic-v1-core/blob/specs/homomorphic-hashing/contracts/PanopticPool.sol#L1295-L1315), called in `_updateSettlementPostMint` and `_updateSettlementPostBurn`.
- **User-Supplied List:** When a user performs any action (mint, burn, withdraw), they must supply their complete list of positions: `positionIdList = [token_0, token_1, ..., token_n]`. The protocol recalculates the XHASH from this list and proceeds only if it matches the one stored internally. Source: [PanopticPool.sol:\_validatePositionList()](https://github.com/panoptic-labs/panoptic-v1-core/blob/specs/homomorphic-hashing/contracts/PanopticPool.sol#L1262-L1293)
- **Implementation Detail:** The number of positions is stored in the upper 8 bits of the hash, and thet 256-bit hash is truncated to 248 bits. Source: [libraries/PanopticMath.sol:updatePositionsHash()](https://github.com/panoptic-labs/panoptic-v1-core/blob/specs/homomorphic-hashing/contracts/libraries/PanopticMath.sol#L115-L139)
- Description from [PanopticPool.sol](https://github.com/panoptic-labs/panoptic-v1-core/blob/specs/homomorphic-hashing/contracts/PanopticPool.sol#L228-L237):
  ```
  /// @notice Tracks the position list hash (i.e `keccak256(XORs of abi.encodePacked(positionIdList))`).
  /// @dev A component of this hash also tracks the total number of legs across all positions (i.e. makes sure the length of the provided positionIdList matches).
  /// @dev The purpose of this system is to reduce storage usage when a user has more than one active position.
  /// @dev Instead of having to manage an unwieldy storage array and do lots of loads, we just store a hash of the array.
  /// @dev This hash can be cheaply verified on every operation with a user provided positionIdList - which can then be used for operations
  /// without having to every load any other data from storage.
  //      numLegs                   user positions hash
  //  |<-- 8 bits -->|<------------------ 248 bits ------------------->|
  //  |<---------------------- 256 bits ------------------------------>|
  mapping(address account => uint256 positionsHash) internal s_positionsHash;
  ```

---

## Identified Vulnerabilities

### **Cryptographic Flaw**

The XHASH scheme is vulnerable to collision attacks. It is computationally feasible for an attacker to find two different lists of `tokenIds` that hash to the same fingerprint `H`. This is a known weakness of XOR-based accumulators, detailed in papers by Bellare & Micciancio and David Wagner (generalized birthday problem).

### **Design Flaw 1: Improper `tokenId` Validation**

The protocol was not properly validating the `tokenIds` in the user-supplied list. This allowed an attacker to:

1.  Supply a list containing `tokenIds` that could never be minted on Panoptic, massively increasing the search space for finding a hash collision.
2.  Supply positions with zero "legs," which did not correctly factor into the position count.

### **Design Flaw 2: Lack of Ownership Check**

The protocol was not verifying that the user actually owned the `tokenIds` in the supplied list. This enabled an attacker's spoofed list to pass the collateral check because the calculated requirement for unowned positions would be zero.

---

## Proposed Remediation ("More Checks")

The following checks are proposed to mitigate the design flaws.

1.  **Remediating Design Flaw 1:**

    - The validation step will `revert` if any supplied `tokenId` is invalid or has zero legs.

2.  **Remediating Design Flaw 2:**

    - The transaction will `revert` if any supplied `tokenId` is not owned by the calling account.
    - The user-supplied `positionIdList` must be sorted in ascending order.
    - The list must not contain any duplicate `tokenIds`.

These remediation steps are designed to make the original attack vector fail, even with the continued use of XHASH, by severely constraining the attacker's ability to construct a malicious spoofed list.

---

#

#

# Statement Of Work and Open Questions

- Question 1: are those remediation steps enough to prevent any future attack, assuming we still use XHASH?

- Question 2: would a different fingerprinting scheme make that type of attack impossible?

# Proposed alternatives

This section reviews two potential cryptographic replacements for the vulnerable XHASH scheme.

### Alternative 1: Hashing the Sorted List

This approach proposes creating the fingerprint by taking the `keccak256` hash of the user's entire, sorted list of `tokenIds`.

- **Method:** `fingerprint = keccak256(abi.encode(sorted_tokenId_list[]))`
- **Pros (Security):** This is the **gold standard** for creating a secure commitment to a set of data. `keccak256` is highly collision-resistant, meaning it's computationally impossible for an attacker to find two different lists of positions that produce the same fingerprint. This would completely eliminate the forgery attack vector.
- **Cons (Gas Cost):** This method is very expensive on a blockchain. To add or remove a single position, the smart contract would need to load the user's _entire list_ of `tokenIds` from storage, make the change, and then write the _entire new list_ back. These storage operations (especially writing) are extremely costly in terms of gas, and the cost would grow as a user's portfolio gets larger.

### Alternative 2: LtHash (k=2)

LtHash is a type of **incremental hash**, which, like XHASH, allows you to efficiently add and remove items from the fingerprint without needing the whole list.

- **Method:** Instead of XORing hashes, you are **adding** them together using math over a very large prime number (modular addition). The `k=2` means you do this twice, with two different hash functions, creating two independent accumulators. A fingerprint might look like `H = {accumulator_1, accumulator_2}`.
- **Pros (Security & Efficiency):**
  1.  **High Security:** It is purported to offer strong 128-bit of security. An attacker would have to find a collision in _both_ accumulators simultaneously, which is a fundamentally harder problem than breaking the XOR scheme.
  2.  **Gas Efficient:** Just like XHASH, it's incremental. To add a position, you add its hashes to the running totals. To remove it, you subtract them. This completely avoids the expensive on-chain array management of the first alternative.
- **Cons:** Unclear if that 128 bits security assumption is valid or cryptographically secure. This would be a slightly higher implementation complexity compared to the simple XOR of XHASH.
