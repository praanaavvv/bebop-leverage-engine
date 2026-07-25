// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Position} from "./Position.sol";

/// @notice Deploys Position clones (EIP-1167) at CREATE2 addresses predictable
/// before deployment — required so Bebop can be quoted with the future position
/// as taker_address. Salt commits to (owner, index) only; the factory is called
/// by the user in their own tx, so committing trade economics is unnecessary.
contract PositionFactory {
    address public immutable IMPL;

    event PositionDeployed(address indexed owner, uint96 indexed index, address position);

    constructor(address impl) {
        IMPL = impl;
    }

    function positionOf(address owner, uint96 index) public view returns (address) {
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(hex"ff", address(this), _salt(owner, index), keccak256(_creationCode()))
                    )
                )
            )
        );
    }

    function deploy(address owner, uint96 index) external returns (address p) {
        p = positionOf(owner, index);
        if (p.code.length == 0) {
            bytes memory code = _creationCode();
            bytes32 salt = _salt(owner, index);
            address deployed;
            assembly {
                deployed := create2(0, add(code, 0x20), mload(code), salt)
            }
            require(deployed == p, "create2");
            Position(p).initialize(owner);
            emit PositionDeployed(owner, index, p);
        }
    }

    function _salt(address owner, uint96 index) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(owner)) << 96 | uint256(index));
    }

    /// EIP-1167 minimal proxy creation code pointing at IMPL.
    function _creationCode() internal view returns (bytes memory) {
        return abi.encodePacked(
            hex"3d602d80600a3d3981f3363d3d373d3d3d363d73", IMPL, hex"5af43d82803e903d91602b57fd5bf3"
        );
    }
}
