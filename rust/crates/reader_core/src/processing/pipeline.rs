use std::collections::HashMap;
use std::time::Instant;

use anyhow::Result;
use tokio::sync::mpsc;

use super::stages::ProcessingStage;

/// Pipeline configuration.
#[derive(Debug, Clone)]
pub struct PipelineConfig {
    /// Enable duplicate title removal.
    pub remove_duplicate_title: bool,
    /// Enable re-segmentation.
    pub re_segment: bool,
    /// Enable HTML tag protection.
    pub protect_html: bool,
    /// Overall pipeline timeout in seconds.
    pub timeout_secs: u64,
    /// Skip stages on error instead of failing the pipeline.
    pub skip_on_error: bool,
}

impl Default for PipelineConfig {
    fn default() -> Self {
        Self {
            remove_duplicate_title: true,
            re_segment: false,
            protect_html: true,
            timeout_secs: 5,
            skip_on_error: true,
        }
    }
}

/// Data flowing through the processing pipeline.
#[derive(Debug, Clone)]
pub struct PipelineData {
    pub content: String,
    pub chapter_title: String,
    pub chapter_index: usize,
    pub book_title: String,
    pub html_map: Option<HashMap<String, String>>,
    /// JS 替换规则（由 JsExecutorWithPool 执行，D9 主路径）
    pub js_rules: Vec<crate::content_preprocessor::ReplaceRule>,
}

impl Default for PipelineData {
    fn default() -> Self {
        Self {
            content: String::new(),
            chapter_title: String::new(),
            chapter_index: 0,
            book_title: String::new(),
            html_map: None,
            js_rules: Vec::new(),
        }
    }
}

/// Processing pipeline that orchestrates multiple stages.
pub struct ProcessingPipeline {
    stages: Vec<Box<dyn ProcessingStage>>,
    config: PipelineConfig,
}

impl ProcessingPipeline {
    /// Create a new pipeline with config.
    pub fn new(config: PipelineConfig) -> Self {
        Self {
            stages: Vec::new(),
            config,
        }
    }

    /// Create a pipeline builder.
    pub fn builder() -> PipelineBuilder {
        PipelineBuilder::new()
    }

    /// Add a stage to the pipeline.
    pub fn add_stage(&mut self, stage: Box<dyn ProcessingStage>) {
        self.stages.push(stage);
    }

    /// Process content through all stages.
    pub async fn process(&mut self, input: PipelineData) -> Result<PipelineData> {
        let start = Instant::now();
        let mut current = input;

        for stage in &self.stages {
            if stage.is_skippable() {
                log::debug!("Skipping stage: {}", stage.stage_name());
                continue;
            }

            log::debug!("Processing stage: {}", stage.stage_name());
            match stage.process(current.clone()).await {
                Ok(output) => current = output,
                Err(e) => {
                    if self.config.skip_on_error {
                        log::warn!(
                            "Stage '{}' failed: {}, continuing...",
                            stage.stage_name(),
                            e
                        );
                        // Continue with unchanged content
                    } else {
                        return Err(e);
                    }
                }
            }

            // Check timeout
            if start.elapsed().as_secs() > self.config.timeout_secs {
                log::warn!(
                    "Pipeline timeout after {}s at stage: {}",
                    start.elapsed().as_secs(),
                    stage.stage_name()
                );
                break;
            }
        }

        let elapsed = start.elapsed();
        if elapsed.as_millis() > 100 {
            log::info!("Pipeline processing took {}ms", elapsed.as_millis());
        }

        Ok(current)
    }

    /// Process content through all stages with streaming output.
    pub fn process_streaming(
        mut self,
        input: PipelineData,
    ) -> (mpsc::Receiver<PipelineData>, tokio::task::JoinHandle<Result<()>>) {
        let (tx, rx) = mpsc::channel(16);
        let config = self.config.clone();
        let stages = std::mem::take(&mut self.stages);

        let handle = tokio::spawn(async move {
            let mut current = input;
            let start = Instant::now();

            for stage in stages.iter() {
                if stage.is_skippable() {
                    continue;
                }

                current = stage.process(current).await?;
                let _ = tx.send(current.clone()).await;

                if start.elapsed().as_secs() > config.timeout_secs {
                    break;
                }
            }

            Ok(())
        });

        (rx, handle)
    }

    /// Get the number of stages.
    pub fn stage_count(&self) -> usize {
        self.stages.len()
    }

    /// Get stage names.
    pub fn stage_names(&self) -> Vec<&'static str> {
        self.stages.iter().map(|s| s.stage_name()).collect()
    }
}

/// Pipeline builder for convenient construction.
pub struct PipelineBuilder {
    stages: Vec<Box<dyn ProcessingStage>>,
    config: PipelineConfig,
}

impl PipelineBuilder {
    pub fn new() -> Self {
        Self {
            stages: Vec::new(),
            config: PipelineConfig::default(),
        }
    }

    pub fn config(mut self, config: PipelineConfig) -> Self {
        self.config = config;
        self
    }

    pub fn add_stage(mut self, stage: Box<dyn ProcessingStage>) -> Self {
        self.stages.push(stage);
        self
    }

    pub fn build(self) -> ProcessingPipeline {
        ProcessingPipeline {
            stages: self.stages,
            config: self.config,
        }
    }
}

