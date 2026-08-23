//! 内置 JS 净化规则集与执行器（D9：JS 主路径，正则仅兜底）
//!
//! 脚本契约镜像 chapter_extractor：全局注入 `content`，脚本返回净化后全文。
//! 执行器持进程级持久 QuickJS Context（懒初始化复用，规避逐章新建 Runtime
//! 的冷启动开销）；超时经 rquickjs 中断句柄实现真超时——tokio timeout
//! 包不住 spawn_blocking 阻塞线程内的死循环。

/// 广告正则数组字面量（JS 源码片段；净化脚本与结构化提取脚本共用的单一来源）
///
/// 与 ContentCleaner 的兜底正则（content_cleaner.rs `ad_patterns`）语义一致：
/// 本书由XX首发 / 更新最快的XX网 / 笔趣阁|顶点小说|飘天文学 /
/// 请记住本站|收藏本站 / www.*.com
pub const AD_PATTERNS_JS_ARRAY: &str = r#"
        /本书由[\s\S]*?首发/gi,
        /更新最快的[\s\S]*?网/gi,
        /笔趣阁|顶点小说|飘天文学/gi,
        /请记住本站|收藏本站/gi,
        /www\.\w+\.com/gi"#;

/// 内置广告净化 JS 规则（单一合并脚本，一次 eval 处理一章）
pub static BUILTIN_AD_RULES_JS: std::sync::LazyLock<String> = std::sync::LazyLock::new(|| {
    format!(
        r#"(function () {{
    const AD_PATTERNS = [{AD_PATTERNS}];
    let out = content;
    for (const p of AD_PATTERNS) {{
        out = out.replace(p, "");
    }}
    return out;
}})()"#,
        AD_PATTERNS = AD_PATTERNS_JS_ARRAY
    )
});

/// 单次执行超时（毫秒）：单章净化为毫秒级操作，3 秒已是极端余量
const EXEC_TIMEOUT_MS: u64 = 3000;

use std::sync::OnceLock;

#[cfg(feature = "js-engine")]
mod imp {
    use super::{BUILTIN_AD_RULES_JS, EXEC_TIMEOUT_MS};
    use anyhow::Context as _;
    use rquickjs::{Context, Runtime};
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::{Mutex, OnceLock};
    use std::time::{Duration, Instant};

    /// 持久执行器（Mutex 保证串行——净化只发生在缓存构建期，非读热路径）
    struct Executor {
        runtime: Runtime,
        context: Context,
    }

    static EXECUTOR: OnceLock<Mutex<Option<Executor>>> = OnceLock::new();
    static FAILURE_LOGGED: AtomicBool = AtomicBool::new(false);

    fn executor_slot() -> &'static Mutex<Option<Executor>> {
        EXECUTOR.get_or_init(|| Mutex::new(None))
    }

    /// 执行内置 JS 广告规则；Err 时调用方应回落正则兜底
    pub fn run_ad_rules(content: &str) -> anyhow::Result<String> {
        let mut guard = executor_slot()
            .lock()
            .map_err(|_| anyhow::anyhow!("JS 净化执行器锁中毒"))?;

        if guard.is_none() {
            let runtime = Runtime::new().context("创建 JS Runtime 失败")?;
            runtime.set_memory_limit(32 * 1024 * 1024);
            runtime.set_max_stack_size(1024 * 1024);
            let context = Context::full(&runtime).context("创建 JS Context 失败")?;
            *guard = Some(Executor { runtime, context });
        }
        let exec = guard.as_ref().unwrap();

        // 中断句柄实现真超时（tokio timeout 包不住阻塞线程内的死循环）；
        // 每次执行前重设截止时间
        let deadline = Instant::now() + Duration::from_millis(EXEC_TIMEOUT_MS);
        let handler: rquickjs::runtime::InterruptHandler =
            Box::new(move || Instant::now() >= deadline);
        exec.runtime.set_interrupt_handler(Some(handler));

        exec.context.with(|ctx| {
            ctx.globals()
                .set("content", content)
                .context("设置 content 变量失败")?;

            let result: String = ctx
                .eval(BUILTIN_AD_RULES_JS.as_str())
                .context("执行 JS 净化规则失败")?;

            Ok(result)
        })
    }

    /// 失败告警限频：仅首次记录，避免逐章刷日志
    pub fn warn_once(err: &anyhow::Error) {
        if !FAILURE_LOGGED.swap(true, Ordering::Relaxed) {
            log::warn!("JS 净化规则执行失败，后续回落正则兜底: {}", err);
        }
    }
}

/// 规则集内容哈希：并入 config_hash——升级/修改内置规则即自动失效全部净化缓存
pub fn ruleset_hash() -> u64 {
    use std::collections::hash_map::DefaultHasher;
    use std::hash::{Hash, Hasher};

    static HASH: OnceLock<u64> = OnceLock::new();
    *HASH.get_or_init(|| {
        let mut hasher = DefaultHasher::new();
        BUILTIN_AD_RULES_JS.as_str().hash(&mut hasher);
        hasher.finish()
    })
}

/// 以 JS 主路径去除广告。
///
/// 返回：
/// - `Some(Ok(cleaned))`：JS 净化成功；
/// - `Some(Err(_))`：JS 执行失败（已限频告警），调用方须回落正则兜底；
/// - `None`：极简构建（js-engine 关闭），调用方直接走正则兜底。
pub fn apply_js_ad_rules(content: &str) -> Option<anyhow::Result<String>> {
    #[cfg(feature = "js-engine")]
    {
        match imp::run_ad_rules(content) {
            Ok(cleaned) => Some(Ok(cleaned)),
            Err(e) => {
                imp::warn_once(&e);
                Some(Err(e))
            }
        }
    }
    #[cfg(not(feature = "js-engine"))]
    {
        let _ = content;
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ruleset_hash_stable_and_nonzero() {
        assert_eq!(ruleset_hash(), ruleset_hash());
        assert_ne!(ruleset_hash(), 0);
    }

    #[cfg(feature = "js-engine")]
    #[test]
    fn js_rules_remove_sample_ads() {
        let input = "正文甲。\n本书由笔趣阁首发，请继续阅读。\n正文乙。请记住本站\n正文丙 www.biquge.com\n正文丁。";
        let cleaned = apply_js_ad_rules(input)
            .expect("默认特性下 JS 主路径必须可用")
            .expect("内置规则不应执行失败");

        assert!(!cleaned.contains("首发"));
        assert!(!cleaned.contains("请记住本站"));
        assert!(!cleaned.contains("biquge.com"));
        assert!(cleaned.contains("正文甲。"));
        assert!(cleaned.contains("正文丁。"));
    }

    #[cfg(feature = "js-engine")]
    #[test]
    fn js_rules_preserve_normal_text() {
        // 正常章节文本不应被误伤（含全角空格与数字编号场景）
        let input = "　　清晨的雾还没散尽。\n第 12 条街道空无一人。\n网址是 example.org 不是广告格式。";
        let cleaned = apply_js_ad_rules(input).unwrap().unwrap();
        assert_eq!(cleaned.trim(), input.trim());
    }
}
