/*
    Copyright 2022 MetaNode Protocol
    SPDX-License-Identifier: BUSL-1.1
*/

pragma solidity ^0.8.19;

import "./interfaces/IDealer.sol";
import "./libraries/Liquidation.sol";
import "./libraries/Position.sol";
import "./libraries/Types.sol";


abstract contract MetaNodeExternal is MetaNodeStorage, IDealer {
    using SignedDecimalMath for int256;
    using SafeERC20 for IERC20;

    // ==================== 资金相关函数 ====================

    /**
     * 存入保证金
     * @param primaryAmount 主资产（USDC）数量
     * @param secondaryAmount 次级资产数量（如果有）
     * @param to 存入的目标账户地址
     * 
     * @dev 用户将资产从钱包转入交易系统，获得交易所需的保证金
     */
    function deposit(uint256 primaryAmount, uint256 secondaryAmount, address to) external nonReentrant {
        Funding.deopsit(state, primaryAmount, secondaryAmount, to);
    }

    /**
     * 请求取款（第一步）
     * @param from 取款来源账户
     * @param primaryAmount 主资产取款数量
     * @param secondaryAmount 次级资产取款数量
     * 
     * @dev 取款分两步：先请求，等待时间锁后再执行
     *      时间锁设计是为了防止再订单成交前取走保证金
     */
    function requestWithdraw(address from, uint256 primaryAmount, uint256 secondaryAmount) external nonReentrant {
        Funding.requestWithdraw(state, from, primaryAmount, secondaryAmount);
    }

    /**
     * 执行取款（第二步）
     * @param from 取款来源账户
     * @param to 资金接收地址
     * @param isInternal 是否为内部转账（不转出合约，只转给另一个账户）
     * @param param 回调参数
     * 
     * @dev 在时间锁到期后执行实际的资金转出
     */
    function executeWithdraw(address from, address to, bool isInternal, bytes memory param) external nonReentrant {
        Funding.executeWithdraw(state, from, to, isInternal, param);
    }
    
    
    // ==================== 仅限已注册永续合约调用 ====================

    /**
     * 批准交易（核心撮合函数，由 Perpetual 合约调用）
     * @param orderSender 订单发送者地址（撮合引擎）
     * @param tardeData 编码的交易数据，包含订单列表、签名、成交数量
     * 
     * @return tradeList 参与交易的交易者列表
     * @return paperChangeCredit 各交易者的 paper （仓位数量）变化
     * @return creditChangeList 各交易者的 credit（资金）变化
     * 
     * @dev 核心交易流程：
     *  1. 解码交易数据，获取订单列表、签名、成交数量
     *  2. 验证每个订单：
     *      - 签名验证（支持 EOA 签名和合约签名 EIP-1271）
     *      - 订单未过期
     *      - 订单价格有效 （peper 和 credit 异号）
     *      - 订单未超额提交
     *      - 防止自成交
     *  3. 撮合订单，计算各方的 paper 和 credit 变化
     *  4. 收取手续费给 orderSender
     *  5. 检查 orderSender 安全性（如果需要支付手续费）
     */
    function approveTrade (address orderSender, bytes calldata tardeData) external onlyRegisteredPerp returns (
            address[] memory,   // 交易者列表
            int256[] memory,    // paper （仓位数量） 变化列表
            int256[] memory     // credit （资金） 变化列表
        ) {
            // 验证订单发送者是否为授权的撮合引擎
            require(state.validOrderSender[orderSender], Errors.INVALID_ORDER_SENDER);

            /**
             * 解析交易数据
             * 传入所有需要撮合的订单及其签名
             * 以及咩哥订单要成交的数量
             */
            (Types.Order[] memory orderList, bytes[] memory signatureList, uint256[] memory matchPaperAmount) = abi.decode(tradeData, (Types.Order[], bytes[], uint256[]));
            bytes32[] memory orderHashList = new bytes32[](orderList.length);

            // 验证所有订单
            for(uint256 i = 0; i < orderList.length;) {
                Types.Order memory order = orderList[i];
                // 计算订单哈希（用于签名验证和订单追踪）
                bytes32 orderHash = EIP712._hashTypedDataV4(domainSeparator, Trading._structHash(order));
                orderHashList[i] = orderHash;

                // 验证签名
                (address recoverSigner, ) = ECDSA.tryRecover(orderHash, signatureList[i]);
                // 签名者必须是订单所有者或其授权的操作员
                if(recoverSinger != order.signer && !state.operatorRegistry[order.signer][recoverSigner]) {
                    // 如果签名者是合约，使用 EIP-1271 标准验证
                    if(Address.isContract(order.signer)) {
                        require(
                            IERC1271(order.signer),isValidSignature(orderHash, signatureList[i]) == 0x1626ba7e,
                            Errors.INVALID_ORDER_SIGNATURE
                        );
                    } else {
                        revert(Errors.INVALID_ORDER_SIGNATURE);
                    }
                }

                // 验证订单基本要求 订单是否过期
                require(Trading._info2Expiration(order.info) >= block.timestamp, Errors.ORDER_EXPIRED);
                // paper 和 credit 必须是异号
                require(
                    (order.paperAmount < 0 && order.creditAmount > 0) || (order.paperAmount > 0 && order.creditAmount < 0),
                    Errors.ORDER_PRICE_NEGATIVE
                );
                // 订单必须属于当前调用的永续合约
                require(order.perp == msg.sender, Errors.PERP_MISMATCH);
                // 防止自成交（第一个订单的签名者不能与后续订单相同）
                require(i == 0 || order.signer != orderList[0].signer, Errors.ORDER_SELF_MATCH);

                // 更新订单已成交数量
                state.orderFilledPaperAmount[orderHash] += matchPaperAmount[i];
                // 检查是否超额提交
                require(
                    state.orderFilledPaperAmount[orderHash] <= int256(orderList[i].paperAmount).abs(),
                    Errors.ORDER_FILLED_OVERFLOW
                );
                unchecked {
                    ++i;
                }
            }

            // 执行订单撮合，计算各方变化
            Types.MatchResult memory result = Trading._matchOrders(state, orderHashList, orderList, matchPaperAmount);

            // 收取手续费给订单发送者（撮合引擎）
            state.primaryCredit[orderSender] += result.orderSenderFee;
            // 如果订单发送者需要支付手续费（负数），检查其账户安全性
            if(result.orderSenderFee < 0) {
                require(Liquidation.is_SolidIMSafe(state, orderSender), Errors.ORDER_SENDER_NOT_SAFE);
            }

            return (result.traderList, result.paperChangeList, result.creditChangeList);
        }


}