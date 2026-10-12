# Retro6 — iOS 6 风格的自建应用生态

本工程提供 UIKit iOS 宿主、自建 Connect、Beta Center、应用商店、FastAPI API、受限 Web Runtime、SDK、CLI 和两个示例应用。应用是 `.simapp` 格式的 HTML/CSS/JavaScript 包，不是原生 IPA；本平台与 Apple 官方服务无关联。

## 本地启动（最快方式）

需要 Python 3.12。Web 前端与 API 同源托管，无需 Node 构建。

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
mkdir -p data
# 请自行设置管理员邮箱及强密码，不要提交到 Git。
export ADMIN_EMAIL='你的管理员邮箱'
read -s -p '管理员密码（至少 12 位）: ' ADMIN_PASSWORD
export ADMIN_PASSWORD
python -m uvicorn services.api.main:app --host 127.0.0.1 --port 8000
```

打开 http://localhost:8000。接口文档：http://localhost:8000/docs。

默认使用 SQLite 和本地文件；数据库、应用包、签名私钥保存在 `data/`。签名密钥在首次启动时生成，后续启动保持不变。**不要删除数据目录或签名私钥**。

## Docker Compose

需要 Docker Engine 与 Compose v2。

```bash
cp .env.example .env
# 编辑 .env，替换 CHANGE_ME 占位值。
docker compose up --build
```

访问 http://localhost:8000。此模式启动 API/Web、PostgreSQL、Redis、MinIO 和 RQ Worker。Web 中可以勾选“使用 S3 直传与异步校验”；不勾选时，仍可用普通上传。

Compose 的端口只绑定本机。生产部署需要 HTTPS 反向代理、替换对象存储外部地址、配置正确的 CORS、备份及管理员 MFA。MinIO 管理页面 http://localhost:9001；账号来自 `.env`。

## 完整应用交付流程

1. 注册开发者账号；进入“我的应用”，创建 `com.retro.pixelnotes`。
2. 上传 `examples/PixelNotes.simapp`，获得校验通过的不可变构建。
3. 点击“创建测试组”及“生成一次性邀请码”。
4. 用另一个账号登录 Beta Center，兑换邀请码、安装、运行、保存笔记并提交反馈。
5. 开发者提交审核；管理员使用 `ADMIN_EMAIL` 对应账号登录并批准。
6. 开发者点击“正式发布”。普通用户即可搜索、安装并运行。
7. 修改示例清单的版本号、打包新版本，重复审核及发布；商店提供更新，SDK 数据保持不变。

网页模拟器支持内联 HTML/CSS/JavaScript 包，下载包经过 Ed25519 验签和 SHA-256 校验后持久保存在 IndexedDB。首次安装采用公钥首次信任，必须在可信的 HTTPS/localhost 环境进行。**多文件应用请在 iOS 宿主运行**。

## iOS 工程

需要 macOS、Xcode（iOS 16+ SDK）与 XcodeGen。

```bash
brew install xcodegen
cd apps/ios-host
xcodegen generate
open Retro6.xcodeproj
```

选择 iPhone Simulator，运行 `Retro6`。在宿主的“设置”中：

- 配置 API 基地址。模拟器可用 `http://localhost:8000`；真机使用你的 HTTPS API 地址。
- 通过可信渠道获取 `/v1/keys` 返回的 `publicKey`，将其粘贴到“可信 Ed25519 公钥”。
- 登录账号，进入应用商店或 Beta 测试安装应用。

长按桌面图标可移动到下一页、Dock 或文件夹，也可卸载。最近应用会保留运行会话；“退出”销毁会话。便签与计算器是原生系统应用。

GitHub Actions 的 `ios-ci.yml` 配置了模拟器测试及未签名 IPA 构建。工作流成功后下载 `Retro6-unsigned-IPA` artifact。**本交付未运行云端 iOS 构建，也不包含已构建 IPA**。未签名 IPA 的真机安装需要适当的签名与分发方式。

## SDK 与 CLI

宿主在页面加载前自动注入 `Simulator`，应用无需再次加载 SDK。

```js
await Simulator.storage.set('note', 'Hello iOS 6');
const note = await Simulator.storage.get('note');
await Simulator.ui.alert('保存成功');
await Simulator.ui.setTitle('我的笔记');
const info = await Simulator.app.getInfo();
```

```bash
python packages/simapp-cli/simapp.py pack examples/pixel-notes -o PixelNotes.simapp
python packages/simapp-cli/simapp.py validate PixelNotes.simapp
```

运行测试：

```bash
python -m pytest -q
node tests/sdk.test.cjs
```

更多说明：[开发指南](docs/DEVELOPMENT.md)、[部署与运维](docs/OPERATIONS.md)、[Vercel 部署](docs/VERCEL_DEPLOY.md)、[验证报告与待完成项](docs/VERIFICATION.md)。原始需求在 `docs/PRD.md`。
