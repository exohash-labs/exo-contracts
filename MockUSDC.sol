// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * Mock USDC for tests:
 * - ERC20 with 6 decimals
 * - EIP-3009 transferWithAuthorization (you already had this)
 * - EIP-2612-style permit + nonces (this is what we add now)
 */
contract MockUSDC is ERC20, EIP712 {
    // ------------------------------------------------------------
    // EIP-3009 (you already had this part)
    // ------------------------------------------------------------

    // keccak256("TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)")
    bytes32 public constant TRANSFER_WITH_AUTHORIZATION_TYPEHASH =
        keccak256(
            "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
        );

    // authorizer => nonce => used?
    mapping(address => mapping(bytes32 => bool)) public authorizationState;

    // ------------------------------------------------------------
    // EIP-2612-style permit (this is the part you need to add)
    // matches the real Sei USDC ABI: nonces(), PERMIT_TYPEHASH, permit(...)
    // ------------------------------------------------------------

    // keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)")
    bytes32 public constant PERMIT_TYPEHASH =
        keccak256(
            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
        );

    // owner => current permit nonce
    mapping(address => uint256) public nonces;

    // Optional, but if Sei USDC exposes version() in its ABI, you need to match it:
    function version() external pure returns (string memory) {
        return "1"; // or whatever version string Sei USDC uses
    }
    
    constructor() ERC20("MockUSDC", "mUSDC") EIP712("MockUSDC", "1") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    // ------------------------------------------------------------
    // transferWithAuthorization (your existing 3009 flow)
    // ------------------------------------------------------------
    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        require(block.timestamp > validAfter, "authorization not yet valid");
        require(block.timestamp < validBefore, "authorization expired");
        require(!authorizationState[from][nonce], "authorization used");

        bytes32 structHash = keccak256(
            abi.encode(
                TRANSFER_WITH_AUTHORIZATION_TYPEHASH,
                from,
                to,
                value,
                validAfter,
                validBefore,
                nonce
            )
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, v, r, s);
        require(signer == from, "invalid signature");

        authorizationState[from][nonce] = true;
        _transfer(from, to, value);
    }

    // ------------------------------------------------------------
    // permit WITH v,r,s  (this is exactly what your test wants)
    // ------------------------------------------------------------
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        require(block.timestamp <= deadline, "permit expired");

        uint256 currentNonce = nonces[owner];

        bytes32 structHash = keccak256(
            abi.encode(
                PERMIT_TYPEHASH,
                owner,
                spender,
                value,
                currentNonce,
                deadline
            )
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, v, r, s);
        require(signer == owner, "invalid signature");

        // bump nonce
        nonces[owner] = currentNonce + 1;

        _approve(owner, spender, value);
    }

    // ------------------------------------------------------------
    // optional: permit WITH single bytes signature
    // (the Sei impl exposes both, so we mirror it)
    // ------------------------------------------------------------
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        bytes calldata signature
    ) external {
        require(block.timestamp <= deadline, "permit expired");

        uint256 currentNonce = nonces[owner];

        bytes32 structHash = keccak256(
            abi.encode(
                PERMIT_TYPEHASH,
                owner,
                spender,
                value,
                currentNonce,
                deadline
            )
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, signature);
        require(signer == owner, "invalid signature");

        nonces[owner] = currentNonce + 1;

        _approve(owner, spender, value);
    }
}
