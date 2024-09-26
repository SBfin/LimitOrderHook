pragma solidity ^0.8.0;

// Foundry Libraries
import "forge-std/Test.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";

// Test ERC-20 token implementation
import {MockERC20} from "lib/periphery-next/lib/permit2/test/mocks/MockERC20.sol";

// Libraries
import {Currency, CurrencyLibrary} from "lib/periphery-next/lib/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "lib/periphery-next/lib/v4-core/src/types/PoolId.sol";
import {PoolKey} from "lib/periphery-next/lib/v4-core/src/types/PoolKey.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FixedPointMathLib} from "lib/periphery-next/lib/v4-core/lib/solmate/src/utils/FixedPointMathLib.sol";
import {StateLibrary} from "lib/periphery-next/lib/v4-core/src/libraries/StateLibrary.sol";

// Interfaces
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

// pool manager related contracts
import {PoolManager} from "v4-core/PoolManager.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

// our contracts
import {TakeProfitsHook} from "../src/TakeProfitsHook.sol";
import {TakeProfitsStub} from "../src/TakeProfitsStub.sol";    


// TO DO function cancel_order {}
// test_order_execute_zeroForOne()
// test_order_execute_oneForZero()

contract TakeProfitsHookTest is Test, GasSnapshot {
    using PoolIdLibrary for PoolKey;
    // Initialize BaseHook and ERC1155 parent contract in the constructor
    using CurrencyLibrary for Currency;
    using FixedPointMathLib for uint256;
    using StateLibrary for IPoolManager;

    function setUp() public {
        _deployERC20Tokens();
        poolManager = new PoolManager();
        _stubValidateHookAddress();
        _initializePool();
        _addLiquidityToPool();
    }

    // Hardcode the adress for our hook instead of deploying it
    TakeProfitsHook hook = 
        TakeProfitsHook(
            address(
                uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG)
            )
        );

    // poolManager is the Uniswap v4 Pool Manager
    PoolManager poolManager;

    // modifyLiquidityRouter is the test-version of the contract
    PoolModifyLiquidityTest modifyLiquidityRouter;

    // swapRouter is the test-version of the contract
    PoolSwapTest swapRouter;

    // token0 is the first token in the pool
    // token1 is the second token in the pool
    MockERC20 token0;
    MockERC20 token1;

    // poolKey and poolId are the pool key 
    PoolKey poolKey;
    PoolId poolId;

    // SQRT_RATIO_1_1 is the Q notation for sqrtPriceX96 where price = 1
    // i.e. sqrt(19 *2^96
    // This is used as the initial price for the pool
    // as we add equal amounts of tokens0 and token1 to the pool during set up
    uint160 constant SQRT_RATIO_1_1 = 79228162514264337593543950336;

    function _addLiquidityToPool() private {
        token0.mint(address(this), 100 ether);
        token1.mint(address(this), 100 ether);
        token0.approve(address(modifyLiquidityRouter), 100 ether);
        token1.approve(address(modifyLiquidityRouter), 100 ether);

        // add liquidity across different ticks
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams(-60, 60, 10 ether, ""),
            ""
        );

        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams(-120, 120, 10 ether, ""),
            ""
        );

        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams(TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 50 ether, ""),
            ""
        );

        // Approve the swapRouter to spend the tokens
        token0.approve(address(swapRouter), 100 ether);
        token1.approve(address(swapRouter), 100 ether);

    }


    function _initializePool() private {
        // deploy the test-versions of modifyLiquidityRouter and swapRouter
        modifyLiquidityRouter = new PoolModifyLiquidityTest(
            IPoolManager(address(poolManager))
        );

        swapRouter = new PoolSwapTest(
            IPoolManager(address(poolManager))
        );

        // Specify the pool key and poolid for the new pool
        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });

        poolId = poolKey.toId();

        // Initialize the new pool initial price ratio = 1
        poolManager.initialize(poolKey, SQRT_RATIO_1_1, "");

    }

    function _stubValidateHookAddress() private {
        // Deploy the TakeProfitsStub contract
        TakeProfitsStub stub = new TakeProfitsStub(poolManager, hook);

        //Fetch all the storage slot writes from the stub contract
        (, bytes32[] memory writes) = vm.accesses(address(stub));

        // 
        vm.etch(address(hook), address(stub).code);

        unchecked {
            for (uint256 i = 0; i < writes.length; i++) {
                bytes32 slot = writes[i];
                vm.store(address(hook), slot, vm.load(address(stub), slot));
            }
        }
    }

    function _deployERC20Tokens() private {
        MockERC20 tokenA = new MockERC20("tokenA", "A", 18);
        MockERC20 tokenB = new MockERC20("tokenB", "B", 18);

        // Token 0 and Token 1 are assigned in a pool based on the address of the token
        if (address(tokenA) < address(tokenB)) {
            token0 = tokenA;
            token1 = tokenB;
        } else {
            token0 = tokenB;
            token1 = tokenA;
        }
    }

    // ERC-1155 TOkens
    receive() external payable {}

    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return 
        bytes4(
            keccak256(
                "onERC1155Received(address,address,uint256,uint256,bytes)"
            )
        );
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return 
        bytes4(
            keccak256(
                "onERC1155BatchReceived(address,address,uint256[],uint256[],bytes)"
            )
        );
    }

    function test_placeOrder() public {
        int24 tick = 100;
        uint256 amount = 10 ether;
        bool zeroForOne = true;

        // Get the current balances of the tokens
        uint256 originalBalance = token0.balanceOf(address(this));

        // Place the order
        token0.approve(address(hook), amount);
        int24 tickLower = hook.placeOrder(poolKey, tick, amount, zeroForOne);

        uint256 newBalance = token0.balanceOf(address(this));

        assertEq(tickLower, 60);
        
        // Ensure that the amount of token0 has been deducted
        assertEq(originalBalance - amount, amount);

        // Chekc the balance of ERC-1155 received
        uint256 tokenId = hook.getTokenId(poolKey, tickLower, zeroForOne);
        uint256 tokenBalance = hook.balanceOf(address(this), tokenId);

        // Ensure that we were, in facet, given the ERC11 55 tokens for the order
        assertTrue(tokenId != 0);
        assertEq(tokenBalance, amount);


}



}