## 推荐讲解结构（5 层，由外到内）

### 第 1 层：系统架构（30 秒）

> 我们是 链下撮合 + 链上结算 的永续合约。
> 前端钱包登录，Go 后端负责撮合、风控、链上提交和事件监听；Kafka 做服务解耦，MySQL 持久化，Redis 做缓存/订单簿；链上核心是 MetaNodeDealer（资金与风控） + 多个 Perpetual（单市场仓位账本）。

### 第 2 层：用户资金（1 分钟）

> 用户登录：钱包地址 + EIP-712 签名 → 后端验签 → 发 JWT。
> 交易前：前端调 `IDealer.deposit()`，USDC 进合约，账本记 `primaryCredit`。
> 充值就是保证金入账，开仓不会再从钱包划一笔；全仓下 USDC 和各市场仓位一起算净值。

一句定心丸：
「保证金不是开仓时单独划拨的，是充值后一直在 Dealer 里，持仓盈亏记在 Perpetual，两者合并做风控。」

### 第 3 层：交易主流程（2 分钟，重点）

用一句话串起来：

> 用户签名订单 → 后端撮合 → 撮合成功调 `Perpetual.trade()` → Dealer `approveTrade` 验签算变化 → Perpetual `_settle` 更新仓位 → 全员 MM 安全检查。

分步话术：

1. 下单
   用户签 `Order`：`perp`、`signer`、`paperAmount`、`creditAmount`、`info`（费率、过期、nonce）。
   例：1 BTC @ $30,000 做多 → `paper=+1`，`credit=-30000`。
2. 撮合（你的 Go 后端）
   内存订单簿；能成交就组 batch；不能成交就挂着。
3. 上链 `trade(tradeData)`
   - Perpetual 调 Dealer.`approveTrade`
   - 验 EIP-712 签名、过期、防自成交、防超量成交
   - `Trading._matchOrders` 算每个用户的 `paperChange`、`creditChange`
4. 返回三个 list（讲清楚含义）
   - `traderList`：参与地址
   - `paperChangeList`：本次仓位变化（多正空负）
   - `creditChangeList`：本次资金变化（已扣手续费）
5. `_settle` 更新存储（合约核心，建议背这段）

旧 credit = paper × fundingRate + reducedCredit

新 credit = 旧 credit + creditChange

新 paper  = 旧 paper + paperChange

新 reducedCredit = 新 credit - 新 paper × fundingRate

1. 收尾
   - 新开仓 → `openPosition` 记入持仓列表
   - 完全平仓 → `realizePnl` 把盈亏写入 `primaryCredit`
   - `isAllSafe`：所有人净值 ≥ 维持保证金，否则 revert

不要说的：「Dealer 给用户授权再交易」——改成「Dealer 验签并返回变化量，Perpetual 负责改账本」。

### 第 4 层：资金费率（1 分钟）

> 链上 `fundingRate` 是累计值，重要的是每次变化量，不是绝对值。
> 公式：`credit = paper × fundingRate + reducedCredit`
> 费率更新时只改全局 `fundingRate`，不用逐个改用户存储（gas 优化）。

你的后端职责（可这样讲）：

- 每 8 小时（或你们定的周期）用现货价、标记价算费率
- 例：溢价指数 = (标记价 - 现货价) / 现货价，再加固定项，clamp 到 [-5%, 5%]
- `fundingRateKeeper` 调 `updateFundingRate` 上链
- 正费率：多头付空头；负费率：反过来
- 目的：让永续价贴近现货，避免单边过度拥挤

### 第 5 层：清算（1.5 分钟）

触发条件（一句）：

> 当 净值 < 维持保证金 时可被清算；`isSafe() == false`。

计算话术：

单市场仓位价值 = paper × markPrice + credit

credit 读取时 = paper × fundingRate + reducedCredit

敞口 exposure = Σ |paper × markPrice|

维持保证金 MM = Σ (敞口 × liquidationThreshold)

净值 netValue = Σ仓位价值 + primaryCredit + secondaryCredit

安全 ⟺ netValue ≥ MM

执行话术：

1. 清算人调 `Perpetual.liquidate()`
2. 校验：被清算者 MM 不安全、方向一致、不能自清算
3. 清算价：多头 `markPrice×(1-折扣)`，空头 `markPrice×(1+折扣)`
4. 算 `paperChange`、`creditChange`、保险费 → 进保险账户
5. 双方 `_settle`；清算人成交后仍须 MM 安全
6. 仓位清零仍资不抵债 → `handleBadDebt`，保险基金兜底

和正常交易的区别：
清算是强制转让仓位，不走订单簿撮合。

### 第 6 层：你的工程化（30 秒）

> Kafka 按交易对分区保顺序；订单 ID 做幂等；链上监听 + 定时对账「进行中」订单；Redis 订单簿；MySQL 落库。
> 这是链下可靠性，和链上结算规则分开讲。



<hr/>

## 一张「口播版」数据流（背这个就够串全场）

~~~txt
钱包 EIP-712 签订单
    ↓
Go 撮合（内存订单簿 / Kafka）
    ↓
Perpetual.trade()
    ↓
Dealer.approveTrade()  ← 验签 + 算 paperChange/creditChange
    ↓
Perpetual._settle()     ← 更新 paper、reducedCredit
    ↓
isAllSafe()             ← MM 检查
    ↓
（持仓期间）后端更新 fundingRate 上链
    ↓
（风险恶化）liquidate() → 保险费 → 可能 handleBadDebt
    ↓
（完全平仓）realizePnl() → 盈亏写入 primaryCredit
~~~



## 合约层「30 秒电梯演讲」模板（可直接练）

> Perpetual 只管单个市场的仓位账本，用 `paper` 表多空，用 `reducedCredit` 配合全局 `fundingRate` 算 `credit`。
> Dealer 管 USDC 保证金 `primaryCredit` 和全仓风控。
> 交易时用户钱包 EIP-712 签名，撮合引擎调 `trade`，Dealer 验签后返回每个人的 `paperChange` 和 `creditChange`，Perpetual 用 `_settle` 更新账本，最后检查所有人是否还满足维持保证金。
> 充值就是保证金，开仓不划款；平仓才把盈亏结转到 USDC。
> 资金费率由 keeper 定期上链，通过累计费率自动调整持仓者 credit。
> 净值低于维持保证金时，清算人以折扣价接手仓位，保险费进保险基金，穿仓由保险基金承担。



## 建议练习方式

1. 只讲合约 3 分钟：Dealer / Perpetual 分工 + `_settle` 公式 + 清算条件
2. 只讲后端 2 分钟：登录、撮合、Kafka、监听、对账
3. 全链路 5 分钟：用上面电梯演讲 + 一个 BTC 做多例子

