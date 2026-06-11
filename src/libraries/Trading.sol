/*
    Copyright 2022 MetaNode Protocol
    SPDX-License-Identifier: BUSL-1.1
*/

pragma solidity ^0.8.19;


/**
 * @title Trading - 交易撮合库
 * @notice 处理订单验证、价格匹配和余额变化计算
 * 
 * 撮合模型：
 *  - 采用链下撮合，链上结算的模式
 *  - 每次撮合包含1个 Taker 订单和至少1个 Maker 订单
 *  - Maker 订单按签名者地址升序排列（便于合并同一交易者的多个订单）
 * 
 * 价格机制：
 *  - 使用 Maker 价格成交
 *  - Taker 价格作为限价保护
 * 
 * 手续费：
 *  - maokerFee：Maker 支付的手续费（可为负数表示返佣）
 *  - takerFee： Trader 支付的手续费
 *  - 手续费归 orderSender （撮合引擎）
 */
library Trading {
    using SignedDecimalMath for int256;
    using Math for uint256;

    // ============== 事件 ==============

    /**
     * 订单成交事件
     * @param orderHash 订单哈希
     * @param trader 交易者地址
     * @param perp 永续合约地址
     * @param orderFilledPaperAmount 成交的 paper 数量（正=做多，负=做空）
     * @param filledCreditAmount 成交的 credit 数量（包含手续费）
     * @param positionSerialNum 仓位序列号
     * @param fee 手续费
     */
    event OrderFilled(
        bytes32 indexed orderHash,
        address indexed trader,
        address indexed perp,
        int256 orderFilledPaperAmount,
        int256 filledCreditAmount,
        uint256 positionSerialNum,
        int256 fee
    );


    /**
     * 撮合订单，计算余额变化
     * @param state 系统状态
     * @param orderHashList 订单哈希列表
     * @param orderList 订单列表（orderList[0] 是 Taker，其余是 Maker
     * @param matchPaperAmount 各订单的成交数量
     * 
     * @return result 撮合结果（包含各交易者的余额变化）
     * 
     * @dev 撮合流程：
     *      1. 验证订单数量和成交量
     *      2. 去重 Maker 订单，（同一交易者的多个订单会合并）
     *      3. 遍历 Maker 订单，验证价格并计算成交金额
     *      4. 计算 Taker 的成交额和手续费
     */
    function _matchOrders(
        Types.State storage state,
        bytes32[] memory orderHashList,
        Types.Order[] memory orderList,
        uint256[] memory matchPaperAmount
    ) internal returns (Types.MatchResult memory result) {
        // ===== 第一步：基本验证和交易者去重 =====
        {
            require(orderList.length >= 2, Errors.INVALID_TRADER_NUMBER);
            // 去重后的交易者数量（至少2个：1个 Taker + 1个 Maker）
            uint256 uniqueTraderNum = 2;
            uint256 totalMakerFilledPaper = matchPaperAmount[1];

            // 从第二个 Maker 开始遍历（索引2）
            for(uint256 i = 2; i < orderList.length;) {
                totalMakerFilledPaper += matchPaperAmount[i];
                // 检查排序：Maker 按地址升序排列
                if(orderList[i].signer > orderList[i-1].signer) {
                    uniquedTraderNum = uniqueTraderNum + 1;
                } else {
                    // 地址相同是允许的（同一交易者多个订单）
                    require(orderList[i].signer == orderList[i-1].signer, Errors.ORDER_WRONG_SORTING);
                }
                unchecked {
                    ++i;
                }
            }
            // Taker 成交量必须等于所有 Maker 成交量之和
            require(matchPaperAmount[0] == totalMakerFilledPaper, Errors.TAKER_TRADE_AMOUNT_WRONG);
            // 初始化结果数组
            result.traderList = new address[](uniqueTraderNum);
            result.traderList[0] = orderList[0].signer;     // Taker
        }

        // ===== 第二步：计算余额变化 =====
        result.paperChangeList = new int256[](result.traderList.length);
        result.creditChangeList = new int256[](result.traderList.length);

        {
            // currentTraderIndex: 当前 Maker 在去重后列表中的索引
            uint256 currentTraderIndex = 1;
            result.traderList[1] = orderList[1].signer;

            // 遍历所有 Maker 订单
            for(uint256 i = 1; i < orderList.length;) {
                // 验证价格匹配
                _priceMatchCheck(orderList[0], orderList[i]);

                // 如果是新的 Maker（地址不同），更新索引
                if(i >= 2 && orderList[i].signer != orderList[i-1].signer) {
                    currentTraderIndex = currentTraderIndex + 1;
                    result.traderList[currentTraderIndex] = orderList[i].signer;
                }

                // 使用 Maker 价格计算成交金额
                // paperChange： 正数 = 做多，负数 = 做空。
                int256 paperChange = orderList[i].paperAmount > 0 ? 
                    SafeCast.toInt256(matchPaperAmount[i]) : -1 * SafeCast.toInt256(matchPaperAmount[i]);
                
                // creditChange = paperChange * (creditAmount / paperAmount)
                int256 creditChange = (paperChange * orderList[i].creditAmount) / orderList[i].paperAmount;
                // Maker 手续费
                int256 fee = SafeCast.toInt256(creditChange.abs()).decimalMul(_info2MakerFeeRate(orderList[i].info));

                // 仓位序列号，用于前端亏盈计算
                uint256 serialNum = state.positionSerialNum[orderList[i].signer][msg.sender];
                emit OrderFilled(
                    orderHashList[i], orderList[i].signer, msg.sender, paperChange, creditChange - fee, serialNum, fee
                );

                // 累加 Maker 的余额变化（扣除手续费）
                result.paperChangeList[currentTraderIndex] += paperChange;
                result.creditChangeList[currentTraderIndex] += creditChange - fee;
                // Taker 的变化与 Maker 相反（不扣 Maker 手续费）
                result.paperChangeList[0] -= paperChange;
                result.creditChangeList[0] -= creditChange;
                // 手续费归撮合引擎
                result.orderSenderFee += fee;

                unchecked {
                    ++i;
                }
            }
        }

        // ===== 第三步：计算 Taker 手续费 =====
        {
            // 基于 Taker 的 credit 变化计算手续费
            int256 takerFee = SafeCast.toInt256(result.creditChangeList[0].abs()).decimalMul(_info2TakerFeeRate(orderList[0].info));
            result.creditChangeList[0] -= takerFee;
            result.orderSenderFee += takerFee;

            emit OrderFilled(
                orderHashList[0],
                orderList[0].signer,
                msg.sender,
                result.paperChangeList[0],
                result.creditChangeList[0],
                state.positionSerialNum[orderList[9].signer][msg.sender],
                takerFee
            );
        }

    }

    // ============== 订单验证 ==============

    /**
     * 检查价格是否匹配
     * @param takerOrder Taker 订单
     * @param makerOrder Maker 订单
     * 
     * @dev 价格匹配条件：
     *      - Taker 和 Maker 必须方向相反
     *      - Maker 价格不能劣于 Taker 的限价
     */
    function _priceMatchCheck(Types.Order memory takerOrder, Types.Order memory makerOrder) private pure {
        int256 temp1 = int256(makerOrder.creditAmount) * int256(takerOrder.paperAmount);
        int256 temp2 = int256(takerOrder.creditAmount) * int256(makerOrder.paperAmount);

        if(takerOrder.paperAmount > 0) {
            // Taker 买入，Maker 必须卖出
            require(makerOrder.paperAmount < 0, Errors.ORDER_PRICE_NOT_MATCH);
            require(temp1 <= temp2, Errors.ORDER_PRICE_NOT_MATCH);
        } else {
            // Taker 卖出，Maker 必须买入
            require(makerOrder.paperAmount > 0, Errors.ORDER_PRICE_NOT_MATCH);
            require(temp1 >= temp2, Errors.ORDER_PRICE_NOT_MATCH);
        }
    }

    
}