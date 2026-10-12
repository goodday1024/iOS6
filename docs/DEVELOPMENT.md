# 开发与协议

## 目录

| 目录 | 实现 |
|---|---|
| apps/ios-host | UIKit 桌面、设置、商店、Beta、WKWebView 运行时 |
| apps/developer-web | 无构建依赖的 Connect、审核后台、网页模拟器 |
| services/api | FastAPI、关系数据库、鉴权、包校验、签名、分发、Worker |
| packages/simulator-sdk | JavaScript SDK 与 TypeScript 声明 |
| packages/simapp-cli | Python 打包与校验 CLI |
| examples | 笔记及专注计时器，含可直接上传的 `.simapp` |
| infra | Docker、数据库迁移 |
| tests | API 全流程、安全、Worker、SDK 测试 |

## 应用包

ZIP 根目录包含 `manifest.json`；入口必须为 HTML，图标必须为 PNG。包体最多 20 MiB，解压资源最多 60 MiB，最多 1000 项，单项最多 10 MiB，压缩比最多 200。路径必须是规范相对路径；不允许隐藏文件、重复/大小写冲突路径、符号链接、设备文件、加密 ZIP 或原生可执行文件。

版本限定为无前导零的 `x.y.z`；`permissions` 必须是数组，当前只支持 `storage`。只支持 portrait 和运行时 1.0.0。包上传后不可变，同一应用与版本不能重复建构。

```json
{"schemaVersion":1,"id":"com.example.notes","name":"Notes","version":"1.0.0","runtime":"web","entry":"index.html","minSimulatorVersion":"1.0.0","permissions":["storage"],"orientation":"portrait","icon":"assets/icon.png"}
```

## 状态与权限

构建校验状态在 builds/uploads；审核状态在 reviews；正式发布状态在 releases；Beta 有独立测试组、过期时间和访问授权。测试组绑定不可变构建，想测试另一个版本应创建新组。

团队 Owner/Admin/Developer 可以开发，Analyst 只读。管理域仅 admin/reviewer 可访问。注册只创建普通用户及其自己的团队，不能由客户端指定管理员角色。团队成员需要先注册；本版本的成员管理是直接添加已注册账号，不发送邮件邀请。

会话是随机高熵 bearer token，数据库只存哈希，7 天到期，可轮换和撤销。实现使用不透明 token，并未采用 PRD 建议的 JWT/OIDC。Web token 放在 sessionStorage，原生放在 Keychain。管理员可通过环境配置 TOTP 二次验证。正式版接入外部身份服务时应迁移这些接口，而不是混用认证模式。

## 上传与幂等

默认 `POST /v1/developer/apps/{id}/builds` 使用 multipart 字段 `file`。在 S3 模式可使用：

1. `POST .../builds/upload-url` → `uploadId / uploadUrl / headers`。
2. PUT 到 uploadUrl；对象只进入 quarantine 命名空间。
3. `POST .../builds/complete`，JSON `{ "upload_id": "..." }`。
4. `GET .../uploads/{uploadId}` 查询 validating/validated/failed。

RQ Worker 读取并校验隔离对象，写入不可变对象后才创建构建记录；结束后删除隔离对象。上传权限 15 分钟到期。对象直传的大小在 Worker 下载前检查；另需对象存储配额及生命周期规则限制滥用和未完成上传。

创建应用、普通构建上传、上传凭证、测试组和邀请码支持 `Idempotency-Key`（1–128 字符），同一用户不能把同一键用于不同路径/载荷。成功响应与业务写入在同一个数据库事务内保存，敏感响应使用 AES-GCM 加密。请求失败后可使用相同键重试；多进程并发撞键可能返回 409，此时再重试读取已提交结果。

提交审核返回同一个审核记录；邀请码重复兑换只对原兑换者成功；安装记录为 upsert；同一正式版本重复发布不会产生第二个活跃版本。其他接口没有统一的强幂等承诺。

## 安装与数据

服务器签名覆盖 canonical JSON 中 appId/buildId/bundleId/version/sha256/permissions，票据本身有效 5 分钟。下载 endpoint 每次重新检查渠道权限，可阻止已撤销测试组/已下架应用的新下载。

原生：URLSession 下载 → 签名和摘要校验 → 安全解压到 staging → Manifest 对照 → 移到版本目录 → 原子更新安装索引。失败不替换旧索引。旧版资源暂时保留，避免运行中会话读到缺失文件；离线启动不依赖 API。私有数据位于按 UUID 标识的文件，由宿主控制，更新不删除。卸载默认清理，可选择保留数据。

已安装应用与存储按设备及 appId 隔离，并非按登录用户隔离。多账号共用设备时，应用数据仍在同一设备的安装中；不要把它当作多用户安全容器。

Beta 到期使用设备时钟限制原生启动；网页预览同样检查安装时的到期记录。组的即时远程撤销只限制后续联网下载与反馈，不远程擦除本地包，离线设备也无法即时得知撤销。

## Web Runtime 安全边界

每个原生会话有非持久 WKWebsiteDataStore、自定义 simapp scheme、绑定于 WebView 的应用身份和主帧检查。桥接不接受客户端 appId，不支持任意原生方法或文件路径。storage：每个值 32 KiB、键 128 字节、应用 1 MiB/100 项；桥接消息 64 KiB、120 次/分钟。只暴露 storage/app/ui。

CSP 在 HTML 最前面注入，默认不允许外部网络、frame、form、object；导航代理只允许自身 scheme 和 host。该方案仍需在支持的 WebKit 版本实测，不能声称具备 OS 级隔离。iOS 后台由系统调度，生命周期事件只是通知，不是资源配额或恶意脚本治理机制。

网页预览通过 sandbox="allow-scripts" 的 opaque-origin iframe 运行，校验 message source 并绑定会话；存储由宿主通过 IndexedDB 操作，不给应用访问主站的 token 或 DOM。它仅支持内联 HTML，不支持多文件资源树或浏览器缓存之外的安装能力。Safari 对 Ed25519/DecompressionStream 的支持受版本限制，失败时明确提示，不降级跳过验签。

## 反馈与隐私

文字反馈最长 4000 字，可带设备型号、系统和模拟器版本。截图只能由作者主动上传，最大 2 MiB、4096×4096 的 PNG；只有作者和有应用权限的团队成员能下载。原生运行页提供文字或“截图与文字”两种提交选项，上传前明确说明数据范围。

没有自动采集 JS 错误或崩溃日志。照片、摄像头、剪贴板、通知和网络代理未开放。请勿通过额外桥接跳过权限设计。
