/*
    Copyright 2022 MetaNode Protocol
    SPDX-License-Identifier: BUSL-1.1
*/

pragma solidity ^0.8.19;

import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "../interfaces/internal/IPriceSource.sol";
import "../interfaces/IPerpetual.sol";
import "../libraries/SignedDecimalMath.sol";
import "../libraries/Errors.sol";
import "./Types.sol";
import "./Position.sol";


/**
 * @title Liquidation - 清算管理库
 * @notice 处理交易者的风险检查和清算执行
 * 
 * 核心概念：
 * - netValue：净值 = 账户余额 + 所有仓位的未实现盈亏
 * - exposure：敞口 = 所有仓位价值的绝对值之和
 * - initialMargin：初始保证金 = exposure * initialMarginRatio
 * - maintenanceMargin： 维持保证金 = exposure * liquidationThreshold
 * 
 * 安全状态：
 * - MM Safe: netValue >= initialMargin
 * - IM Safe: netValue >= initialMargin
 * - Solid IM Safe: IM Safe + (netValue - secondaryCredit >= 0)
 * 
 * 清算流程：
 * 1. 当交易者 MM 不安全时，任何人可以清算其仓位
 * 2. 清算者一折扣价格接手被清算者的仓位
 * 3. 保险费从被清算者收取，转入保险账户
 * 4. 如果清算后被清算者余额为负，保险账户承担坏账
 */
