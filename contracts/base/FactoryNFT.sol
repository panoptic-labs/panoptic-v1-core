// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

// Interfaces
import {PanopticMath} from "@libraries/PanopticMath.sol";
import {PanopticPool} from "@contracts/PanopticPool.sol";
// Inherited implementations
import {ERC721} from "solmate/tokens/ERC721.sol";
import {MetadataStore} from "@base/MetadataStore.sol";
// Custom types
import {Pointer} from "@types/Pointer.sol";
// Solady libraries
import {LibString} from "solady/utils/LibString.sol";
import {Base64} from "solady/utils/Base64.sol";

/// @title FactoryNFT: ERC721 contract for Panoptic Factory NFTs.
/// @notice Constructs dynamic SVG art and metadata for Panoptic Factory NFTs from a set of building blocks.
/// @dev Pointers to metadata are provided at deployment time.
contract FactoryNFT is MetadataStore, ERC721 {
    using LibString for string;

    /// @notice Initialize metadata pointers and token name/symbol.
    /// @param properties An array of identifiers for different categories of metadata
    /// @param indices A nested array of keys for K-V metadata pairs for each property in `properties`
    /// @param pointers Contains pointers to the metadata values stored in contract data slices for each index in `indices`
    constructor(
        bytes32[] memory properties,
        uint256[][] memory indices,
        Pointer[][] memory pointers
    )
        MetadataStore(properties, indices, pointers)
        ERC721("Panoptic Factory Deployer NFTs", "PANOPTIC-NFT")
    {}

    /// @notice Returns the metadata URI for a given `tokenId`.
    /// @dev The metadata is dynamically generated from the characteristics of the `PanopticPool` encoded in `tokenId`.
    /// @dev The first 160 bits of `tokenId` are the address of a Panoptic Pool.
    /// @param tokenId The token ID (encoded pool address) to get the metadata URI for
    /// @return The metadata URI for the token ID
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        address panopticPool = address(uint160(tokenId));

        return
            constructMetadata(
                panopticPool,
                PanopticMath.safeERC20Symbol(PanopticPool(panopticPool).univ3pool().token0()),
                PanopticMath.safeERC20Symbol(PanopticPool(panopticPool).univ3pool().token1()),
                PanopticPool(panopticPool).univ3pool().fee()
            );
    }

    /// @notice Returns the metadata URI for a given set of characteristics.
    /// @param panopticPool The displayed address used to determine the rarity (leading zeros) and lastCharVal (last 4 bits)
    /// @param symbol0 The symbol of `token0` in the Uniswap pool
    /// @param symbol1 The symbol of `token1` in the Uniswap pool
    /// @param fee The fee of the Uniswap pool (in hundredths of basis points)
    /// @return The metadata URI for the given characteristics
    function constructMetadata(
        address panopticPool,
        string memory symbol0,
        string memory symbol1,
        uint256 fee
    ) public view returns (string memory) {
        uint256 lastCharVal = uint160(panopticPool) & 0xF;
        uint256 rarity = PanopticMath.numberOfLeadingHexZeros(panopticPool);

        string memory svgOut = generateSVGArt(lastCharVal, rarity);

        svgOut = generateSVGInfo(svgOut, panopticPool, rarity, symbol0, symbol1);
        return
            string(
                abi.encodePacked(
                    "data:application/json;base64,",
                    Base64.encode(
                        bytes(
                            abi.encodePacked(
                                '{"name":"',
                                abi.encodePacked(
                                    LibString.toHexString(uint256(uint160(panopticPool)), 20),
                                    "-",
                                    string.concat(
                                        metadata[bytes32("strategies")][lastCharVal].dataStr(),
                                        "-",
                                        LibString.toString(rarity)
                                    )
                                ),
                                '", "description":"',
                                string.concat(
                                    "Panoptic Pool for the ",
                                    symbol0,
                                    "-",
                                    symbol1,
                                    "-",
                                    PanopticMath.uniswapFeeToString(uint24(fee)),
                                    " market"
                                ),
                                '", "attributes": [{"trait_type": "Rarity", "value": "',
                                string.concat(
                                    LibString.toString(rarity),
                                    " - ",
                                    metadata[bytes32("rarities")][rarity].dataStr()
                                ),
                                '"}, {"trait_type": "Strategy", "value": "',
                                metadata[bytes32("strategies")][lastCharVal].dataStr(),
                                '"}, {"trait_type": "ChainId", "value": "',
                                getChainName(),
                                '"}], "image": "data:image/svg+xml;base64,',
                                Base64.encode(bytes(svgOut)),
                                '"}'
                            )
                        )
                    )
                )
            );
    }

    /// @notice Generate the artwork component of the SVG for a given rarity and last character value.
    /// @param lastCharVal The last character of the pool address
    /// @param rarity The rarity of the NFT
    /// @return svgOut The SVG artwork for the NFT
    function generateSVGArt(
        uint256 lastCharVal,
        uint256 rarity
    ) internal view returns (string memory svgOut) {
        svgOut = metadata[bytes32("frames")][
            rarity < 18 ? rarity / 3 : rarity < 23 ? 23 - rarity : 0
        ].decompressedDataStr();
        svgOut = svgOut.replace(
            "<!-- LABEL -->",
            write(
                metadata[bytes32("strategies")][lastCharVal].dataStr(),
                maxStrategyLabelWidth(rarity)
            )
        );

        svgOut = svgOut
            .replace(
                "<!-- TEXT -->",
                metadata[bytes32("descriptions")][lastCharVal + 16 * (rarity / 8)]
                    .decompressedDataStr()
            )
            .replace("<!-- ART -->", metadata[bytes32("art")][lastCharVal].decompressedDataStr())
            .replace("<!-- FILTER -->", metadata[bytes32("filters")][rarity].decompressedDataStr());
    }

    /// @notice Fill in the pool/rarity specific text fields on the SVG artwork.
    /// @param svgIn The SVG artwork to complete
    /// @param panopticPool The address of the Panoptic Pool
    /// @param rarity The rarity of the NFT
    /// @param symbol0 The symbol of `token0` in the Uniswap pool
    /// @param symbol1 The symbol of `token1` in the Uniswap pool
    /// @return The final SVG artwork with the pool/rarity specific text fields filled in
    function generateSVGInfo(
        string memory svgIn,
        address panopticPool,
        uint256 rarity,
        string memory symbol0,
        string memory symbol1
    ) internal view returns (string memory) {
        svgIn = svgIn
            .replace("<!-- POOLADDRESS -->", LibString.toHexString(uint160(panopticPool), 20))
            .replace("<!-- CHAINID -->", getChainName());

        svgIn = svgIn.replace(
            "<!-- RARITY_NAME -->",
            write(metadata[bytes32("rarities")][rarity].dataStr(), maxRarityLabelWidth(rarity))
        );

        return
            svgIn
                .replace("<!-- RARITY -->", write(LibString.toString(rarity)))
                .replace("<!-- SYMBOL0 -->", write(symbol0, maxSymbolWidth(rarity)))
                .replace("<!-- SYMBOL1 -->", write(symbol1, maxSymbolWidth(rarity)));
    }

    /// @notice Get the name of the current chain.
    /// @return The name of the current chain, or the chain ID if not recognized
    function getChainName() internal view returns (string memory) {
        if (block.chainid == 1) {
            return "Ethereum Mainnet";
        } else if (block.chainid == 56) {
            return "BNB Smart Chain Mainnet";
        } else if (block.chainid == 42161) {
            return "Arbitrum One";
        } else if (block.chainid == 8453) {
            return "Base";
        } else if (block.chainid == 43114) {
            return "Avalanche C-Chain";
        } else if (block.chainid == 137) {
            return "Polygon Mainnet";
        } else if (block.chainid == 10) {
            return "OP Mainnet";
        } else if (block.chainid == 42220) {
            return "Celo Mainnet";
        } else if (block.chainid == 238) {
            return "Blast Mainnet";
        } else {
            return LibString.toString(block.chainid);
        }
    }

    /// @notice Get a group of paths representing `chars` written in a certain font at a default size.
    /// @param chars The characters to write
    /// @return The group of paths representing the characters written in the font
    function write(string memory chars) internal view returns (string memory) {
        return write(chars, type(uint256).max);
    }

    /// @notice Get a group of paths representing `chars` written in a certain font, scaled to a maximum width.
    /// @param chars The characters to write
    /// @param maxWidth The maximum width (in SVG units) of the group of paths
    /// @return fontGroup The group of paths representing the characters written in the font
    function write(
        string memory chars,
        uint256 maxWidth
    ) internal view returns (string memory fontGroup) {
        // the sum of all character widths in `chars`
        uint256 offset;

        for (uint256 i = 0; i < bytes(chars).length; ++i) {
            // character widths are hardcoded in the metadata
            uint256 charOffset = uint256(
                bytes32(metadata[bytes32("charOffsets")][uint256(bytes32(bytes(chars)[i]))].data())
            );
            offset += charOffset;

            fontGroup = string.concat(
                '<g transform="translate(-',
                LibString.toString(charOffset),
                ', 0)">',
                fontGroup,
                metadata[bytes32("charPaths")][uint256(bytes32(bytes(chars)[i]))].dataStr(),
                "</g>"
            );
        }

        // scale the font to fit within the maximum width, if necessary
        string memory factor;
        if (offset > maxWidth) {
            uint256 _scale = (3400 * maxWidth) / offset;
            if (_scale > 99) {
                factor = LibString.toString(_scale);
            } else {
                factor = string.concat("0", LibString.toString(_scale));
            }
        } else {
            factor = "34";
        }

        fontGroup = string.concat(
            '<g transform="scale(0.0',
            factor,
            ") translate(",
            LibString.toString(offset / 2),
            ', 0)">',
            fontGroup,
            "</g>"
        );
    }

    /// @notice Get the maximum SVG unit width for the token symbols at the bottom left/right corners for a given rarity.
    /// @dev This is to ensure the text fits within its section on the frame. There are 6 frames, and each rarity is assigned one of the six.
    /// @param rarity The rarity of the NFT
    /// @return width The maximum SVG unit width for the token symbols
    function maxSymbolWidth(uint256 rarity) internal pure returns (uint256 width) {
        if (rarity < 3) {
            width = 1600;
        } else if (rarity < 9) {
            width = 1350;
        } else if (rarity < 12) {
            width = 1450;
        } else if (rarity < 15) {
            width = 1350;
        } else if (rarity < 19) {
            width = 1250;
        } else if (rarity < 20) {
            width = 1350;
        } else if (rarity < 21) {
            width = 1450;
        } else if (rarity < 23) {
            width = 1350;
        } else if (rarity >= 23) {
            width = 1600;
        }
    }

    /// @notice Get the maximum SVG unit width for the rarity name at the top for a given rarity (frame).
    /// @dev This is to ensure the text fits within its section on the frame. There are 6 frames, and each rarity is assigned one of the six.
    /// @param rarity The rarity of the NFT
    /// @return width The maximum SVG unit width for the rarity name
    function maxRarityLabelWidth(uint256 rarity) internal pure returns (uint256 width) {
        if (rarity < 3) {
            width = 210;
        } else if (rarity < 6) {
            width = 220;
        } else if (rarity < 9) {
            width = 210;
        } else if (rarity < 12) {
            width = 220;
        } else if (rarity < 15) {
            width = 260;
        } else if (rarity < 19) {
            width = 225;
        } else if (rarity < 20) {
            width = 260;
        } else if (rarity < 21) {
            width = 220;
        } else if (rarity < 22) {
            width = 210;
        } else if (rarity < 23) {
            width = 220;
        } else if (rarity >= 23) {
            width = 210;
        }
    }

    /// @notice Get the maximum SVG unit width for the strategy name label in the center for a given rarity (frame).
    /// @dev This is to ensure the text fits within its section on the frame. There are 6 frames, and each rarity is assigned one of the six.
    /// @param rarity The rarity of the NFT
    /// @return width The maximum SVG unit width for the strategy name label
    function maxStrategyLabelWidth(uint256 rarity) internal pure returns (uint256 width) {
        if (rarity < 6) {
            width = 9000;
        } else if (rarity <= 22) {
            width = 3900;
        } else if (rarity > 22) {
            width = 9000;
        }
    }
}
