use anyhow::Result;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use tokio::sync::Mutex;
use tokio::task::JoinHandle;

/// 加载阶段枚举
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LoadingStage {
    /// 检测文件格式
    DetectingFormat,
    /// 打开文件
    OpeningFile,
    /// 解析元信息
    ParsingMetadata,
    /// 提取章节列表
    ExtractingChapters,
    /// 加载完成
    Completed,
    /// 发生错误
    Error,
}

impl LoadingStage {
    /// 获取阶段的中文描述
    pub fn description(&self) -> &'static str {
        match self {
            LoadingStage::DetectingFormat => "正在检测文件格式...",
            LoadingStage::OpeningFile => "正在打开文件...",
            LoadingStage::ParsingMetadata => "正在解析书籍信息...",
            LoadingStage::ExtractingChapters => "正在提取章节列表...",
            LoadingStage::Completed => "加载完成",
            LoadingStage::Error => "加载失败",
        }
    }
}

/// 加载进度信息
#[derive(Debug, Clone)]
pub struct LoadingProgress {
    /// 进度值 (0.0 - 1.0)
    pub progress: f32,
    /// 状态描述消息
    pub message: String,
    /// 当前阶段
    pub stage: LoadingStage,
}

impl LoadingProgress {
    pub fn new(progress: f32, message: String, stage: LoadingStage) -> Self {
        Self {
            progress,
            message,
            stage,
        }
    }
}

/// 回调函数类型
pub type ProgressCallback = Box<dyn Fn(LoadingProgress) + Send + Sync>;
pub type CompleteCallback = Box<dyn Fn(Result<BookLoadResult>) + Send + Sync>;
pub type ErrorCallback = Box<dyn Fn(String) + Send + Sync>;

/// 加载回调集合
pub struct LoadingCallbacks {
    /// 进度回调
    pub on_progress: Option<ProgressCallback>,
    /// 完成回调
    pub on_complete: Option<CompleteCallback>,
    /// 错误回调
    pub on_error: Option<ErrorCallback>,
}

impl LoadingCallbacks {
    pub fn new() -> Self {
        Self {
            on_progress: None,
            on_complete: None,
            on_error: None,
        }
    }

    /// 设置进度回调
    pub fn with_progress<F>(mut self, callback: F) -> Self
    where
        F: Fn(LoadingProgress) + Send + Sync + 'static,
    {
        self.on_progress = Some(Box::new(callback));
        self
    }

    /// 设置完成回调
    pub fn with_complete<F>(mut self, callback: F) -> Self
    where
        F: Fn(Result<BookLoadResult>) + Send + Sync + 'static,
    {
        self.on_complete = Some(Box::new(callback));
        self
    }

    /// 设置错误回调
    pub fn with_error<F>(mut self, callback: F) -> Self
    where
        F: Fn(String) + Send + Sync + 'static,
    {
        self.on_error = Some(Box::new(callback));
        self
    }
}

impl Default for LoadingCallbacks {
    fn default() -> Self {
        Self::new()
    }
}

/// 书籍加载结果
#[derive(Debug, Clone)]
pub struct BookLoadResult {
    /// 书籍 ID
    pub book_id: String,
    /// 书籍标题
    pub title: String,
    /// 作者
    pub author: String,
    /// 总章节数
    pub total_chapters: usize,
    /// 文件格式
    pub format: String,
}

/// 加载任务
struct LoadingTask {
    /// 任务 ID
    #[allow(dead_code)]
    task_id: String,
    /// 取消标志
    cancel_flag: Arc<AtomicBool>,
    /// 任务句柄
    handle: Option<JoinHandle<()>>,
}

/// 书籍加载器
///
/// 管理书籍加载任务的生命周期，支持：
/// - 自动检测格式并加载
/// - 进度回调
/// - 取消任务
/// - 异步执行
pub struct BookLoader {
    /// 当前正在执行的任务
    current_task: Arc<Mutex<Option<LoadingTask>>>,
    /// 书籍存储（book_id → 解析器状态）
    books: Arc<Mutex<std::collections::HashMap<String, BookState>>>,
}

/// 书籍状态（内部使用）
struct BookState {
    title: String,
    author: String,
    total_chapters: usize,
    format: String,
    #[allow(dead_code)]
    file_path: String,
}

impl BookLoader {
    pub fn new() -> Self {
        Self {
            current_task: Arc::new(Mutex::new(None)),
            books: Arc::new(Mutex::new(std::collections::HashMap::new())),
        }
    }

    /// 异步加载书籍
    ///
    /// 自动检测文件格式，创建解析器，提取元信息和章节列表。
    /// 如果有正在执行的任务，会自动取消旧任务。
    pub async fn load_book(
        &self,
        file_path: String,
        callbacks: LoadingCallbacks,
    ) -> Result<String> {
        // 1. 取消旧任务
        self.cancel_current_task().await;

        // 2. 生成任务 ID
        let task_id = uuid::Uuid::new_v4().to_string();
        let task_id_clone = task_id.clone();

        // 3. 创建取消标志
        let cancel_flag = Arc::new(AtomicBool::new(false));
        let cancel_flag_clone = cancel_flag.clone();

        // 4. 克隆必要的 Arc
        let books = self.books.clone();

        // 5. 启动异步任务
        let handle = tokio::spawn(async move {
            let result = Self::load_book_internal(
                &file_path,
                cancel_flag_clone,
                callbacks.on_progress,
                books,
            )
            .await;

            match result {
                Ok(result) => {
                    if let Some(callback) = callbacks.on_complete {
                        callback(Ok(result));
                    }
                }
                Err(e) => {
                    let msg = e.to_string();
                    if let Some(callback) = callbacks.on_error {
                        callback(msg.clone());
                    }
                    if let Some(callback) = callbacks.on_complete {
                        callback(Err(e));
                    }
                }
            }
        });

        // 6. 保存任务
        {
            let mut current = self.current_task.lock().await;
            *current = Some(LoadingTask {
                task_id: task_id_clone.clone(),
                cancel_flag,
                handle: Some(handle),
            });
        }

        Ok(task_id_clone)
    }

