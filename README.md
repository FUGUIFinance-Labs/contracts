# FUGUI Finance · Contracts

> 富贵险中求，赚了买美股 · Trade memes. Bank stocks.

富贵财经（FUGUI Finance）链上协议的智能合约部分：把中文 meme 币 **$FUGUI** 和**代币化美股（Stock Tokens）**接在一起的 Foundry 工程，部署于 Robinhood Chain。

核心玩法——**富贵钱庄 FuguiBank**：

- **落袋为安**：存入 $FUGUI，价格每上一档（如 +20%）自动卖出一部分换成 NVDA/GME 等 Stock Token，随时取回——「炒 meme，攒英伟达」。
- **富贵险中求**：存入 Stock Token，meme 每跌一档自动逢跌买入——逆向定投。
- 每个仓位铸造一张链上生成的像素风**银票 NFT（BankNote）**作为凭证。

## 合约一览

| 合约 | 路径 | 说明 |
|---|---|---|
| `FuguiBank` | `src/bank/FuguiBank.sol` | 富贵钱庄：落袋金库。两种模式——落袋为安（meme 涨档自动换 Stock Token）/ 富贵险中求（meme 跌档自动买入）。权限无关的 `harvest`（keeper 有小费），TWAP/静态预言机报价，滑点保护，绩效费入金库 |
| `BankNote` | `src/bank/BankNote.sol` | 银票 NFT（ERC-721），tokenId == positionId，链上 SVG 生成像素银行票据，可保留作兑付纪念 |
| `FuguiTreasury` | `src/bank/FuguiTreasury.sol` | 协议金库（手续费、奖池），PAYOUT 角色 multisig |
| `TwapOracle` | `src/oracle/TwapOracle.sol` | Uniswap-V2 风格时间加权预言机（主网用） |
| `StaticOracle` | `src/oracle/StaticOracle.sol` | 管理员设价的静态预言机（测试网/冷启动） |
| `LhbRewards` | `src/lhb/LhbRewards.sol` | 龙虎榜激励：按 epoch 发布 Merkle 根，获奖者领 Stock Token |
| `FuguiToken` | `src/tokens/FuguiToken.sol` | $FUGUI 测试网代币（固定供应、可燃烧） |
| `StockToken` | `src/tokens/StockToken.sol` | 代币化美股测试网代币（tNVDA/tGME…，发行人元数据 + 合规锁） |
| `MockExchange` | `src/mocks/MockExchange.sol` | 恒定乘积模拟盘（`IExchangeRouter`），带 `setPrice` 供 keeper 模拟行情 |

## 仓库结构

```
contracts/
├── src/
│   ├── bank/        # FuguiBank / BankNote / FuguiTreasury
│   ├── oracle/      # TwapOracle / StaticOracle
│   ├── lhb/         # LhbRewards（龙虎榜激励）
│   ├── tokens/      # FuguiToken / StockToken
│   ├── interfaces/  # IBank / IFuguiBankView / IERC20
│   ├── lib/         # Roles / ReentrancyGuard / MerkleProof / FullMath / Base64 / Strings
│   └── mocks/       # MockExchange（测试网模拟盘）
├── script/          # Deploy.s.sol（测试网一键部署）
├── test/            # Foundry 测试（开仓/收割/领取/清仓、双模式、费率、暂停、权限、Merkle、TWAP）
├── foundry.toml
└── .env.example
```

## 环境要求

- [Foundry](https://book.getfoundry.sh/getting-started/installation)（`forge` / `cast`）
- solc `0.8.26`（自动下载），`via_ir` 开启

## 快速开始

```bash
# 1. 安装依赖（本仓库不包含 lib/，需要先装 forge-std）
forge install foundry-rs/forge-std --no-commit

# 2. 编译 + 测试
forge build
forge test            # 42 个用例
forge test -vvv       # 详细输出
```

## 部署（Robinhood Chain 测试网）

1. 领测试币：<https://faucet.testnet.chain.robinhood.com>（Chain ID 46630）
2. 配置环境变量（参考 `.env.example`；**私钥只放本地 `.env`，已被 `.gitignore` 排除，切勿提交**）
3. 部署：

```bash
cp .env.example .env   # 填入 PRIVATE_KEY
source .env
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast
```

脚本会依次部署代币、模拟盘、预言机、钱庄、银票、龙虎榜与金库，注入初始流动性
（1 tNVDA = 1000 FUGUI，1 tGME = 30 FUGUI），并把地址写到
`deployments/robinhood-testnet.json`（该目录不入库）。

### 测试网演示流程

```bash
# 行情拉到 +50%（meme 暴涨），然后任何人都能触发收割
cast send $EXCHANGE "setPrice(address,address,uint256)" $NVDA $FUGUI 1500000000000000000000 --rpc-url $RPC_URL --private-key $PK
cast send $ORACLE "setPrice(address,address,uint256)"   $NVDA $FUGUI 1500000000000000000000 --rpc-url $RPC_URL --private-key $PK
cast send $BANK "harvest(uint256)" 0 --rpc-url $RPC_URL --private-key $PK
```

## 网络

| | 测试网 | 主网 |
|---|---|---|
| RPC | `https://rpc.testnet.chain.robinhood.com` | `https://rpc.mainnet.chain.robinhood.com` |
| Chain ID | 46630 | 4663 |
| 水龙头 | `https://faucet.testnet.chain.robinhood.com` | — |

## 主网切换清单

- `StaticOracle` → `TwapOracle`（注册 meme/stock 的 V2 交易对并定期 `update`）
- `MockExchange` → 真实 DEX 的 `IExchangeRouter` 适配器
- `FuguiToken` → 主网 $FUGUI `0xceebf25b318201f1f949be2fabbfcee231737139`，Stock Token 换 Robinhood 官方地址
- 角色移交：RANKER/FUNDER → 索引机器人，PAYOUT → multisig，ADMIN → Timelock

## 安全说明

- 本仓库当前为**测试网演示代码，未经第三方审计**，请勿直接用于管理主网资产。
- 密钥管理：部署只用 `.env`（本地），仓库内不含任何私钥、助记词或 API key。
- 权限角色（ADMIN/PAYOUT/RANKER/FUNDER）上线前应移交 multisig/Timelock。

## License

MIT（见 [LICENSE](./LICENSE)）。
