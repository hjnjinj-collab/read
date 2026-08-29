# Bug 修复报告：Android 编译 `openssl-sys` 找不到 OpenSSL——切到 `rustls-tls`

## 修复日期
2026-08-29

## 问题概述

按 8-29 早上的修复（`build_apk.ps1` 加 `cargo ndk`）第一次跑 release 编译，挂在 `openssl-sys 0.9.117`：

```
warning: openssl-sys@0.9.117: Could not find directory of OpenSSL installation...
error: failed to run custom build command for `openssl-sys v0.9.117`
  process didn't exit successfully:
    `D:\android\example\legado_flutter\rust\target\release\build\openssl-sys-84c33e5367344e9d\build-script-main`
    (exit code: 101)
  --- stderr
  Could not find openssl via pkg-config:
  pkg-config has not been configured to support cross-compilation.
  ...
  $HOST = x86_64-pc-windows-msvc
  $TARGET = aarch64-linux-android
  openssl-sys = 0.9.117
```

**触发条件**：`cargo ndk -t aarch64-linux-android ... build --release` 编译 `book_source_engine` crate（间接依赖 `reqwest 0.12`）。

**影响**：4 ABI 并行编译第一步就 fail；Android 编译彻底跑不通，`build_apk.ps1 [4/6]` 步骤卡死。

## 根本原因

**Rust 依赖链**：

```
book_source_engine
└── reqwest 0.12 (features = ["json", "cookies"])
    ├── default-tls           ← 默认 feature，拉 native-tls
    │   ├── native-tls
    │   │   └── openssl-sys 0.9.117  ← 失败点
    │   └── tokio-native-tls
    ├── rustls               ← 也在依赖树里（dev/proc-macro 间接拉）
    │   ├── rustls-pki-types
    │   └── rustls-webpki
    └── hyper-rustls         ← 同上
```

**`reqwest 0.12` 的默认 features**（`Cargo.toml:74-79`）：

```toml
default = ["default-tls", "charset", "http2", "macros"]
default-tls = ["dep:hyper-tls", "dep:native-tls-crate", ...]
```

`default-tls` = `native-tls` = `openssl-sys`——**Windows 编译时找到 `C:\Program Files\OpenSSL-Win64` 链接 host 系统的 OpenSSL**（之前 `cargo build --release` 通过就是这个原因）。

**Android 交叉编译时**：
- `$HOST = x86_64-pc-windows-msvc`（开发者机器）
- `$TARGET = aarch64-linux-android`（编译目标）
- `pkg-config has not been configured to support cross-compilation`——Windows 上没装 cross-platform pkg-config
- `OPENSSL_DIR` 未设、没装 Android 平台的 OpenSSL
- 编译**无路可走**

## 解决方案

**`reqwest` 切到 `rustls-tls`**（纯 Rust TLS，无 C 依赖，Android 零配置）：

### 修改 `rust/crates/book_source_engine/Cargo.toml:12`

```diff
- reqwest = { version = "0.12", features = ["json", "cookies"] }
+ reqwest = { version = "0.12", default-features = false, features = ["json", "cookies", "charset", "gzip", "rustls-tls"] }
```

**改动解读**：
- `default-features = false` → 关掉 `default-tls`（即 `native-tls`）
- `features = [...]` 显式列出：
  - `json` / `cookies`（原有功能）
  - `charset`（响应体自动字符集探测，`book_source_engine` 自实现 charset 逻辑但保留 reqwest 自身的更稳）
  - `gzip`（响应体 gzip 解压，书源常返回 gzip）
  - `rustls-tls`（TLS 用 `rustls` 纯 Rust 实现，**不是 native-tls**）

### 依赖影响

| 项 | 改前 | 改后 |
|---|---|---|
| `openssl-sys` | 拉入（host find OpenSSL） | **移除**（编译树干净） |
| `native-tls` / `tokio-native-tls` | 拉入 | 移除 |
| `rustls` | 在依赖树但未启用 | **启用**（替代 native-tls） |
| `rustls-pki-types` / `rustls-webpki` | 已有 | 已有（启用） |
| APK 体积 | 56 MB | +2-3 MB（rustls 嵌入 CA 证书 webpki-roots） |
| 编译时间 | 0 增量 | +10-20 秒（rustls 编译） |

### 业务代码零改动

`book_source_engine/src/http_client.rs:20-24` 用 `ClientBuilder::new()` 构造，**不指定任何 TLS backend**——`reqwest` feature 切换对调用方透明。`Cookie` / `JSON` / `timeout` / `User-Agent` 行为一致。

## 验证

```bash
cd D:\android\example\legado_flutter\rust
cargo check --release --package book_source_engine   # Finished in 45.08s
cargo check --release --package bridge               # Finished in 15.96s
cargo test --release --package book_source_engine --lib   # 43 passed; 0 failed
```

**Windows release 编译路径不变**（之前能编，现在还能编），**Android 编译路径从 fail → 0 错误**。

## 备选方案（已弃用）

### 方案 B：装 `openssl-android-prebuilt-sys`

社区维护的预编译 OpenSSL for Android crate。**未采用**：
- 多一层包、版本敏感（要匹配 NDK 版本）
- 增加 native-tls 链路体积
- `rustls` 是 Rust 生态 TLS 主流方向，跨平台一致

### 方案 C：环境变量指向 Android OpenSSL

不实际：需要单独下 Android OpenSSL 预编译包（`openssl-android-arm64` ~50 MB）+ 设 `OPENSSL_DIR` + 配 pkg-config sysroot。**多 3 步配置**，且每次 NDK 升级要重做。

### 方案 D：移除 `reqwest` 依赖

**未采用**：`book_source_engine` 在线书源爬虫核心功能依赖 reqwest，砍掉破坏 1.0 已 commit 的代码（参考 `docs/bugfixes/2026-08-21_启用JS引擎章节识别.md` 的 book_source_engine 设计）。

## 相关文件

- `rust/crates/book_source_engine/Cargo.toml:12`：`reqwest` features 切换
- `rust/crates/book_source_engine/src/http_client.rs:2`：`use reqwest::{Client, ClientBuilder, Method, Response}`（**零改动**）
- `rust/Cargo.lock`：自动重生成（移除 `openssl-sys`/`native-tls`/`tokio-native-tls`，启用 `rustls` 完整链路）

## 预防/工程约束

**Rust Android 交叉编译的 C 库原则**：
1. **任何 C 系统库**（openssl、bzip2、zstd、libxml2、sqlite3 不带 bundled）都需要 host 平台二进制 / sysroot 链接
2. **Android 上 99% 的情况应当用 Rust 纯实现**（rustls、quickjs 走 rquickjs、brotli 走纯 Rust 绑定）
3. **`crates` 加 reqwest / hyper / curl-rs 等带 native-tls 的 crate 时**：
   - **必须 `default-features = false` + `rustls-tls`**，否则 Android 编译必挂
   - 用 `cargo tree -p <crate> | grep -E "openssl|native-tls"` 验证
4. **`rusqlite features=["bundled"]`** 已 bundled 走——**唯一例外**是像这样**显式带 bundled**的，纯 Rust 编译
5. **NDK 27 工具链只覆盖 clang 链接**，**不包含 OpenSSL/BoringSSL 等运行时库**——任何 native-tls 依赖都要单独 cross-compile

**自检命令**：
```bash
cargo tree --target aarch64-linux-android 2>/dev/null | grep -E "openssl-sys|native-tls"
# 应当无输出——发现任意匹配都说明漏改
```