    /// 内部加载逻辑
    async fn load_book_internal(
        file_path: &str,
        cancel_flag: Arc<AtomicBool>,
        on_progress: Option<ProgressCallback>,
        books: Arc<Mutex<std::collections::HashMap<String, BookState>>>,
    ) -> Result<BookLoadResult> {
        // 阶段 1: 检测格式
        if cancel_flag.load(Ordering::SeqCst) {
            return Err(anyhow::anyhow!("加载已取消"));
        }

        if let Some(ref callback) = on_progress {
            callback(LoadingProgress::new(
                0.1,
                LoadingStage::DetectingFormat.description().to_string(),
                LoadingStage::DetectingFormat,
            ));
        }

        let path = Path::new(file_path);
        if !path.exists() {
            return Err(anyhow::anyhow!("文件不存在: {}", file_path));
        }

        // 阶段 2: 打开文件
        if cancel_flag.load(Ordering::SeqCst) {
            return Err(anyhow::anyhow!("加载已取消"));
        }

        if let Some(ref callback) = on_progress {
            callback(LoadingProgress::new(
                0.2,
                LoadingStage::OpeningFile.description().to_string(),
                LoadingStage::OpeningFile,
            ));
        }

        // 阶段 3: 解析元信息
        if cancel_flag.load(Ordering::SeqCst) {
            return Err(anyhow::anyhow!("加载已取消"));
        }

        if let Some(ref callback) = on_progress {
            callback(LoadingProgress::new(
                0.4,
                LoadingStage::ParsingMetadata.description().to_string(),
                LoadingStage::ParsingMetadata,
            ));
        }

        // 创建解析器并解析
        let mut parser = book_parser::loader::BookSourceLoader::load(file_path)?;
        let metadata = parser.parse()?;

        // 阶段 4: 提取章节列表
        if cancel_flag.load(Ordering::SeqCst) {
            return Err(anyhow::anyhow!("加载已取消"));
        }

        if let Some(ref callback) = on_progress {
            callback(LoadingProgress::new(
                0.7,
                LoadingStage::ExtractingChapters.description().to_string(),
                LoadingStage::ExtractingChapters,
            ));
        }

        let _chapters = parser.get_chapter_list()?;

        // 阶段 5: 完成
        if let Some(ref callback) = on_progress {
            callback(LoadingProgress::new(
                1.0,
                LoadingStage::Completed.description().to_string(),
                LoadingStage::Completed,
            ));
        }

        // 生成书籍 ID
        let book_id = format!("book_{}", uuid::Uuid::new_v4());

        // 保存书籍状态
        {
            let mut books_guard = books.lock().await;
            books_guard.insert(
                book_id.clone(),
                BookState {
                    title: metadata.title.clone(),
                    author: metadata.author.clone(),
                    total_chapters: metadata.total_chapters,
                    format: metadata.format.to_string(),
                    file_path: file_path.to_string(),
                },
            );
        }

        Ok(BookLoadResult {
            book_id,
            title: metadata.title,
            author: metadata.author,
            total_chapters: metadata.total_chapters,
            format: metadata.format.to_string(),
        })
    }

    /// 取消当前任务
    pub async fn cancel_current_task(&self) {
        let mut current = self.current_task.lock().await;
        if let Some(task) = current.take() {
            task.cancel_flag.store(true, Ordering::SeqCst);
            if let Some(handle) = task.handle {
                handle.abort();
            }
        }
    }

    /// 获取书籍信息
    pub async fn get_book_info(&self, book_id: &str) -> Option<(String, String, usize, String)> {
        let books = self.books.lock().await;
        books.get(book_id).map(|state| {
            (
                state.title.clone(),
                state.author.clone(),
                state.total_chapters,
                state.format.clone(),
            )
        })
    }

    /// 检查是否有正在执行的任务
    pub async fn has_active_task(&self) -> bool {
        let current = self.current_task.lock().await;
        current.is_some()
    }
}

impl Default for BookLoader {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_book_loader_new() {
        let loader = BookLoader::new();
        assert!(!loader.has_active_task().await);
    }

    #[tokio::test]
    async fn test_cancel_nonexistent_task() {
        let loader = BookLoader::new();
        // 应该不会 panic
        loader.cancel_current_task().await;
        assert!(!loader.has_active_task().await);
    }

    #[tokio::test]
    async fn test_loading_callbacks_builder() {
        let callbacks = LoadingCallbacks::new()
            .with_progress(|_p| {})
            .with_complete(|_r| {})
            .with_error(|_e| {});

        assert!(callbacks.on_progress.is_some());
        assert!(callbacks.on_complete.is_some());
        assert!(callbacks.on_error.is_some());
    }
}
