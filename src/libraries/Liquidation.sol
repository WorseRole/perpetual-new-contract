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
    event ChangeInsurance(address perp, address indexed liquidatedTrader, uint256 fee);

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
     * 
     * @param state 系统状态
     * @param perp 永续合约地址
     * @param liquidatedTrader 被清算者地址
     * @param requestPaperAmount 请求清算的数量
     * @return liqtorPaperChange 清算者的paper 变化
     * @return liqtorCreditChange 清算者的credit 变化
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

    }

}