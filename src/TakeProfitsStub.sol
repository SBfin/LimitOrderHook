// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {TakeProfitsHook} from "./TakeProfitsHook.sol";
import {BaseHook} from "lib/periphery-next/src/base/hooks/BaseHook.sol";
import {IPoolManager} from "lib/periphery-next/lib/v4-core/src/interfaces/IPoolManager.sol";

contract TakeProfitsStub is TakeProfitsHook {
    constructor(
        IPoolManager _poolManager,
        TakeProfitsHook addressToEtch
    ) TakeProfitsHook(_poolManager, "") {}

    // make this a no-op in testing
    function validateHookAddress(BaseHook _this) internal pure override {}
}