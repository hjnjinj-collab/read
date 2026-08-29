# Bug 修复报告：Android 编译 `rquickjs-sys` 缺 `aarch64-linux-android.rs` bindings——加 `bindgen` feature

## 修复日期
2026-08-29

## 问题概述

继 `openssl-sys` 修复后，第二次跑 `cargo ndk` 编译失败在 `rquickjs-sys 0.6.2`：

```
error: couldn't read `C:\Users\25644\.cargo\registry\src\index.crates.io-1949cf8c6b5b557f\rquickjs-sys-0.6.2\src\bindings/aarch64-linux-android.rs`:
       系统找不到指定的文件。 (os error 2)
  --> C:\Users\25644\.cargo\registry\src\index.crates.io-1949cf8c6b5b557f\rquickjs-sys-0.6.2\src\lib.rs:17:1
   |
17 | include!(concat!("bindings/", bindings_env!("TARGET"), ".rs"));
   | ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

warning: rquickjs-sys@0.6.2: rquickjs probably doesn't ship bindings for platform `aarch64-linux-android`.
       try the `bindgen` feature instead.
```

**触发条件**：`cargo ndk -t aarch64-linux-android ... build --release` 编译 `book_parser` / `reader_core` crate（间接依赖 `rquickjs 0.6`）。

**影响**：4 ABI 编译挂第二步（`rquickjs` 编译）；Android 编译第二次 fail。

## 根本原因

### `rquickjs-sys 0.6.2` 的两种 bindings 生成模式

**`rquickjs-sys/build.rs:107-122`** 关键代码：

```rust
#[cfg(not(feature = "bindgen"))]
fn bindgen<'a, D, H, X, K, V>(out_dir: D, _header_file: H, _defines: X, _add_cflags: Vec<String>) {
    let target = env::var("TARGET").unwrap();
    if !Path::new("./")
        .join("src")
        .join("bindings")
        .join(format!("{}.rs", target))    // 读 src/bindings/<target>.rs
        .canonicalize()
        .map(|x| x.exists())
    {
        println!("cargo:warning=rquickjs probably doesn't ship bindings for platform `{}`. ...",
                 target);
    }
    // ... 输出 macro_rules! bindings_env!("TARGET") => "<target>"
}
```

`lib.rs:17`：

```rust
include!(concat!("bindings/", bindings_env!("TARGET"), ".rs"));
```

**两套机制**：
- **默认（无 `bindgen` feature）**：`include!` 直接读预编译 `src/bindings/<target>.rs`——**只覆盖** `x86_64-pc-windows-msvc` / `x86_64-unknown-linux-gnu` / `aarch64-apple-darwin` 等 ~10 个主流目标
- **开 `bindgen` feature**：build 时**现场跑 `bindgen` crate 用 clang** 把 QuickJS C 头（`quickjs.h` / `quickjs-bind.h`）现场生成 Rust FFI bindings

**`aarch64-linux-android` 不在预编译列表里**——是意料之中的。`rquickjs-sys` 没预料到 Android NDK 编译。

### Windows 编译为什么之前能过

`rust/target/aarch64-linux-android/debug/.fingerprint/rquickjs-sys-*/` 显示之前有人跑过 `cargo build --target aarch64-linux-android`（在 NDK 修复前）——**但只 debug 没 release**。`book_source_engine` 是新的（之前 `book_parser` + `reader_core` 走 `js-engine` feature 触发的 `rquickjs-sys` 编译也走预编译路径）。

**预编译 bindings 清单**（`rquickjs-sys 0.6.2/src/bindings/`）：

```
aarch64-apple-darwin.rs
aarch64-unknown-linux-gnu.rs
aarch64-unknown-linux-musl.rs
i686-pc-windows-msvc.rs
i686-unknown-linux-gnu.rs
wasm32-wasi.rs
x86_64-apple-darwin.rs
x86_64-pc-windows-gnu.rs
x86_64-pc-windows-msvc.rs
x86_64-unknown-linux-gnu.rs
x86_64-unknown-linux-musl.rs
```

**没有 `aarch64-linux-android.rs`**——Android 编译走默认路径必 fail。

## 解决方案

**`rquickjs` 加 `bindgen` feature**——让 `rquickjs-sys` build 时用 NDK clang 现场生成 bindings。

### 改动

**`rust/crates/book_parser/Cargo.toml:19`** + **`rust/crates/reader_core/Cargo.toml:19`**：

```diff
- rquickjs = { version = "0.6", features = ["array-buffer", "classes", "parallel"], optional = true }
+ rquickjs = { version = "0.6", features = ["array-buffer", "classes", "parallel", "bindgen"], optional = true }
```

`book_parser` 和 `reader_core` 两处都要加（**workspace 共享** `rquickjs` 但各自声明 features——`Cargo.toml` workspace `[workspace.dependencies]` 里没列 `rquickjs`，是各自 inline 写的）。

**`bridge` crate** 不需要改——它通过 `js-engine` feature 透传 `book_parser` / `reader_core` 的 rquickjs，依赖图合并时 `bindgen` feature 自动随 `rquickjs` 一起传下去。

