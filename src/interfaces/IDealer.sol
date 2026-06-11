// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;


interface IDealer {

    // =========== 资金管理 ===========

    /**
     * 存入保证金
     * @param primaryAmount 主资产存款数量
     * @param secondaryAmount 次级资产存款数量
     * @param to 存入的目标账户地址
     * @dev 调用放需提前 approve 足够额度
     */
    function deposit(uint256 primaryAmount, uint256 secondaryAmount, address to) external;


    /**
     * 请求取款（第一步）
     * @param from 取款来源账户
     * @param primaryAmount 主资产取款数量
     * @param secondaryAmount 次级资产取款数量
     * @dev 主要目的是避免因取款导致对手方交易失败，取款请求需要等待时间锁后才能执行
     */
    function requestWithdraw(address from, uint256 primaryAmount, uint256 secondaryAmount) external;


    /**
     * 执行取款（第二步）
     * @param from 取款来源账户
     * @param to 资金接收地址
     * @param isInternal 是否仅内部转账（不实际转出ERC20）
     * @param param 回调参数，非空时会调用 to 地址
     */
    function executeWithdraw(address from, address to, bool isInternal, bytes memory param) external;


    // =========== 交易管理 ===========


    /**
     * 批准交易（核心撮合函数）
     * @param orderSender 订单发送者（撮合引擎）地址
     * @param tradeData 包含订单、签名和撮合信息的编码数据
     * @return traderList 参与交易的交易者列表
     * @return paperChangeList 各交易者的 paper 变化
     * @return creditChangeList 各交易者的 credit 变化
     * @dev 仅永续合约可调用此函数，
     *     解析 tradeData，验证订单并返回各方余额变化
     */
    function approveTrade(address orderSender, bytes calldata tradeData) 
        external 
        returns(address[] memory traderList, int256[] memory paperChangeList, int256[] memory creditChangeList);


    // =========== 风险管理 ===========


    /**
     * @notice 检查交易者是否安全（满足维持保证金）
     * @param trader 交易者地址
     * @return bool 是否安全，true 表示满足维持保证金要求，false 表示需要强平
     * @dev 如果不安全，该交易者所有市场的仓位都可能被清算
     */
    function isSafe(address trader) external view returns (bool);
    

    /**
     * @notice 批量检查交易者安全状态
     * @param traderList 交易者列表
     * @return bool 是否全部安全
     * @dev 通过缓存标记价格提高 gas 效率
     */
    function isAllSage(address[] calldata traderList) external view returns (bool);


    /**
     * 请求清算
     * @param executor 执行清算地址
     * @param liquidator 清算者
     * @param liquidatedTrader 被清算者
     * @param requestPaperAmount 请求清算的仓位数量，正数表示清算多头仓位，负数表示清算空头仓位
     * 
     * @return liqtorPaperChange 清算者的 paper 变化
     * @return liqtorCreditChange 清算者的 credit 变化
     * @return liqedPaperChange 被清算者的 paper 变化
     * @return liqedCreditChange 被清算者的 credit 变化
     * @dev 仅永续合约可调用
     *     liqtor = liquidator, liqued = liquidated trader
     */
    function requestLiquidation(address executor, address liquidator, address liquidatedTrader, int256 requestPaperAmount) 
        external 
        returns(int256 liqtorPaperChange, int256 liqtorCreditChange, int256 liqedPaperChange, int256 liqedCreditChange);


    /**
     * 处理坏账
     * @param liquidatedTrader 被清算者地址
     * @dev 将所有坏账（包括主资产和次级资产）转移给保险账户，确保平台整体安全性
     */
    function handleBadDebt(address liquidatedTrader) external;


    // =========== 仓位管理 ===========
    
    /**
     * 注册开仓
     * @param trader 交易者地址
     * @dev 仅永续合约可调用
     *      当交易者开仓时由 Perpetual 合约调用
     */
    function openPosition(address trader) external;


    /**
     * @notice 实现盈亏并移除仓位
     * @param trader 交易者地址
     * @param pnl 盈亏金额，正数表示盈利，负数表示亏损
     * @dev 仅永续合约可调用
     *     当交易者平仓时由 Perpetual 合约调用
     */
    function realizePnL(address trader, int256 pnl) external;

    // =========== 权限管理 ===========

    /**
     * 设置操作员
     * @param operator 操作员地址
     * @param isValid 是否授权
     * @dev 操作员可以代替用户签名订单
     */
    function setOperator(address operator, bool isValid) external;


    // ========== 权限检查 ===========

    /**
     * 检查订单发送者是否有效
     * @param orderSender 订单发送者地址
     * @return 是否有效，true 表示该地址被授权为订单发送者，false 表示未授权
     */
    function isOrderSenderValid(address orderSender) external view returns (bool);

    /**
     * 检查快速取款操作员是否有效
     * @param fastWithdrawalAddress 快速取款操作员地址
     * @return 是否有效，true 表示该地址被授权为快速取款操作员，false 表示未授权
     */
    function isFastWithdrawalValid(address fastWithdrawalAddress) external view returns (bool);

    /**
     * 检查操作员是否有效
     * @param client 用户地址
     * @param operator 操作员地址
     * @return 操作员是否被授权
     */
    function isOperatorValid(address client, address operator) external view returns (bool);

    /**
     * 查询资金操作授权额度
     * @param from 授权者
     * @param spender 被授权者
     * @return primaryCreditAllowed 主资产授权额度
     * @return secondaryCreditAllowed 次级资产授权额度
     */
    function isCreditAllowed(address from, address spender) external view returns (uint256 primaryCreditAllowed, uint256 secondaryCreditAllowed);

}