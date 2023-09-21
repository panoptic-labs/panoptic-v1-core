// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.18;

// OpenZeppelin
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
// Panoptic
import {CollateralTracker} from "@contracts/CollateralTracker.sol";
import {GatedFactory} from "@contracts/GatedFactory.sol";
// Internal
import {IERC20Partial} from "@tokens/interfaces/IERC20Partial.sol";
import {ERC20Minimal} from "@tokens/ERC20Minimal.sol";
import {Errors} from "@libraries/Errors.sol";

contract MerkleDistributor {
    // Underlying CollateralTokens
    CollateralTracker public immutable collateralToken0;
    CollateralTracker public immutable collateralToken1;

    // ERC20 tokens of the associated Uniswap pool
    address public immutable token0;
    address public immutable token1;

    // Factory which deployed the merkle distributor
    GatedFactory public immutable factory;
    // Address of the associated Panoptic Pool
    address public immutable panopticPoolAddress;

    // Merkle root for the corresponding merkle tree generated off-chain.
    bytes32 public merkleRoot;

    /// @notice This is a packed array of booleans.
    mapping(uint256 claimedWordIndex => uint256 claimedWord) private claimedBitMap;

    /// @notice Ensures that the Panoptic Factory Owner is the caller. Revert if not.
    modifier onlyFactoryOwner() {
        if (msg.sender != factory.factoryOwner()) revert Errors.NotOwner();
        _;
    }

    /// @param _collateralToken0 The underlying CollateralTracker which represents token0 of the PanopticPool.
    /// @param _collateralToken1 The underlying CollateralTracker which represents token1 of the PanopticPool.
    /// @param _token0 The token0 of the associated Uniswap pool.
    /// @param _token1 The token1 of the associated Uniswap pool.
    /// @param _factory Reference to factory contract which deployed the Panoptic pool.
    /// @param _panopticPool Address of the underlying Panoptic pool.
    constructor(
        CollateralTracker _collateralToken0,
        CollateralTracker _collateralToken1,
        address _token0,
        address _token1,
        GatedFactory _factory,
        address _panopticPool
    ) {
        // set the factory reference
        factory = _factory;

        // link the underlying panoptic pool
        panopticPoolAddress = _panopticPool;

        // link the underlying collateral trackers
        collateralToken0 = _collateralToken0;
        collateralToken1 = _collateralToken1;

        // link the ERC20 tokens of the associated Uniswap pool
        token0 = _token0;
        token1 = _token1;

        // Approve the CollateralTracker to move funds on the MerkleDistributors behalf
        // Neccessary when deposit is called via this the distributors claim function
        // As users funds will be debited from the distributor
        IERC20Partial(token0).approve(address(collateralToken0), type(uint256).max);
        IERC20Partial(token1).approve(address(collateralToken1), type(uint256).max);
    }

    /// @notice Returns true if the index has been marked claimed.
    /// @param index the bit assigned to the user, that is flipped upon a successful claim.
    function isClaimed(uint256 index) public view returns (bool) {
        uint256 claimedWordIndex = index / 256;
        uint256 claimedBitIndex = index % 256;
        uint256 claimedWord = claimedBitMap[claimedWordIndex];
        uint256 mask = (1 << claimedBitIndex);
        return claimedWord & mask == mask;
    }

    /// @notice Flips the requested index/bit in the bitmap to denote it as 'claimed'.
    /// @param index the bit assigned to the user, that is flipped upon a successful claim.
    function _setClaimed(uint256 index) private {
        uint256 claimedWordIndex = index / 256;
        uint256 claimedBitIndex = index % 256;
        claimedBitMap[claimedWordIndex] = claimedBitMap[claimedWordIndex] | (1 << claimedBitIndex);
    }

    /// @notice Gates deposits to both underlying CollateralTokens.
    /// Only whitelisted users will be allowed to claim/invoke a deposit to the underlying CollateralTokens.
    /// @param index Bit/index in the bitmap assigned to the claiming account.
    /// @param depositToken0 The max deposit amounts asssigned to the account for token 0.
    /// @param depositToken1 The max deposit amounts asssigned to the account for token 1.
    /// @param merkleProof Proof generated off-chain to prove the existence of the node in the merkle tree.
    function claim(
        uint256 index,
        uint256 depositToken0,
        uint256 depositToken1,
        bytes32[] calldata merkleProof
    ) external {
        // Ensure user has not already deposited
        if (isClaimed(index)) revert Errors.InvalidClaim();

        // Verify the merkle proof
        bytes32 node = keccak256(abi.encodePacked(index, msg.sender, depositToken0, depositToken1));
        if (!MerkleProof.verify(merkleProof, merkleRoot, node)) revert Errors.InvalidProof();

        // Mark the associated bit/index in the bitmap claimed
        _setClaimed(index);

        /// Invoke the deposit process for both tokens

        // transfer funds from the user to the MerkleDistributor
        ERC20Minimal(token0).transferFrom(msg.sender, address(this), depositToken0);
        ERC20Minimal(token1).transferFrom(msg.sender, address(this), depositToken1);

        // Users will always be forced to deposit the amount specified in their pre-hashed data
        collateralToken0.deposit(depositToken0, msg.sender);
        collateralToken1.deposit(depositToken1, msg.sender);
    }

    /// @notice Called by the owner to update the stored merkleRoot.
    /// @param _newRootHash the root hash corresponding to the merkle tree generated off-chain.
    function updateRoot(bytes32 _newRootHash) external onlyFactoryOwner {
        merkleRoot = _newRootHash;
    }
}
