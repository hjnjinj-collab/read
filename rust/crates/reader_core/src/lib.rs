pub mod content_preprocessor;
pub mod task_scheduler;
pub mod chapter_utils;
pub mod pagination_cache;
pub mod loading;
pub mod processing;
pub mod cache;
pub mod scheduler;
pub mod session;

pub use content_preprocessor::{
    ChineseConvertType, ContentPreprocessor, ContentProcessError, ProcessOptions, ReplaceRule,
    RuleType,
};
pub use task_scheduler::ChapterTaskScheduler;
pub use chapter_utils::{ChapterInfo, extract_chapter_number, get_pure_chapter_name};
pub use pagination_cache::{PaginationCache, CacheKey, CachedChapterPages, CacheStats};
pub use loading::{BookLoader, LoadingProgress, LoadingStage, LoadingCallbacks};

#[cfg(feature = "js-engine")]
pub use processing::{
    JsRuntime, JsExecContext, JsRuntimeStats,
    JsRuntimePool, PooledRuntime, PoolStats, PoolStatus,
};

pub use processing::{
    ChineseConverter, ConvertMode,
    ProcessingPipeline, PipelineConfig, PipelineData,
    ContentCleaner,
    ParagraphFormatSettings, ReParagraphMode,
    ParagraphFormatter,
    split_pieces, split_ranges,
    AGGRESSIVE_THRESHOLD, SMART_THRESHOLD,
};

pub use scheduler::{
    PreloadStrategy, DefaultPreloadStrategy, PreloadPriority, PreloadTask,
    PreloadExecutor, PreloadExecutorConfig, PreloadHandle, PreloadResult, PreloadStatus, PreloadStats,
};
pub use session::{
    ChapterCache, CachedChapterPages as ChapterCachePages,
    ReadSession, ReadSessionManager, ReadSessionRef,
};