/// Build the optimized preprocessing pipeline with all stages in correct order.
#[cfg(feature = "js-engine")]
pub fn build_optimized_pipeline(
    js_pool: Option<Arc<super::js_runtime_pool::JsRuntimePool>>,
) -> ProcessingPipeline {
    use super::content_cleaner::ContentCleaner;
    use super::stages::*;

    let mut builder = ProcessingPipeline::builder()
        .config(PipelineConfig {
            skip_on_error: true,
            ..Default::default()
        })
        // Stage 1: Title dedup (fast, high priority)
        .add_stage(Box::new(DuplicateTitleRemover::new()))
        // Stage 2: HTML protection (before JS)
        .add_stage(Box::new(HtmlProtector::default()))
        // Stage 3: Content cleaning (headers, OCR, separators)
        .add_stage(Box::new(ContentCleaner::new()));

    // Stage 4: JS rules (optional, needs pool)
    if let Some(pool) = js_pool {
        builder = builder.add_stage(Box::new(super::stages::JsExecutorWithPool::new(pool)));
    }

    builder = builder
        // Stage 5: HTML restore
        .add_stage(Box::new(HtmlRestorer))
        // Stage 6: Re-segment
        .add_stage(Box::new(ResegmentProcessor));

    builder.build()
}

/// Build the optimized preprocessing pipeline without JS engine support.
#[cfg(not(feature = "js-engine"))]
pub fn build_optimized_pipeline() -> ProcessingPipeline {
    use super::content_cleaner::ContentCleaner;
    use super::stages::*;

    ProcessingPipeline::builder()
        .config(PipelineConfig {
            skip_on_error: true,
            ..Default::default()
        })
        // Stage 1: Title dedup (fast, high priority)
        .add_stage(Box::new(DuplicateTitleRemover::new()))
        // Stage 2: HTML protection (before JS)
        .add_stage(Box::new(HtmlProtector::default()))
        // Stage 3: Content cleaning (headers, OCR, separators)
        .add_stage(Box::new(ContentCleaner::new()))
        // Stage 4: HTML restore
        .add_stage(Box::new(HtmlRestorer))
        // Stage 5: Re-segment
        .add_stage(Box::new(ResegmentProcessor))
        .build()
}

use std::sync::Arc;

#[cfg(test)]
mod tests {
    use super::*;
    use super::super::stages::*;

    #[tokio::test]
    async fn test_pipeline_basic() {
        let mut pipeline = ProcessingPipeline::builder()
            .add_stage(Box::new(DuplicateTitleRemover::new()))
            .add_stage(Box::new(ResegmentProcessor))
            .build();

        let input = PipelineData {
            content: "第一章 测试\n\n\n这是内容".to_string(),
            chapter_title: "第一章 测试".to_string(),
            ..Default::default()
        };

        let output = pipeline.process(input).await.unwrap();
        assert_eq!(output.content, "这是内容");
    }

    #[tokio::test]
    async fn test_pipeline_with_replacements() {
        let mut pipeline = ProcessingPipeline::builder()
            .add_stage(Box::new(StringReplacer::new(vec![(
                "测试".to_string(),
                "TEST".to_string(),
            )])))
            .add_stage(Box::new(RegexReplacer::new(vec![(
                r"\d+".to_string(),
                "[数字]".to_string(),
            )])))
            .build();

        let input = PipelineData {
            content: "这是123测试456内容".to_string(),
            ..Default::default()
        };

        let output = pipeline.process(input).await.unwrap();
        assert_eq!(output.content, "这是[数字]TEST[数字]内容");
    }

    #[tokio::test]
    async fn test_pipeline_stage_names() {
        let pipeline = ProcessingPipeline::builder()
            .add_stage(Box::new(DuplicateTitleRemover::new()))
            .add_stage(Box::new(ResegmentProcessor))
            .build();

        let names = pipeline.stage_names();
        assert_eq!(names, vec!["DuplicateTitleRemover", "ResegmentProcessor"]);
    }

    #[tokio::test]
    async fn test_pipeline_skip_on_error() {
        let mut pipeline = ProcessingPipeline::builder()
            .config(PipelineConfig {
                skip_on_error: true,
                ..Default::default()
            })
            .add_stage(Box::new(DuplicateTitleRemover::new()))
            .add_stage(Box::new(ResegmentProcessor))
            .build();

        let input = PipelineData {
            content: "测试内容".to_string(),
            ..Default::default()
        };

        let output = pipeline.process(input).await.unwrap();
        assert_eq!(output.content, "测试内容");
    }

    #[tokio::test]
    async fn test_build_optimized_pipeline() {
        #[cfg(feature = "js-engine")]
        let pipeline = build_optimized_pipeline(None);
        #[cfg(not(feature = "js-engine"))]
        let pipeline = build_optimized_pipeline();
        assert!(pipeline.stage_count() >= 5);
        let names = pipeline.stage_names();
        assert!(names.contains(&"DuplicateTitleRemover"));
        assert!(names.contains(&"ContentCleaner"));
        assert!(names.contains(&"HtmlProtector"));
        assert!(names.contains(&"HtmlRestorer"));
        assert!(names.contains(&"ResegmentProcessor"));
    }
}
