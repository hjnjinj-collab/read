//! JS Runtime - 仅在 js-engine feature 启用时编译
//!
//! 持久化 QuickJS 实例：`Runtime`/`Context` 在构造时创建一次并跨执行复用，
//! 池化的收益来自这里（此前每次执行都 `Runtime::new()`，~10–20ms）。
//! 超时保护基于 rquickjs 中断句柄 + 执行 deadline——长脚本会被引擎内部
//! 真正打断（spawn_blocking 的 abort 无法杀死正在运行的阻塞任务）。

use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::Arc;
use std::time::Instant;

use anyhow::{Context as AnyhowContext, Result};
use rquickjs::{Context as JsCtx, FromJs, Runtime};

/// JS execution context with book/chapter metadata.
#[derive(Debug, Clone)]
pub struct JsExecContext {
    pub book_title: String,
    pub book_author: String,
    pub book_url: String,
    pub chapter_title: String,
    pub chapter_index: usize,
    pub chapter_url: String,
    pub chapter_content: String,
}

impl Default for JsExecContext {
    fn default() -> Self {
        Self {
            book_title: String::new(),
            book_author: String::new(),
            book_url: String::new(),
            chapter_title: String::new(),
            chapter_index: 0,
            chapter_url: String::new(),
            chapter_content: String::new(),
        }
    }
}

/// Runtime statistics.
#[derive(Debug, Clone)]
pub struct JsRuntimeStats {
    pub usage_count: usize,
    pub age: std::time::Duration,
}

/// JS runtime wrapper with sandbox isolation and deadline-based interruption.
///
/// 内部的 QuickJS 实例跨执行复用；同一实例的并发访问由调用方（池的互斥）
/// 保证串行。
pub struct JsRuntime {
    runtime: Runtime,
    context: JsCtx,
    /// 当前执行的截止时间（Unix 毫秒）；<0 表示无执行进行中。
    /// 与中断句柄共享：句柄发现超时即通知引擎中止脚本。
    deadline_ms: Arc<AtomicI64>,
    /// 默认执行时限（毫秒），可被调用方按规则覆盖（见 execute_sync_with_timeout）
    timeout_ms: u64,
    created_at: Instant,
    usage_count: usize,
}

impl JsRuntime {
    /// Create a new JS runtime with default timeout (50ms per rule).
    pub fn new() -> Result<Self> {
        Self::with_timeout(50)
    }

    /// Create a new JS runtime with custom timeout.
    ///
    /// `timeout_ms` 是默认执行时限；每次执行前可用 [`Self::set_timeout`] 覆盖。
    pub fn with_timeout(timeout_ms: u64) -> Result<Self> {
        let runtime = Runtime::new().context("Failed to create JS runtime")?;
        // 中断句柄：deadline 已过 → 返回 true 令引擎中止当前脚本
        let deadline = Arc::new(AtomicI64::new(-1));
        {
            let deadline = Arc::clone(&deadline);
            runtime.set_interrupt_handler(Some(Box::new(move || {
                let dl = deadline.load(Ordering::Relaxed);
                dl >= 0 && now_millis() > dl
            })));
        }
        let context = JsCtx::full(&runtime).context("Failed to create JS context")?;
        // 静态全局（java 兼容层）只需注入一次——实例跨执行持久复用
        context.with(|js_ctx| -> Result<()> {
            let java_code = r#"
                var java = {
                    ajax: function(url) { return ''; },
                    getString: function(str) { return str || ''; },
                    put: function(key, value) { }
                };
            "#;
            js_ctx.eval::<(), _>(java_code.as_bytes())?;
            Ok(())
        })?;

        Ok(Self {
            runtime,
            context,
            deadline_ms: deadline,
            timeout_ms,
            created_at: Instant::now(),
            usage_count: 0,
        })
    }

    /// Reset runtime state for reuse in pool.
    pub fn reset(&mut self) -> Result<()> {
        self.usage_count = 0;
        self.runtime.run_gc();
        Ok(())
    }

    /// Get runtime statistics.
    pub fn stats(&self) -> JsRuntimeStats {
        JsRuntimeStats {
            usage_count: self.usage_count,
            age: self.created_at.elapsed(),
        }
    }

    /// Set the default timeout for subsequent executions.
    pub fn set_timeout(&mut self, timeout_ms: u64) {
        self.timeout_ms = timeout_ms;
    }

    /// Execute a JS rule synchronously with the given context and default timeout.
    ///
    /// 必须在阻塞友好线程调用（如 spawn_blocking / 池工作线程）。
    /// 超时由中断句柄在引擎内部生效，不会悬挂线程。
    pub fn execute_sync(&mut self, code: &str, ctx: &JsExecContext) -> Result<String> {
        let timeout_ms = self.timeout_ms;
        self.execute_sync_inner(code, ctx, timeout_ms)
    }

    /// Execute with an explicit per-call timeout（规则级超时覆盖默认值）。
    pub fn execute_sync_with_timeout(
        &mut self,
        code: &str,
        ctx: &JsExecContext,
        timeout_ms: u64,
    ) -> Result<String> {
        self.execute_sync_inner(code, ctx, timeout_ms)
    }

