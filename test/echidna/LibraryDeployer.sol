pragma solidity ^0.8.12;

import {PanopticMath} from "@libraries/PanopticMath.sol";
import {InteractionHelper} from "@libraries/InteractionHelper.sol";

contract LibraryDeployer {
    address public panopticMath;
    address public interactionHelper;

    event LogAddress(string name, address addr);

    constructor() {
        bytes memory code = type(PanopticMath).creationCode;

        address _pointer;

        assembly ("memory-safe") {
            _pointer := create(0, add(code, 0x20), mload(code))
        }
        panopticMath = _pointer;

        code = type(InteractionHelper).creationCode;
        assembly ("memory-safe") {
            _pointer := create(0, add(code, 0x20), mload(code))
        }
        interactionHelper = _pointer;
    }

    function get_lib_addresses() external {
        emit LogAddress("PanopticMath", panopticMath);
        emit LogAddress("InteractionHelper", interactionHelper);

        assert(false);
    }
}
