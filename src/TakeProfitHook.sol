pragma solidity ^0.8.0;

import {BaseHook} from "lib/periphery-next/src/base/hooks/BaseHook.sol";
import {ERC1155} from "openzeppelin-contracts/contracts/token/ERC1155/ERC1155.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolId, PoolIdLibrary} from "lib/periphery-next/lib/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "lib/periphery-next/lib/v4-core/librariees/CurrencyLibrary.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

contract TokenProfitsHook is BaseHook, ERC1155 {
    using PoolIdLibrary for IPoolManager.PoolKey;
    // Initialize BaseHook and ERC1155 parent contract in the constructor
    using CurrencyLibrary for Currency;
    using FixedPointMathLib for uint256;

    mapping(PoolId poolId => int24 tickLower) public tickLowerLasts;

    mapping(
        PoolId poolId =>
            mapping(int24 tick =>
                mapping(bool zeroForOne =>
                    int256 amount
                )
            )
    ) public takeProfitPositions;

    // ERC-1155 State
    //tokenIdExists is a mapping to store whether a given tokenId (i.e. a take-profit order) exists
    mapping(uint tokenId => bool exists) public tokenIdExists;
    //tokenIdeClaimable is a mapping that stores how many swapped tokens are claimable for a given token
    mapping(uint256 tokenId => uint256 claimable) public tokenIdClaimable;
    //tokeIdTotalSupplyis a mapping that stores howmany tokens need to be sold to execute the take order
    mapping(uint256 tokenId => uint256 supply) public tokenIdTotalSupply;
    // tokenIdData is a mapping that stores the PoolKey, tickLower, and zero for one values for a given 
    mapping(uint256 tokenId => tokenData) public tokenIdData;



    constructor(
        IPoolManager _poolManager,
        string memory _uri
    ) BaseHook(_poolManager) ERC1155(_uri) {}

    function getHooksCalls() public pure override returns (Hooks.Calls memory) {
        return
        Hooks.Calls({
            beforeInitialize: false,
            afterInitialize: true,
            beforeModifyPosition: false,
            afterModifyPosition: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false
        });

    }

    // Core utilities
    function PlaceOrder(
        IPoolManger.Poolkey calldata key,
        int24 tick,
        uint256 amountIn,
        bool zeroForOne
    ) external returns (int24) {
        int24 tickLower = _getTickLower(tick, key.tickSpacing, tickSpacing);

        takeProfitPositions[key.toId()][tickLower][zeroForOne] += int256(amountIn);

        uint256 tokenId = getTokenId(key, tickLower, zeroForOne);

        if (!tokenIdExists[tokenId]) {
            tokenIdExists[tokenId] = true;
            tokenIdData[tokenId] = tokenData(key, tickLower, zeroForOne);
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
        IPoolManager.PoolKey calldata key,
        int24 tick,
        bool zeroForOne) external {
            int25 tickLower = _getTickLower(tick, key.TickSpacing);
            uint256 tokenId = getTokenId(key, tickLower, zeroForOne);

            // balanceOf is coming from ERC-1155
            uint256 amountIn = balanceOf(msg.sender, tokenId);
            require(amountIn > 0, "no orders to cancel");

            takeProfitPosition[key.toId()][tickLower][zeroForOne] -= int256(amountIn);
            tokenIdTotalSupply[tokenId] -= amountIn;
            _burn(msg.sender, tokenId, amountIn);

            address tokenToBeSoldContract = zeroForOne 
                ? Currency.unwrap(key.currency0)
                : Currency.unwrap(key.currency1);

            IERC20(tokenToBeSoldContract).transfer(msg.sender, amountIn);
        }
    

    // hooks
    function afterInitialize(address, IPoolManager.PoolKey calldata key, uint160, int24 tick) 
    external override poolManagerOnly returns (bytes4) {
        _setTickLowerLast(key.toId(), _getTickLower(tick, key.tickSpacing));

        return TakeProfitsHooks.afterInitialize.selector;
    }

    function afterSwap(address, IPoolManger.PoolKey calldata key,
        IPoolManger.SwapParams calldata params,
        BalanceDelta) external override poolManagerOnly returns (bytes4) {
            int24 lastTickLower = tickLowerLasts[key.toId()];
            (, int24 currentTick, , , ,) = poolManager.getSlot0(key.toId());
            int24 currentTickLower = _getTickLower(currentTick, key.tickSpacing);

            bool swapZeroForOne = !params.zeroForOne;
            int256 swapAmountIn;

            // tick has increased
            if (lastTickLower < currentTickLower) {

                for (int24 tick = lastTickLower; tick < currentTickLower; ) {
                    swapAmountIn = takeProfitPositions[key.toId()][tick][
                        swapZeroForOne
                    ];

                    if (swapAmountIn > 0) {
                        fillOrder(key, tick, swapZeroForOne, swapAmountIn);
                    }

                    tick += key.tickSpacing;
                }
            } else {

                for (int24 tick = lastTickLower; tick > currentTickLower; ) {
                    swapAmountIn = takeProfitPositions[key.toId()][tick][
                        swapZeroForOne
                    ];

                    if (swapAmountIn > 0) {
                        fillOrder(key, tick, swapZeroForOne, swapAmountIn);
                    }

                    tick -= key.tickSpacing;
                }

            }

            tickLowerLasts[key.toId()] = currentTickLower;

            return TakeProfitHoks.afterSwap.selector;
        }

    // fillorder
    function fillOrder(IPoolManager.PoolKey calldata key,
    int24 tick,
    bool zeroForOne,
    int256 amountIn) internal {
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountIn,
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_RATIO + 1
                : TickMath.MAX_SQRT_RATIO - 1
        });

        balanceDelta delta = abi.decode(
            poolMager.lock(
                abi.encodeCall(this._handleSwap, (key, swapParams))
            ),
            (balanceDelta)
        );

        tokenProfitPostiions[key.toId()][tick][zeroForOne] -= amountIn;

        uint256 tokenId = getTokenId(key, tick, zeroForOne);

        uint256 amountOfTokensReceivedFromSwap = zeroForOne
            ? uint256(int256(-delta.amount1()))
            : uint256(int256(-delta.amount0()));
        
        tokenIdClaimable[tokenId] += amountOfTokensReceivedFromSwaps;
    }

    function redeem(
        uint256 tokenId,
        uint256 amountIn,
        address destination
    ) external (
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
        _bunr(msg.sender, tokenId, amountIn);

        IERC20(tokenToSendContract).transfer(destination, amountToSend);

    )

    function _handleSwap(IPoolManager.PoolKey calldata key, 
    IPoolManager.SwapParams calldata params) 
    external returns (BalanceDelta) {
        BalanceDelta delta = poolManager.swap(key, params);

        if (params.zeroForOne) {
            if (delta.amount0() > 0) {
                IERC20(Currency.unwrap(key.currency0)).transfer(address(poolManager), uint128(delta.amount0())
                );
                poolManager.settle(key.currency0);
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
                poolManager.settle(key.currency0);
            }

            if (delta.amount0() < 0) {
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
        IpoolManager.Poolkey calldata key,
        int24 tickLower,
        bool zeroForOne
    ) public pure returns (uint256) {
        return
            uint256(
                keccack256(abi.encodePacked(key.toId(), tickLower, zeroForOne))
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