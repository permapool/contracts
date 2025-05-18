// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { INonfungiblePositionManager } from "./Uniswap/INonfungiblePositionManager.sol";
import { IUniswapV3Factory } from "./Uniswap/IUniswapV3Factory.sol";
import { IUniswapV3Pool } from "./Uniswap/IUniswapV3Pool.sol";
import { ISwapRouter } from "./Uniswap/ISwapRouter.sol";
import "./IGovernance.sol";
import "./IPermapool.sol";
import "./IWETH.sol";

contract Permapool is IPermapool, IERC721Receiver, Ownable {
    using EnumerableSet for EnumerableSet.UintSet;

    ISwapRouter public constant SWAP_ROUTER = ISwapRouter(0x2626664c2603336E57B271c5C0b26F421741e481);
    INonfungiblePositionManager public constant POSITION_MANAGER = INonfungiblePositionManager(0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1);
    IUniswapV3Factory public constant POOL_FACTORY = IUniswapV3Factory(0x33128a8fC17869897dcE68Ed026d694621f6FDfD);
    address public constant WETH = 0x4200000000000000000000000000000000000006;

    address public immutable TOKEN;
    uint24 public immutable POOL_FEE;
    uint256 public LP_TOKEN_ID; // Tracks the NFT ID of the LP position
    address private _governance;
    Donation[] private _donations;
    mapping(address => EnumerableSet.UintSet) _tokenDonations;
    mapping(address => EnumerableSet.UintSet) _userDonations;
    uint private _totalFees0;
    uint private _totalFees1;
    uint private _totalEthDonated;
    uint private _totalTokenDonated;
    uint private _ethPaidToGuardians;
    uint private _ethPaidToGovernance;
    uint private _tokenPaidToGovernance;

    struct Donation {
        address user;
        address token;
        uint quantity;
        uint ethValue;
        uint timestamp;
    }

    event Donate(
        uint indexed id,
        address indexed user,
        address indexed token,
        uint quantity,
        uint ethValue,
        uint timestamp
    );

    constructor(address token) {
        TOKEN = token;
        POOL_FEE = getPoolFee(token);
        IERC20(WETH).approve(address(SWAP_ROUTER), type(uint256).max);
        IERC20(TOKEN).approve(address(SWAP_ROUTER), type(uint256).max);
        IERC20(WETH).approve(address(POSITION_MANAGER), type(uint256).max);
        IERC20(TOKEN).approve(address(POSITION_MANAGER), type(uint256).max);
    }

    function donate() public payable {
        require(msg.value > 0, "Invalid quantity");
        IWETH(WETH).deposit{value: msg.value}();
        _donate(msg.sender, WETH, msg.value);
    }

    function donate(address token, uint quantity) external {
        require(quantity > 0, "Invalid quantity");
        require(IERC20(token).transferFrom(msg.sender, address(this), quantity), "Unable to transfer token");

        _donate(msg.sender, token, quantity);
    }

    function _donate(address user, address token, uint quantity) internal {
        uint ethValue = token == WETH ? convertWethToLP() : convertTokenToWethAndLP(token);

        _donations.push(Donation({
            user: user,
            token: token,
            quantity: quantity,
            ethValue: ethValue,
            timestamp: block.timestamp
        }));
        uint donationId = _donations.length - 1;
        _tokenDonations[token].add(donationId);
        _userDonations[user].add(donationId);

        emit Donate(donationId, user, token, quantity, ethValue, block.timestamp);
    }

    function convertTokenToWethAndLP(address token) public returns (uint) {
        uint256 tokenBalance = IERC20(token).balanceOf(address(this));
        require(tokenBalance > 0, "No tokens to sell");

        // Approve the router to spend the tokens
        IERC20(token).approve(address(SWAP_ROUTER), type(uint256).max);

        uint24 poolFee = getPoolFee(token);
        require(poolFee != 0, "Unable to convert donated token");

        // Perform the token-to-ETH swap
        SWAP_ROUTER.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: token,
                tokenOut: WETH,
                fee: poolFee,
                recipient: address(this),
                amountIn: tokenBalance,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        return convertWethToLP();
    }

    function convertWethToLP() public returns (uint) {
        uint donation = IERC20(WETH).balanceOf(address(this));
        uint guardianFee = donation / 10;
        uint ethBalance = donation - guardianFee;

        if (guardianFee > 0) {
            IWETH(WETH).withdraw(guardianFee);
            payGuardians();
        }

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
        if (LP_TOKEN_ID == 0) {
            (int24 minTick, int24 maxTick) = getPoolTicks(POOL_FEE);
            // Create a new full-range position
            (LP_TOKEN_ID, , , ) = POSITION_MANAGER.mint(
                INonfungiblePositionManager.MintParams({
                    token0: WETH < TOKEN ? WETH : TOKEN,
                    token1: WETH < TOKEN ? TOKEN : WETH,
                    fee: POOL_FEE,
                    tickLower: minTick,
                    tickUpper: maxTick,
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
                    tokenId: LP_TOKEN_ID,
                    amount0Desired: WETH < TOKEN ? halfEth : tokenAmount,
                    amount1Desired: WETH < TOKEN ? tokenAmount : halfEth,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp
                })
            );
        }
        _totalEthDonated += halfEth;
        _totalTokenDonated += tokenAmount;

        return donation;
    }

    function upgradeGovernance(address governance) external {
        require(msg.sender == _governance || msg.sender == owner(), "Not authorized");
        _governance = governance;
    }

    function collectFees() external {
        require(msg.sender == _governance, "Not authorized");

        INonfungiblePositionManager.CollectParams memory collectParams = INonfungiblePositionManager.CollectParams({
            tokenId: LP_TOKEN_ID,
            recipient: address(this),
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });
        POSITION_MANAGER.collect(collectParams);

        // All ETH LP Fees go to governance contract
        // To be split among squad, at schedule set there
        uint ethBalance = IWETH(WETH).balanceOf(address(this));
        if (ethBalance > 0) {
            IWETH(WETH).withdraw(ethBalance);
            (bool transferred,) = _governance.call{value: ethBalance}("");
            require(transferred, "Failed to send eth to governance");
            _ethPaidToGovernance += ethBalance;
        }

        // TOKEN Fees go to guardians
        // Paid instantly
        payGuardians();
    }

    // Allow the contract to receive ETH
    // Donate the ETH unless it is being unwrapped from WETH
    receive() external payable {
        if (msg.sender != WETH) {
            donate();
        }
    }

    // Send any ETH and TOKEN in the contract to guardians
    // 10% of all donations go to guardians
    // All LP Fees in TOKEN go to guardians
    function payGuardians() public {
        address[] memory guardians = IGovernance(_governance).getGuardians();
        if (guardians.length > 0) {
            uint ethBalance = address(this).balance;
            uint ethToSend = ethBalance / guardians.length;
            if (ethToSend > 0) {
                bool allTransferred = true;
                for (uint i = 0; i < guardians.length; i++) {
                    (bool transferred,) = guardians[i].call{value: ethToSend}("");
                    allTransferred = allTransferred && transferred;
                }
                require(allTransferred, "Unable to transfer eth");
                _ethPaidToGuardians += ethToSend;
            }
            IERC20 token = IERC20(TOKEN);
            uint tokenBalance = token.balanceOf(address(this));
            uint tokenToSend = tokenBalance / guardians.length;
            if (tokenToSend > 0) {
                bool allTransferred = true;
                for (uint i = 0; i < guardians.length; i++) {
                    allTransferred = allTransferred && token.transfer(guardians[i], tokenToSend);
                }
                require(allTransferred, "Unable to transfer token");
                _tokenPaidToGovernance += tokenToSend;
            }
        }
    }

    // Find the most liquid token/WETH pool
    // Checks UniswapV3 1%, 0.3%, 0.05% and 0.01% fee pools
    function getPoolFee(address token) public view returns (uint24 poolFee) {
        uint topPoolLiquidity = 0;
        address poolAddress = POOL_FACTORY.getPool(token, WETH, 10000);
        if (poolAddress != address(0)) {
            uint poolLiquidity = IERC20(WETH).balanceOf(poolAddress);
            if (topPoolLiquidity < poolLiquidity) {
                topPoolLiquidity = poolLiquidity;
                poolFee = 10000;
            }
        }
        poolAddress = POOL_FACTORY.getPool(token, WETH, 3000);
        if (poolAddress != address(0)) {
            uint poolLiquidity = IERC20(WETH).balanceOf(poolAddress);
            if (topPoolLiquidity < poolLiquidity) {
                topPoolLiquidity = poolLiquidity;
                poolFee = 3000;
            }
        }
        poolAddress = POOL_FACTORY.getPool(token, WETH, 500);
        if (poolAddress != address(0)) {
            uint poolLiquidity = IERC20(WETH).balanceOf(poolAddress);
            if (topPoolLiquidity < poolLiquidity) {
                topPoolLiquidity = poolLiquidity;
                poolFee = 500;
            }
        }
        poolAddress = POOL_FACTORY.getPool(token, WETH, 100);
        if (poolAddress != address(0)) {
            uint poolLiquidity = IERC20(WETH).balanceOf(poolAddress);
            if (topPoolLiquidity < poolLiquidity) {
                topPoolLiquidity = poolLiquidity;
                poolFee = 100;
            }
        }
    }

    function getPoolTicks(uint24 poolFee) public pure returns (int24, int24) {
        if (poolFee == 100) {
            return (-887272, 887272);
        } else if (poolFee == 500) {
            return (-887270, 887270);
        } else if (poolFee == 3000) {
            return (-887220, 887220);
        } else if (poolFee == 10000) {
            return (-887200, 887200);
        } else {
            revert("Unsupported pool fee");
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

    function getUserDonations(address user) external view returns (Donation[] memory) {
        uint[] memory donationIds = _userDonations[user].values();
        Donation[] memory donations = new Donation[](donationIds.length);
        for (uint i = 0; i < donationIds.length; i++) {
            donations[i] = _donations[i];
        }
        return donations;
    }
    function getUserDonationAt(address user, uint index) external view returns (Donation memory) {
        return _donations[_userDonations[user].at(index)];
    }
    function getNumUserDonations(address user) external view returns (uint) {
        return _userDonations[user].length();
    }

    function getTokenDonations(address token) external view returns (Donation[] memory) {
        uint[] memory donationIds = _tokenDonations[token].values();
        Donation[] memory donations = new Donation[](donationIds.length);
        for (uint i = 0; i < donationIds.length; i++) {
            donations[i] = _donations[i];
        }
        return donations;
    }
    function getTokenDonationAt(address token, uint index) external view returns (Donation memory) {
        return _donations[_tokenDonations[token].at(index)];
    }
    function getNumTokenDonations(address token) external view returns (uint) {
        return _tokenDonations[token].length();
    }

    function getDonations() external view returns (Donation[] memory) {
        return _donations;
    }

    function getDonationAt(uint index) external view returns (Donation memory) {
        return _donations[index];
    }

    function getNumDonations() external view returns (uint) {
        return _donations.length;
    }

    function getGovernance() external view returns (address) {
        return _governance;
    }

    function getTotalEthAndTokenFees() external view returns (uint, uint) {
        return WETH < TOKEN ? (_totalFees0, _totalFees1) : (_totalFees1, _totalFees0);
    }

    function getTotalEthAndTokenDonated() external view returns (uint, uint) {
        return (_totalEthDonated, _totalTokenDonated);
    }

    function getEthPaidToGuardians() external view returns (uint) {
        return _ethPaidToGuardians;
    }

    function getEthPaidToGovernance() external view returns (uint) {
        return _ethPaidToGovernance;
    }

    function getTokenPaidToGovernance() external view returns (uint) {
        return _tokenPaidToGovernance;
    }
}
