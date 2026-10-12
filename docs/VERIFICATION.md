# 交付验证报告

日期：2026-10-12。报告只记录实际执行的检查，不将待运行的 CI 当作通过结果。

## 实际通过

| 检查 | 结果 |
|---|---|
| Python API 与安全测试 | `9 passed`，在隔离虚拟环境及本次锁定依赖下执行 |
| 全交付链路 | 注册 → 团队/应用 → 上传校验 → Beta 兑换/下载 → 反馈 → 审核 → 发布 → 商店搜索/安装记录 → 新版本/更新发现 → 下架 |
| 包安全 | ZIP 路径穿越、绝对路径、反斜杠、隐藏/原生文件、符号链接、压缩炸弹、大小写重复、畸形清单被拒绝 |
| 权限 | 普通用户不能审核；外部用户不能修改应用；Analyst 不能上传；截图只能由作者上传及授权团队查看 |
| 签名与票据 | 校验 Ed25519 签名与 SHA-256，篡改 payload/下载票据失败，撤销测试授权后旧下载链接失效 |
| 重试与会话 | 应用/构建/组/邀请码幂等；键复用不同载荷返回冲突；刷新后旧 token 失效；登出撤销 |
| Worker | 在本地对象存储上调用真实校验函数，验证成功入库、失败状态、隔离文件清理；未启动真实 Redis 队列 |
| 管理员 MFA | 配置 TOTP 后，管理员缺少动态口令被拒绝；正确动态口令可登录 |
| 流式请求大小 | 没有 Content-Length 的超大 chunked JSON 请求被拒绝（413） |
| SDK | Node VM 测试存储调用、请求 ID、协议版本、错误传播与缺失宿主提示 |
| HTTP 服务 | 启动真实 Uvicorn；health、主页、CSS、JS、指南、SDK、OpenAPI、商店列表均返回 200 |
| API 数量 | 当前 OpenAPI 包含 43 个操作，快照在 docs/openapi.json |
| 数据迁移 | 在全新 SQLite 数据库执行 Alembic upgrade head，并再次执行成功 |
| 源文件检查 | JavaScript 语法、Python 编译、YAML 及 Info.plist 解析通过 |
| 应用 CLI | PixelNotes.simapp、FocusTimer.simapp 均已真实打包并校验 |
| Python 依赖审计 | pip-audit 审计 41 个依赖，无已知漏洞；pip check 无依赖冲突 |

测试有一条 Starlette/httpx 兼容弃用提示，不影响本次通过结果。后续可迁移到新的 TestClient HTTP 客户端。

## 尚未实际执行

- 环境是 Linux，没有 Xcode/Swift/UIKit 编译工具：**没有验证 iOS 工程可编译，没有运行 iOS 单元/UI 测试，没有生成 IPA**。GitHub Actions 文件提供检查路径，但尚未上传或执行。
- 没有 Docker Engine、实际 PostgreSQL/Redis/MinIO 服务：Compose 和数据库 CI 配置仅通过语法检查，尚未实测容器整体启动、S3 直传、队列投递、数据库并发事务。
- 没有可用的受支持浏览器自动化能力：没有浏览器截图、移动端视觉 QA 或真正 IndexedDB/iframe/WebCrypto 的 UI 端到端验收。Node 检查不替代浏览器测试。
- 原生 WebKit scheme/CSP、生存周期、桥接主帧校验与应用间隔离需要在目标 iOS 版本验证。服务端测试不替代这些系统行为检查。
- “安装→保存→退出→离线重开→更新仍保留数据”的原生人工验收尚未完成，不能由服务端安装记录的测试推断通过。

## 实现偏离与明确边界

- Web 采用原生 JavaScript/CSS，同源由 FastAPI 托管，未采用 Next.js/Tailwind。SDK 提供 JS 运行文件和 TS 类型声明。此选择减少本地启动依赖。
- iOS 工程使用 Swift 5 语言模式、UIKit、iOS 16+，通过 XcodeGen 生成工程，未宣称完成 Swift 6 strict concurrency 迁移。
- 本地模式 SQLite/文件存储，容器模式 PostgreSQL/S3/Redis/RQ；普通 multipart 上传同步校验，S3 直传走 Worker。
- 原生安装有完整下载后校验与原子索引，不支持显式保存 resumeData 的断点续传。
- 网页模拟器只支持内联 HTML 包，文件夹及多文件包等完整行为在原生宿主源码中；网页预览不是原生宿主替代品。
- 缺少自动 JS 崩溃诊断、相册/摄像头 P2 能力、排行榜/编辑精选运营、地区年龄限制、举报申诉、开发者身份验证、逐用户管理 MFA、公开运营监控与告警。
- 没有建立 GitHub 仓库或公开部署；没有接入 Apple 官方服务，没有运行原生第三方 IPA。

## 对原 PRD 完成定义的结论

交付的是有真实 API、可运行开发者站、包校验与签名、SDK、示例和原生宿主源码的核心生态工程，**不是已完成生产验收的产品**。PRD 的最终 Definition of Done 仍需完成原生构建/实机与浏览器验收、容器外部服务集成和上述运营能力补齐。不得把本报告或预置工作流描述为这些环节已经通过。