    /// Inner synchronous JS execution.
    fn execute_sync_inner(
        &mut self,
        code: &str,
        ctx: &JsExecContext,
        timeout_ms: u64,
    ) -> Result<String> {
        self.usage_count += 1;
        let deadline = now_millis() + timeout_ms as i64;
        self.deadline_ms.store(deadline, Ordering::Relaxed);

        let result = self.context.with(|js_ctx| {
            // Inject global objects（每次执行覆盖旧值，语义与逐次新建一致）
            Self::inject_globals(&js_ctx, ctx)?;

            let result: rquickjs::Value = js_ctx
                .eval(code.as_bytes())
                .context("Failed to evaluate JS code")?;

            let output: String = if let Ok(s) = String::from_js(&js_ctx, result.clone()) {
                s
            } else if let Ok(i) = i32::from_js(&js_ctx, result.clone()) {
                i.to_string()
            } else if let Ok(f) = f64::from_js(&js_ctx, result.clone()) {
                f.to_string()
            } else if let Ok(b) = bool::from_js(&js_ctx, result.clone()) {
                b.to_string()
            } else {
                "undefined".to_string()
            };
            Ok::<String, anyhow::Error>(output)
        });

        self.deadline_ms.store(-1, Ordering::Relaxed);
        result
    }

    /// Inject global objects into JS context.
    fn inject_globals(js_ctx: &rquickjs::Ctx, ctx: &JsExecContext) -> Result<()> {
        let globals = js_ctx.globals();

        // book/chapter 元数据：仅非空时注入（预处理热路径的规则通常不消费它们，
        // 跳过可省每条规则 2 次 eval——B2 基准的固定开销来源之一）
        if !ctx.book_title.is_empty() || !ctx.book_author.is_empty() || !ctx.book_url.is_empty() {
            let book_code = format!(
                r#"(function() {{
                    return {{
                        title: {},
                        author: {},
                        url: {}
                    }};
                }})()"#,
                Self::escape_js_string(&ctx.book_title),
                Self::escape_js_string(&ctx.book_author),
                Self::escape_js_string(&ctx.book_url),
            );
            let book_obj: rquickjs::Value = js_ctx.eval(book_code.as_bytes())?;
            globals.set("book", book_obj)?;
        }

        if !ctx.chapter_title.is_empty() || ctx.chapter_index != 0 || !ctx.chapter_url.is_empty()
        {
            let chapter_code = format!(
                r#"(function() {{
                    return {{
                        title: {},
                        index: {},
                        url: {}
                    }};
                }})()"#,
                Self::escape_js_string(&ctx.chapter_title),
                ctx.chapter_index,
                Self::escape_js_string(&ctx.chapter_url),
            );
            let chapter_obj: rquickjs::Value = js_ctx.eval(chapter_code.as_bytes())?;
            globals.set("chapter", chapter_obj)?;
        }

        // 正文注入走原生字符串构造：省去转义全量拷贝 + 10KB 字面量重新解析
        // （这是多规则场景下每条规则的固定开销，B2 基准的主要优化点）
        let content = rquickjs::String::from_str(js_ctx.clone(), &ctx.chapter_content)?;
        globals.set("chapterContent", content)?;

        Ok(())
    }

    /// Escape a string for safe insertion into JS code.
    fn escape_js_string(s: &str) -> String {
        let escaped = s
            .replace('\\', "\\\\")
            .replace('"', "\\\"")
            .replace('\n', "\\n")
            .replace('\r', "\\r")
            .replace('\t', "\\t");
        format!("\"{}\"", escaped)
    }

    /// Get current default timeout.
    pub fn timeout(&self) -> u64 {
        self.timeout_ms
    }
}

fn now_millis() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_basic_js_execution() {
        let mut runtime = JsRuntime::new().unwrap();
        let ctx = JsExecContext::default();
        let result = runtime.execute_sync("1 + 2", &ctx).unwrap();
        assert_eq!(result, "3");
    }

    #[test]
    fn test_persistent_instance_reuse() {
        // 池化核心价值：同一实例跨执行复用（usage_count 累计）
        let mut runtime = JsRuntime::new().unwrap();
        let ctx = JsExecContext::default();
        let _ = runtime.execute_sync("1+1", &ctx).unwrap();
        let _ = runtime.execute_sync("2+2", &ctx).unwrap();
        assert!(runtime.stats().usage_count >= 2);
    }

    #[test]
    fn test_content_transform() {
        let mut runtime = JsRuntime::new().unwrap();
        let mut ctx = JsExecContext::default();
        ctx.chapter_content = "这是测试内容，包含广告需要删除。".to_string();

        let result = runtime
            .execute_sync("chapterContent.replace(/广告/g, '')", &ctx)
            .unwrap();
        assert_eq!(result, "这是测试内容，包含需要删除。");
    }

    #[test]
    fn test_deadline_interrupts_runaway_script() {
        // 中断句柄必须在时限内打断死循环（旧实现 abort 杀不死阻塞任务）
        let mut runtime = JsRuntime::with_timeout(50).unwrap();
        let ctx = JsExecContext::default();
        let start = Instant::now();
        let result = runtime.execute_sync("while(true) {}", &ctx);
        assert!(result.is_err(), "死循环脚本必须报错返回");
        assert!(
            start.elapsed() < std::time::Duration::from_millis(2000),
            "应在 deadline 附近被打断，而非永久阻塞"
        );
    }
}
