pragma solidity ^0.8.0;

import {BaseHook} from "lib/periphery-next/src/base/hooks/BaseHook.sol";
import {ERC1155} from "openzeppelin-contracts/contracts/token/ERC1155/ERC1155.sol";
import {IPoolManager} from "lib/periphery-next/lib/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "lib/periphery-next/lib/v4-core/src/libraries/Hooks.sol";
import {PoolId, PoolIdLibrary} from "lib/periphery-next/lib/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "lib/periphery-next/lib/v4-core/src/types/Currency.sol";
import {PoolKey} from "lib/periphery-next/lib/v4-core/src/types/PoolKey.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "lib/periphery-next/lib/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "lib/periphery-next/lib/v4-core/src/types/BalanceDelta.sol";
import {FixedPointMathLib} from "lib/periphery-next/lib/v4-core/lib/solmate/src/utils/FixedPointMathLib.sol";
import {StateLibrary} from "lib/periphery-next/lib/v4-core/src/libraries/StateLibrary.sol";
import {console} from "forge-std/console.sol";

contract TakeProfitsHook is BaseHook, ERC1155 {
    using PoolIdLibrary for PoolKey;
    // Initialize BaseHook and ERC1155 parent contract in the constructor
    using CurrencyLibrary for Currency;
    using FixedPointMathLib for uint256;
    using StateLibrary for IPoolManager;

    mapping(PoolId poolId => int24 tickLower) public tickLowerLasts;

    mapping(
        PoolId poolId =>
            mapping(int24 tick =>
                mapping(bool zeroForOne =>
                    int256 amount
                )
            )
    ) public takeProfitsPositions;

    // ERC-1155 State
    //tokenIdExists is a mapping to store whether a given tokenId (i.e. a take-profit order) exists
    mapping(uint tokenId => bool exists) public tokenIdExists;
    //tokenIdeClaimable is a mapping that stores how many swapped tokens are claimable for a given token
    mapping(uint256 tokenId => uint256 claimable) public tokenIdClaimable;
    //tokeIdTotalSupplyis a mapping that stores howmany tokens need to be sold to execute the take order
    mapping(uint256 tokenId => uint256 supply) public tokenIdTotalSupply;
    // tokenIdData is a mapping that stores the PoolKey, tickLower, and zero for one values for a given 
    mapping(uint256 tokenId => TokenData) public tokenIdData;


    struct TokenData {
        PoolKey poolKey;
        int24 tick;
        bool zeroForOne;
    }


    constructor(
        IPoolManager _poolManager,
        string memory _uri
    ) BaseHook(_poolManager) ERC1155(_uri) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return
        Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });

    }

    // Core utilities
    function placeOrder(
        PoolKey calldata key,
        int24 tick,
        uint256 amountIn,
        bool zeroForOne
    ) external returns (int24) {
        int24 tickLower = _getTickLower(tick, key.tickSpacing);

        takeProfitsPositions[key.toId()][tickLower][zeroForOne] += int256(amountIn);

        uint256 tokenId = getTokenId(key, tickLower, zeroForOne);

        if (!tokenIdExists[tokenId]) {
            tokenIdExists[tokenId] = true;
            tokenIdData[tokenId] = TokenData(key, tickLower, zeroForOne);
        }

        _mint(msg.sender, tokenId, amountIn, "");
        tokenIdTotalSupply[tokenId] += amountIn;

        address tokenToBeSoldContract = zeroForOne ? 
            Currency.unwrap(key.currency0)
            : Currency.unwrap(key.currency1);

        IERC20(tokenToBeSoldContract).transferFrom(
            msg.sender,
            address(this),
            amountIn
        );

        return tickLower;
    }

    function cancelOrder(
        PoolKey calldata key,
        int24 tick,
        bool zeroForOne) external {
            int24 tickLower = _getTickLower(tick, key.tickSpacing);
            uint256 tokenId = getTokenId(key, tickLower, zeroForOne);

            // balanceOf is coming from ERC-1155
            uint256 amountIn = balanceOf(msg.sender, tokenId);
            require(amountIn > 0, "no orders to cancel");

            takeProfitsPositions[key.toId()][tickLower][zeroForOne] -= int256(amountIn);
            tokenIdTotalSupply[tokenId] -= amountIn;
            _burn(msg.sender, tokenId, amountIn);

            address tokenToBeSoldContract = zeroForOne 
                ? Currency.unwrap(key.currency0)
                : Currency.unwrap(key.currency1);

            IERC20(tokenToBeSoldContract).transfer(msg.sender, amountIn);
        }
    

    // hooks REMOVING PoolManager only - add later
    function afterInitialize(address, PoolKey calldata key, uint160, int24 tick, bytes calldata) 
    external override returns (bytes4) {
        _setTickLowerLast(key.toId(), _getTickLower(tick, key.tickSpacing));

        return TakeProfitsHook.afterInitialize.selector;
    }

    function afterSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, BalanceDelta delta, bytes calldata) 
    external 
    override 
    returns (bytes4,int128) {
            int24 lastTickLower = tickLowerLasts[key.toId()];
            (, int24 currentTick, , ) = poolManager.getSlot0(key.toId());
            int24 currentTickLower = _getTickLower(currentTick, key.tickSpacing);

            bool swapZeroForOne = !params.zeroForOne;
            int256 swapAmountIn;

            console.log("lastTickLower: ", lastTickLower);
            console.log("currentTickLower: ", currentTickLower);
            console.log("swapZeroForOne: ", swapZeroForOne);

            // tick has increased
            if (lastTickLower < currentTickLower) {
                console.log("inside lastTickLower < currentTickLower");
                for (int24 tick = lastTickLower; tick < currentTickLower; ) {
                    swapAmountIn = takeProfitsPositions[key.toId()][tick][
                        swapZeroForOne
                    ];

                    if (swapAmountIn > 0) {
                        console.log("inside fillorder for swapAmountIn > 0");
                        fillOrder(key, tick, swapZeroForOne, swapAmountIn);
                    }

                    tick += key.tickSpacing;
                }
            } else {

                for (int24 tick = lastTickLower; tick > currentTickLower; ) {
                    swapAmountIn = takeProfitsPositions[key.toId()][tick][
                        swapZeroForOne
                    ];
                    console.log(swapAmountIn);
                    console.log(tick);

                    if (swapAmountIn > 0) {
                        console.log("inside fillorder for swapAmountIn > 0");
                        console.log(swapAmountIn);
                        fillOrder(key, tick, swapZeroForOne, swapAmountIn);
                        console.log("order filled");
                    }

                    tick -= key.tickSpacing;
                }

            }

            tickLowerLasts[key.toId()] = currentTickLower;

            console.log("end hook");

            return (TakeProfitsHook.afterSwap.selector, 0);
        }

    // fillorder
    function fillOrder(PoolKey calldata key,
    int24 tick,
    bool zeroForOne,
    int256 amountIn) internal {
        console.log("inside fillOrder");
        console.log("SwapParams of the order:");
        console.log("amountIn", amountIn);
        console.log("zeroForOne: ", zeroForOne);
        uint160 sqrtPriceLimit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        console.log("sqrtPriceLimit: ", sqrtPriceLimit);

        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountIn,
            sqrtPriceLimitX96: sqrtPriceLimit
        });

        BalanceDelta delta = this._handleSwap(key, swapParams);

        takeProfitsPositions[key.toId()][tick][zeroForOne] -= amountIn;

        uint256 tokenId = getTokenId(key, tick, zeroForOne);

        uint256 amountOfTokensReceivedFromSwap = zeroForOne
            ? uint256(int256(-delta.amount1()))
            : uint256(int256(-delta.amount0()));
        
        tokenIdClaimable[tokenId] += amountOfTokensReceivedFromSwap;

    }

    function redeem(
        uint256 tokenId,
        uint256 amountIn,
        address destination
    ) external {
        require(
        tokenIdClaimable[tokenId] > 0,
        "TakeProfitsHook: No tokens to redeem");

        uint256 balance = balanceOf(msg.sender, tokenId);
        require(
            balance >= amountIn,
            "TakeProfitsHook: Not enough ERC-1155 tokens to redeem requrested amount"
        );

        TokenData memory data = tokenIdData[tokenId];
        address tokenToSendContract = data.zeroForOne
            ? Currency.unwrap(data.poolKey.currency1)
            : Currency.unwrap(data.poolKey.currency0);
        
        // users withdraw is shares
        uint256 amountToSend = amountIn.mulDivDown(
            tokenIdClaimable[tokenId],
            tokenIdTotalSupply[tokenId]
        );

        tokenIdClaimable[tokenId] -= amountToSend;
        tokenIdTotalSupply[tokenId] -= amountIn;
        _burn(msg.sender, tokenId, amountIn);

        IERC20(tokenToSendContract).transfer(destination, amountToSend);

    }

    function _handleSwap(PoolKey calldata key, 
    IPoolManager.SwapParams calldata params) 
    external returns (BalanceDelta) {

        console.log("Inside _handleswap");

        BalanceDelta delta = poolManager.swap(key, params, "");

        console.log("delta.amount0: ", delta.amount0());
        console.log("delta.amount1: ", delta.amount1());
        console.log("zeroForOne: ", params.zeroForOne);

        if (params.zeroForOne) {
            if (delta.amount0() > 0) {
                IERC20(Currency.unwrap(key.currency0)).transfer(address(poolManager), uint128(delta.amount0())
                );
                poolManager.settle();
            }

            if (delta.amount1() < 0) {
                poolManager.take(
                    key.currency1,
                    address(this),
                    //flip the sign
                    uint128(-delta.amount1())
                );
            }
            

        } else {
            if (delta.amount1() > 0) {
                IERC20(Currency.unwrap(key.currency0)).transfer(address(poolManager), uint128(delta.amount0())
                );
                poolManager.settle();
            }

            if (delta.amount0() < 0) {
                console.log("settling");
                poolManager.take(
                    key.currency1,
                    address(this),
                    //flip the sign
                    uint128(-delta.amount1())
                );
            }

        }

        return delta;
    }

    // ERC-1155 helpers
    function getTokenId(
        PoolKey calldata key,
        int24 tickLower,
        bool zeroForOne
    ) public pure returns (uint256) {
        return
            uint256(
                keccak256(abi.encodePacked(key.toId(), tickLower, zeroForOne))
            );
    }

    // helper functions
    function _setTickLowerLast(PoolId poolId, int24 tickLower) private {
        tickLowerLasts[poolId] = tickLower;
    }

    function _getTickLower(int24 actualTick, int24 tickSpacing) private pure returns (int24) {
        int24 intervals = actualTick / tickSpacing;
        if (actualTick < 0 && (actualTick % tickSpacing) != 0) {
            intervals--;
        }
        return intervals * tickSpacing;
    }

}