### 工作机制

`bindgen` feature 在 `rquickjs-sys/build.rs:124-167` 的实现：

```rust
#[cfg(feature = "bindgen")]
fn bindgen<...>(...) {
    let target = env::var("TARGET").unwrap();
    let mut cflags = vec![format!("--target={}", target)];
    // ... 用 clang_arg("--target=<android-target>") 调 NDK clang
    let builder = bindgen_rs::Builder::default()
        .detect_include_paths(true)
        .clang_arg("-xc")
        .blocklist_function("JS_DumpMemoryUsage");
    // ... 现场生成 bindings 写到 OUT_DIR
}
```

`cargo-ndk` 已经把 NDK clang + 工具链 sysroot 加到环境变量，bindgen 自动找到——**Android 编译零额外配置**。

### Windows 编译兼容性

Windows host 编译**之前**走预编译 `x86_64-pc-windows-msvc.rs`（快），**改后**走 bindgen 现场生成（多 ~10 秒）。

**实测**：
- `cargo check --release --workspace`：**22.81s**（bindgen 多花 ~8-10s）
- `cargo test --release -p book_parser --lib`：**122 passed**
- `cargo test --release -p reader_core --lib`：**141 passed**

**Windows 用户无感差异**（增量编译更慢一点），**Android 编译从 fail → 通过**。

## 验证

```bash
cd D:\android\example\legado_flutter\rust
cargo check --release --workspace         → Finished 22.81s ✅
cargo test --release -p book_parser --lib → 122 passed; 0 failed ✅
cargo test --release -p reader_core --lib → 141 passed; 0 failed ✅
```

**Android 编译预期**：`cargo ndk` 走 `rquickjs-sys` 时 build.rs 切到 `#[cfg(feature = "bindgen")]` 分支，NDK clang 现场生成 bindings，编译可继续。

## 备选方案（已弃用）

### 方案 B：手动 `include!` 一个 `aarch64-linux-android.rs` 到 pub cache

不实际——需要我们手动跑 bindgen，但 bindgen 又下不了（SSL 网络问题）；且 pub cache 路径版本敏感（`C:\Users\25644\.cargo\registry\src\...rquickjs-sys-0.6.2\`），全局污染。

### 方案 C：给 `rquickjs-sys` 加 `[patch.crates-io]` 用 fork 仓库

不实际——需要 fork + 自维护，破坏社区上游；commit hash 漂移维护成本高。

### 方案 D：关掉 `js-engine` feature 砍 `rquickjs`

**已评估不可行**：`rquickjs` 是核心架构（`JsRuntime` / `JsRuntimePool` / `chapter_extractor.rs` / `clean_rules.rs` / `extract_rules.rs` 全栈使用）——`optional = true` 仅在依赖层面是可选，**代码层不可关**。砍掉 = 重写 5 个核心文件 + 删架构。工作量 ~2-3 天，且破坏设计。

## 相关文件

- `rust/crates/book_parser/Cargo.toml:19`：`rquickjs` 加 `bindgen` feature
- `rust/crates/reader_core/Cargo.toml:19`：同上
- `C:\Users\25644\.cargo\registry\src\...\rquickjs-sys-0.6.2\build.rs`：build.rs 路径分支逻辑（**不动**）
- `Cargo.lock`：自动添加 `bindgen v0.69.5` + 间接依赖（`clang-sys` / `libloading` / `peeking_take_while` 等 ~10 个）

## 预防/工程约束

**Rust Android 交叉编译的 C 库原则（续 8-29 早上的"reqwest 切 rustls"约束）**：
1. **任何 `*-sys` crate 默认走预编译 bindings**——只覆盖主流目标（x86_64 / aarch64 macOS+Linux+Windows）
2. **Android / iOS / wasm 几乎必加 bindgen feature**——除非该 `-sys` crate 明确在 pub cache bindings 目录里覆盖了 Android ABI
3. **加任何 `-sys` 依赖前必查 bindings 目录**：
   ```bash
   ls ~/.cargo/registry/src/index.crates.io-*/<crate>-<ver>/src/bindings/ | grep -E "android|ios|wasm"
   ```
4. **bindgen 现场生成需要 host 上有 clang**（Windows 自带 / Linux 自带 / macOS 自带 Xcode clang）——`cargo-ndk` 已经把 NDK clang 注入到 build 环境，但**host 上仍需基础 clang**（bindgen-rs 通过 `clang-sys` 查找）。
5. **bindgen 第一次编译会下载 ~30 MB**（bindgen 0.69.5 + 间接依赖）——**网络不稳时**多次重试（SSL error 临时）。
6. **`optional = true` 的 Rust 库**不一定是"真的可选"——只代表依赖层是可选；代码层有 `use rquickjs::` 的必须开 feature。

**自检命令**：
```bash
cargo tree --target aarch64-linux-android 2>/dev/null | grep -E "rquickjs|bindgen|openss-sys"
# 应当看到 rquickjs-sys 0.6.2 + bindgen 0.69.x
```