library Liquidation {
    using SignedDecimalMath for int256;

    // =============== 事件 ===============

    /**
     * @notice 被清算事件
     * @param perp 永续合约地址
     * @param liquidatedTrade 被清算者
     * @param paperChange paper 变化
     * @param creditChange credit 变化
     * @param positionSerialNum 仓位序列号
     */
    event BeingLiquidated(
        address indexed perp,
        address indexed liquidatedTrade,
        int256 paperChange,
        int256 creditChange,
        uint256 positionSerialNum
    );

    /**
     * 执行清算事件
     * @param perp 永续合约地址
     * @param liquidator 清算者
     * @param liquidatedTrader 被清算者
     * @param paperChange 清算者的 paper 变化
     * @param creditChange 清算者的 credit 变化
     * @param positionSerialNum 仓位序列号
     */
    event JoinLiquidation(
        address indexed perp,
        address indexed liquidator,
        address indexed liquidatedTrader,
        int256 paperChange,
        int256 creditChange,
        uint256 positionSerialNum
    );

    /**
     * 收取保险费事件
     * @param perp 永续合约地址
     * @param liquidatedTrader 被清算者
     * @param fee 保险费金额
     */
    event ChargeInsurance(address perp, address indexed liquidatedTrader, uint256 fee);

    /**
     * 处理坏账事件
     * @param liquidatedTrader 被清算者
     * @param primaryCredit 主资产余额（负数表示坏账）
     * @param secondaryCredit 次级资产余额
     */
    event HandleBadDebt(address indexed liquidatedTrader, int256 primaryCredit, uint256 secondaryCredit);


    // =============== 安全检查函数 ===============

    /**
     * @notice 获取交易者的总敞口和风险指标
     * @param state 系统状态
     * @param trader 交易者地址
     * @return netValue 净值（余额 + 未实现盈亏）
     * @return exposure 总敞口（仓位价值绝对值之和）
     * @return initialMargin 所需初始保证金
     * @return maintenanceMargin 所需维持保证金
     * 
     * @dev 计算过程：
     *          1. 遍历所有持仓市场
     *          2. 对每个市场：获取仓位、计算价值、累加敞口和保证金
     *          3. 净值 = 仓位价值 + 账户余额
     */
    function getTotalExposure(
        Types.State storage state, 
        address trader) 
        public view returns (int256 netValue, uint256 exposure, uint256 initialMargin, uint256 maintenanceMargin) {
            int256 netPositionValue;

            // 遍历所有持仓市场，计算净值和敞口
            for(uint256 i = 0; i < state.openPosition[trader].length;) {
                // 获取仓位余额
                (int256 paperAmount, int256 creditAmount) = IPerpetual(state.openPositions[trader][i]).balanceOf(trader);
                Types.RiskParams storage params = state.perpRiskParams[state.openPositions[trader][i]];
                // 获取标记价格
                int256 price = SafeCast.toInt256(IPriceSource(params.markPriceSource).getMarkPrice());

                // 仓位价值 = paper * markPrice + reducedCredit
                netPositionValue += paperAmount.decimalMul(price) + creditAmount;
                // 敞口 = | paper * price |
                uint256 exposureIncrement = paperAmount.decimalMul(price).abs();
                // 计算所需保证金
                maintenanceMargin += (exposureIncrement * params.liquidationThreshold) /Types.ONE;
                initialMargin += (exposureIncrement * params.initialMarginRatio) / Types.ONE;
                unchecked {
                    ++i;
                }
            }
            // 净值 = 仓位价值 + 主资产余额 + 次级资产余额
            netValue = netPositionValue + state.primaryCredit[trader] + SafeCast.toInt256(state.secondaryCredit[trader]);
    }


    /**
     * @notice 检查交易者是否满足维持保证金要求
     * @param state 系统状态
     * @param trader 交易者地址
     * @return 是否 MM 安全（不会被清算）
     */
    function _isMMSafe(Types.State storage state, address trader) internal view returns (bool) {
        (int256 netValue, , , uint256 maintenanceMargin) = getTotalExposure(state, trader);
        return netValue >= SafeCast.toInt256(maintenanceMargin);
    }

    /**
     * 检查交易者是否满足初始保证金要求
     * @param state 系统状态
     * @param trader 交易者地址
     * @return 是否 IM 安全（可以开新仓）
     */
    function _isIMSafe(Types.State storage state, address trader) internal view returns (bool) {
        (int256 netValue, , uint256 initialMargin, ) = getTotalExposure(state, trader);
        return netValue >= SafeCast.toInt256(initialMargin);
    }

    /**
     * @notice 更严格的安全检查（用于取款主资产时）
     * @param state 系统状态
     * @param trader 交易者地址
     * @return 是否 Solid IM 安全
     * 
     * @dev 额外要求：netPositionValue + primaryCredit >= 0
     *      即不能依赖次级资产来满足初始保证金。
     */
    function _isSolidIMSafe(Types.State storage state, address trader) internal view returns (bool) {
        (int256 netValue, , uint256 initialMargin,) getTotalExposure(state, trader);
        // 净值减去次级资产后仍需 >= 0, 净值需要 >= 初始化保证金
        return netValue - SafeCast.toInt256(state.secondaryCredit[trader]) >= 0 && netValue >= SafeCast.toInt256(initialMargin);
    }

    /**
     * 批量检查所有交易者是否 MM 安全
     * @param state 系统状态
     * @param traderList 交易者列表
     * @return 是否全部安全
     */
    function _isAllMMSafe(Types.State storage state, address[] calldata traderList) internal view returns (bool) {
        for (uint256 i = 0; i < traderList.length;) {
            address trader = traderList[i];
            if(!_isMMSafe(state, trader)) {
                return false;
            }
            unchecked {
                ++i;
            }
        }
        return true;
    }


    /**
     * 查询用 的 view 接口，给前端/后端或风控系统调的
     * @notice 计算清算价格
     * @param state 系统状态
     * @param trader 交易者地址
     * @param perp 永续合约地址
     * @return liquidationPrice 清算价格
     * 
     * @dev 返回 0 的含义：
     *      - 没有仓位
     *      - 绝对安全（永远不会被清算）
     *      - 已经处于被清算状态
     * 
     * 计算逻辑：
     *  为避免清算，需要 netValue >= maintenanceMargin
     *  对于特定市场的仓位，推导出使等式成立的价格
     * 
     * 公式推导在代码注释
     */
    function getLiquidationPrice(Types.State storage state, address trader, address perp) 
        external view returns (uint256 liquidationPrice) {

    }


    /**
     * 计算清算金额
     * @param state 系统状态
     * @param perp 永续合约地址
     * @param liquidatedTrader 被清算者地址
     * @param requestPaperAmount 请求清算的数量
     * 
     * @return liqtorPaperChange 清算者的 paper 变化
     * @return liqtorCreditChange 清算者的 credit 变化
     * @return insuranceFee 保险费
     * 
     * @dev 使用固定折扣价格模型：
     *      - 清算多头：markPrice * （1 - liquidationPriceOff）
     *      - 清算空头：markPrice * （1 + liquidationPriceOff）
     *      清算数量会被限制在实际仓位大小内
     */
    function getLiquidateCreditAmount(
        Types.State storage state, 
        address perp, 
        address liquidatedTrader, 
        int256 requestPaperAmount) public view 
        returns (int256 liqtorPaperChange, int256 liqtorCreditChange, uint256 insuranceFee) {
            // 检查被清算者是否真的不安全
            require(!is_MMSafe(state, liquidatedTrader), Errors.ACCOUNT_IS_SAFE);

            // 获取并验证仓位
            (int256 brokenPaperAmount) = IPerpetual(perp).balanceOf(liquidatedTrader);
            require(brokenPaperAmount != 0, Errors.TRADER_HAS_NO_POSITION);

            // 清算方向必须与仓位方向一致
            require(brokenPaperAmount * requestPaperAmount > 0, Errors.LIQUIDATION_REQUEST_AMOUNT_WRONG);
            // 限制清算数量不超过实际仓位
            liqtorPaperChange = requestPaperAmount,abs() > brokenPaperAmount.abs() ? brokenPaperAmount : requestPaperAmount.abs();

            // 计算清算价格
            Types.RiskParams storage params = state.perpRiskParams[perp];
            uint256 price = IPriceSource(params.markPriceSource).getMarkPrice();
            uint256 priceOffset = price * params.liquidationPriceOff / Types.ONE;
            // 清算多头给折扣价（低于市价），清算空头加溢价（高于市价）
            price = liqtorPaperChange > 0 ? price - priceOffset : price + priceOffset;

            // 计算 credit 变化：清算者付出 credit 获得 paper
            liqtorCreditChange = -1 * liqtorPaperChange.decimalMul(SafeCast.toInt256(price));

            // 计算保险费: 清算者的 credit 变化 * 保险费率
            insuraceFee = (liqtorCreditChange.abs() * params.insuranceFeeRate) / Types.ONE;
    }


    /**
     * @notice 执行清算请求
     * @param state 系统状态
     * @param perp 永续合约地址
     * @param executor 清算执行者
     * @param liquidator 清算者
     * @param liquidatedTrader 被清算者
     * @param requestPaperAmount 请求清算的数量
     * 
     * @return liqtorPaperChange 清算者的 paper 变化
     * @return liqtorCrediChange 清算者的 credit 变化
     * @return liqedPaperChange 被清算者的 paper 变化
     * @return liqedCreditChange 被清算者的 credit 变化
     * 
     * @dev 执行流程：
     *      1. 验证执行者权限
     *      2. 计算清算金额
     *      3. 保险费转入保险账户
     *      4. 触发清算事件
     */
    function requestLiquidation(
        Types.State storage state,
        address perp,
        address executor,
        address liquidator,
        address liquidatedTrader,
        int256 requestPaperAmount
    ) external returns (int256 liqtorPaperChange, int256 liqtorCrediChange, int256 liqedPaperChange, int256 liqedCreditChange) {
        // 验证执行者权限：必须是清算者本人或其授权操作人员
        require(
            executor == liquidator || state.operatorRegistry[liquidator][executor], Errors.INVALID_LIQUIDATION_EXECUTOR
        );

        // 禁止自我清算
        require(liquidatedTrader != liquidator, Errors.SELF_LIQUIDATION_NOT_ALLOWED);

        // 计算清算金额
        uint256 insuranceFee;
        (liqtorPaperChange, liqtorCreditChange, insuranceFee) = 
            getLiquidateCreditAmount(state, perp, liquidatedTrader, requestPaperAmount);
        
        // 保险费转入保险账户
        state.primaryCredit[state.insurance] += SafeCast.toInt256(insuranceFee);

        // 计算被清算者的变化（与清算者相反，另外扣除保险费）
        liqedCreditChange = liqtorCreditChange * -1 - SafeCast.toInt256(insuranceFee);
        liqedPaperChange = liqtorPaperChange * -1;

        // 更新仓位        
        uint256 ltSN = state.positionSerialNum[liquidatedTrader][perp];
        uint256 liquidatorSN = state.positionSerialNum[liquidator][perp];
        // 被清算事件
        emit BeingLiquidated(perp, liquidatedTrader, liqedPaperChange, liqedCreditChange, ltSN);
        // 清算事件
        emit JoinLiquidation(perp, liquidator, liquidatedTrader, liqtorPaperChange, liqtorCreditChange, liquidatorSN);
        // 清算保险费
        emit ChargeInsurance(perp, liquidatedTrader, insuranceFee);
    }

    /**
     * @notice 获取标记价格
     * @param state 系统状态
     * @param prep 永续合约地址
     * @return price 标记价格
     */
    function getMarkPrice(Types.State storage state, address prep) external view returns (uint256 price) {
        price = IPriceSource(state.perpRiskParams[perp].markPriceSource).getMarkPrice();
    }

    /**
     * @notice 处理坏账
     * @param state 系统状态
     * @param liquidatedTrader 被清算者地址
     * 
     * @dev 当交易者所有仓位清空但余额为负时：
     *      1. 将负余额（坏账）转移给保险账户
     *      2. 保险账户承担损失
     *      3. 被清算者余额归零
     */
    function handleBadDebt(Types.State storage state, address liquidatedTrader) external {
        // 只有放所有仓位已清空且账户不安全时才处理
        if(state.openPositions[liquidatedTrader].length == 0 && 
                !Liquidation._isMMSafe(state, liquidatedTrader)) {
            int256 primaryCredit = state.primaryCredit[liquidatedTrader];
            int256 secondaryCredit = state.secondaryCredit[liquidatedTrader];
            // 清空被清算者余额
            state.primaryCredit[liquidatedTrader] = 0;
            state.secondaryCredit[liquidatedTrader] = 0;
            // 坏账转入保险账户（负数意味着保险账户承担损失）
            state.primaryCredit[state.insurance] += primaryCredit;
            state.secondaryCredit[state.insurance] += secondaryCredit;
            emit HandleBadDebt(liquidatedTrader, primaryCredit, secondaryCredit);
        }
    }

}