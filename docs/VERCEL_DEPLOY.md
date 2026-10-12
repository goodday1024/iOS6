# Vercel 部署

项目根目录作为 Vercel 项目根目录，`api/index.py` 导出 FastAPI，`vercel.json` 将站点请求交给应用。运行时需要 Python 3.12；安装根目录 `requirements.txt`。部署前必须配置以下环境变量，之后重新部署：

| 变量 | 含义 |
|---|---|
| `DATABASE_URL` | 持久 PostgreSQL 连接串，`postgresql://` 或 `postgresql+psycopg://` |
| `RELEASE_KEY_BASE64` | 固定 Ed25519 私钥的 32 字节原始形式，Base64 编码；保持备份，轮换会影响客户端信任 |
| `S3_ENDPOINT` | 服务端访问的 S3 兼容端点 |
| `S3_PUBLIC_ENDPOINT` | 浏览器及 iOS 设备访问的同一桶端点；省略时沿用 `S3_ENDPOINT` |
| `S3_ACCESS_KEY`, `S3_SECRET_KEY`, `S3_BUCKET` | 对私有存储桶有读写权限的凭据与桶名 |
| `ADMIN_EMAIL`, `ADMIN_PASSWORD` | 可选首次管理员账号；密码至少 12 位 |

先从受控环境运行 `DATABASE_URL=... alembic upgrade head`。函数环境不会自动建表或运行迁移。可用 `python3 -c 'import base64; from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey; from cryptography.hazmat.primitives import serialization; print(base64.b64encode(Ed25519PrivateKey.generate().private_bytes(serialization.Encoding.Raw,serialization.PrivateFormat.Raw,serialization.NoEncryption())).decode())'` 生成签名密钥，仅复制到 Vercel 加密环境变量，不提交仓库。

存储桶须保持私有；浏览器直接 PUT 隔离区、直接 GET 签名包。配置 CORS 允许正式域名的 `PUT`、`GET`、`HEAD`，允许 `Content-Type` 请求头，暴露必要响应头。签名 URL 由服务端签发，PUT 有效 15 分钟，GET 有效 5 分钟。部署时直传为强制选项；`complete` 请求内同步校验，失败状态可查询。为隔离区加生命周期清理和存储配额；对外的 S3 端点必须可用 HTTPS。

Vercel 请求体限制使 20 MiB 包不能通过函数 multipart 上传；直传接口绕过该限制。函数只在请求内执行校验，没有常驻 RQ Worker；若校验超过函数超时，应改为外部持久队列和 Worker。上线前检查 `/health`、`/v1/keys`、注册、直传、审核、签名下载安装的完整流程。iOS 客户端需配置该 HTTPS API 地址，并独立核对首次信任的公钥。
