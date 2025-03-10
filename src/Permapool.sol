// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { INonfungiblePositionManager } from "./Uniswap/INonfungiblePositionManager.sol";
import { IUniswapV3Factory } from "./Uniswap/IUniswapV3Factory.sol";
import { IUniswapV3Pool } from "./Uniswap/IUniswapV3Pool.sol";
import { ISwapRouter } from "./Uniswap/ISwapRouter.sol";
import "./IWETH.sol";

interface IGovernance {
    function getGuardians() external returns (address[] memory);
}

contract Permapool is IERC721Receiver, Ownable {
    using EnumerableMap for EnumerableMap.AddressToUintMap;

    ISwapRouter public constant SWAP_ROUTER = ISwapRouter(0x2626664c2603336E57B271c5C0b26F421741e481);
    INonfungiblePositionManager public constant POSITION_MANAGER = INonfungiblePositionManager(0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1);
    address public constant WETH = 0x4200000000000000000000000000000000000006;
    uint24 public constant POOL_FEE = 10000; // Pool fee (e.g., 3000 = 0.3%)
    address public immutable TOKEN;
    uint256 public TOKEN_ID; // Tracks the NFT ID of the LP position

    address private _governance;

    mapping(address => EnumerableMap.AddressToUintMap) _tokenUserDonations;
    mapping(address => EnumerableMap.AddressToUintMap) _userTokenDonations;

    event Donate(
        address indexed user,
        address indexed token,
        uint quantity,
        uint timestamp
    );

    constructor(address token) {
        TOKEN = token;
        IERC20(WETH).approve(address(SWAP_ROUTER), type(uint256).max);
        IERC20(TOKEN).approve(address(SWAP_ROUTER), type(uint256).max);
        IERC20(WETH).approve(address(POSITION_MANAGER), type(uint256).max);
        IERC20(TOKEN).approve(address(POSITION_MANAGER), type(uint256).max);
    }

    function donate(address token, uint quantity) external {
        require(quantity > 0, "Invalid quantity");
        require(IERC20(token).transferFrom(msg.sender, address(this), quantity), "Unable to transfer token");

        _donate(msg.sender, token, quantity);
    }

    function _donate(address user, address token, uint quantity) internal {
        (,uint userQuantity) = _userTokenDonations[user].tryGet(token);
        userQuantity += quantity;
        _userTokenDonations[user].set(token, userQuantity);
        _tokenUserDonations[token].set(user, userQuantity);

        emit Donate(user, token, quantity, block.timestamp);

        if (token == WETH) {
            convertEthToLP();
        } else {
            convertTokenToLP(token);
        }
    }

    function convertTokenToLP(address token) public {
        uint256 tokenBalance = IERC20(token).balanceOf(address(this));
        require(tokenBalance > 0, "No tokens to sell");

        // Approve the router to spend the tokens
        IERC20(token).approve(address(SWAP_ROUTER), type(uint256).max);

        // Perform the token-to-ETH swap
        SWAP_ROUTER.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: token,
                tokenOut: WETH,
                fee: POOL_FEE,
                recipient: address(this),
                amountIn: tokenBalance,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        convertEthToLP();
    }

    function convertEthToLP() public {
        uint ethBalance = IERC20(WETH).balanceOf(address(this));
        uint guardianFee = ethBalance / 10;
        ethBalance -= guardianFee;

        IERC20(WETH).transfer(_governance, guardianFee);

        // Split the received ETH into two halves
        uint256 halfEth = ethBalance / 2;
        require(halfEth > 0, "No ETH to LP");

        // Buy TOKEN with half of the ETH
        uint256 tokenAmount = SWAP_ROUTER.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: WETH,
                tokenOut: TOKEN,
                fee: POOL_FEE,
                recipient: address(this),
                amountIn: halfEth,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        // Add liquidity to the pool
        if (TOKEN_ID == 0) {
            // Create a new full-range position
            (TOKEN_ID, , , ) = POSITION_MANAGER.mint(
                INonfungiblePositionManager.MintParams({
                    token0: WETH < TOKEN ? WETH : TOKEN,
                    token1: WETH < TOKEN ? TOKEN : WETH,
                    fee: POOL_FEE,
                    tickLower: -887200,
                    tickUpper: 887200,
                    amount0Desired: WETH < TOKEN ? halfEth : tokenAmount,
                    amount1Desired: WETH < TOKEN ? tokenAmount : halfEth,
                    amount0Min: 0,
                    amount1Min: 0,
                    recipient: address(this),
                    deadline: block.timestamp
                })
            );
        } else {
            // Increase liquidity on the existing position
            POSITION_MANAGER.increaseLiquidity(
                INonfungiblePositionManager.IncreaseLiquidityParams({
                    tokenId: TOKEN_ID,
                    amount0Desired: WETH < TOKEN ? halfEth : tokenAmount,
                    amount1Desired: WETH < TOKEN ? tokenAmount : halfEth,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp
                })
            );
        }
    }

    function setGovernance(address governance) external {
        require(msg.sender == _governance || msg.sender == owner(), "Not authorized");
        _governance = governance;
    }

    function collectFees() external returns (uint, uint) {
        require(msg.sender == _governance, "Not authorized");

        INonfungiblePositionManager.CollectParams memory collectParams = INonfungiblePositionManager.CollectParams({
            tokenId: TOKEN_ID,
            recipient: _governance,
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });
        (uint feesToken0, uint feesToken1) = POSITION_MANAGER.collect(collectParams);

        return (feesToken0, feesToken1);
    }

    // Allow the contract to receive ETH
    receive() external payable {
        // 90% to LP
        IWETH(WETH).deposit{value: msg.value * 9 / 10}();
        _donate(msg.sender, WETH, msg.value * 9 / 10);
        // 10% to Guardians
        payGuardians();
    }

    function payGuardians() public {
        address[] memory guardians = IGovernance(_governance).getGuardians();
        uint balance = address(this).balance;
        if (guardians.length > 0 && balance > 0) {
            uint amountToSend = address(this).balance / guardians.length;
            for (uint i = 0; i < guardians.length; i++) {
                (bool transferred,) = guardians[i].call{value: amountToSend}("");
                require(transferred, "Transfer failed");
            }
        }
    }

    /// @notice Allows receiving of LP NFT on contract
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    function getUserTokenDonation(address user, address token) external view returns (uint) {
        return _userTokenDonations[user].get(token);
    }
    function getUserTokenDonations(address user) external view returns (address[] memory, uint[] memory) {
        address[] memory tokens = _userTokenDonations[user].keys();
        uint[] memory quantities = new uint[](tokens.length);
        for (uint i = 0; i < tokens.length; i++) {
            quantities[i] = _userTokenDonations[user].get(tokens[i]);
        }
        return (tokens, quantities);
    }
    function getUserTokenDonationAt(address user, uint index) external view returns (address, uint) {
        return _userTokenDonations[user].at(index);
    }
    function getNumUserTokenDonations(address user) external view returns (uint) {
        return _userTokenDonations[user].length();
    }

    function getTokenUserDonation(address token, address user) external view returns (uint) {
        return _tokenUserDonations[token].get(user);
    }
    function getTokenUserDonations(address token) external view returns (address[] memory, uint[] memory) {
        address[] memory users = _tokenUserDonations[token].keys();
        uint[] memory quantities = new uint[](users.length);
        for (uint i = 0; i < users.length; i++) {
            quantities[i] = _tokenUserDonations[token].get(users[i]);
        }
        return (users, quantities);
    }
    function getTokenUserDonationAt(address token, uint index) external view returns (address, uint) {
        return _tokenUserDonations[token].at(index);
    }
    function getNumTokenUserDonations(address token) external view returns (uint) {
        return _tokenUserDonations[token].length();
    }

    function getGovernance() external view returns (address) {
        return _governance;
    }
}
