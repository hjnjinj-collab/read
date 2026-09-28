//! OCR：可插拔引擎 + **可下载模型**（不打进 APK）
//!
//! - `OcrEngine`：识别页光栅 → 文本
//! - `OcrModelManager`：模型目录、安装、状态
//! - `TesseractCliOcr`：本机 tesseract + 已下载 traineddata（默认实现）
//! - `NullOcr`：无模型时占位（调用方降级「对照」模式）
//!
//! 模型包约定（下载 zip 解压后）：
//! `ocr/chi_sim.traineddata`（或 `eng` 等）+ 可选 `tessdata/` 根。

use anyhow::Result;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

/// 识别一页图（PNG/JPEG 字节）
pub trait OcrEngine: Send + Sync {
    fn name(&self) -> &'static str;
    /// 模型/依赖是否就绪
    fn is_ready(&self) -> bool;
    fn recognize(&self, image_bytes: &[u8]) -> Result<String>;
}

/// 无模型占位
pub struct NullOcr;

impl OcrEngine for NullOcr {
    fn name(&self) -> &'static str {
        "null"
    }
    fn is_ready(&self) -> bool {
        false
    }
    fn recognize(&self, _image_bytes: &[u8]) -> Result<String> {
        anyhow::bail!("OCR 模型未安装")
    }
}

/// 调用本机 tesseract（模型 traineddata 由用户下载，不进 APK）
pub struct TesseractCliOcr {
    tessdata_dir: PathBuf,
    lang: String,
}

impl TesseractCliOcr {
    pub fn new(tessdata_dir: PathBuf, lang: impl Into<String>) -> Self {
        Self {
            tessdata_dir,
            lang: lang.into(),
        }
    }

    fn find_tesseract() -> Option<PathBuf> {
        for c in ["tesseract", "tesseract.exe"] {
            if let Ok(p) = which(c) {
                return Some(p);
            }
        }
        None
    }
}

fn which(cmd: &str) -> Result<PathBuf> {
    let out = std::process::Command::new(cmd)
        .arg("--version")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status();
    if out.is_ok() {
        return Ok(PathBuf::from(cmd));
    }
    anyhow::bail!("not found")
}

impl OcrEngine for TesseractCliOcr {
    fn name(&self) -> &'static str {
        "tesseract"
    }

    fn is_ready(&self) -> bool {
        Self::find_tesseract().is_some() && self.lang_data_path().exists()
    }

    fn recognize(&self, image_bytes: &[u8]) -> Result<String> {
        let tesseract = Self::find_tesseract()
            .ok_or_else(|| anyhow::anyhow!("未找到 tesseract 可执行文件"))?;
        if !self.lang_data_path().exists() {
            anyhow::bail!("OCR 语言包未安装: {}", self.lang_data_path().display());
        }
        let tmp = std::env::temp_dir().join(format!(
            "ocr_{}_{}.png",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0)
        ));
        std::fs::write(&tmp, image_bytes)?;
        let out_base = tmp.with_extension("txt");
        let status = std::process::Command::new(&tesseract)
            .arg(&tmp)
            .arg(out_base.with_extension("")) // tesseract 加 .txt
            .arg("-l")
            .arg(&self.lang)
            .arg("--tessdata-dir")
            .arg(&self.tessdata_dir)
            .arg("--psm")
            .arg("6")
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()?;
        let _ = std::fs::remove_file(&tmp);
        if !status.success() {
            let _ = std::fs::remove_file(&out_base);
            anyhow::bail!("tesseract 失败");
        }
        let text = std::fs::read_to_string(&out_base).unwrap_or_default();
        let _ = std::fs::remove_file(&out_base);
        Ok(text.trim().to_string())
    }
}

impl TesseractCliOcr {
    fn lang_data_path(&self) -> PathBuf {
        self.tessdata_dir.join(format!("{}.traineddata", self.lang))
    }
}

/// 模型安装状态
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OcrModelStatus {
    NotInstalled,
    Installed { lang: String, data_file: String },
}

/// 模型目录管理（app support 下 `ocr/`）
pub struct OcrModelManager {
    root: Mutex<PathBuf>,
    lang: Mutex<String>,
}

impl Clone for OcrModelManager {
    fn clone(&self) -> Self {
        Self::new(self.root())
    }
}

impl OcrModelManager {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self {
            root: Mutex::new(root.into()),
            lang: Mutex::new("chi_sim".to_string()),
        }
    }

    pub fn root(&self) -> PathBuf {
        self.root.lock().unwrap().clone()
    }

    pub fn lang(&self) -> String {
        self.lang.lock().unwrap().clone()
    }

    pub fn set_lang(&self, lang: impl Into<String>) {
        *self.lang.lock().unwrap() = lang.into();
    }

    pub fn status(&self) -> OcrModelStatus {
        let lang = self.lang();
        let data = self
            .root()
            .join(format!("{lang}.traineddata"));
        if data.exists() {
            OcrModelStatus::Installed {
                lang,
                data_file: data.display().to_string(),
            }
        } else {
            OcrModelStatus::NotInstalled
        }
    }

    /// 从已下载文件安装（copy 到模型目录）
    pub fn install_from_file(&self, src: &Path) -> Result<PathBuf> {
        let dst_dir = self.root();
        std::fs::create_dir_all(&dst_dir)?;
        let lang = self.lang();
        let dst = dst_dir.join(format!("{lang}.traineddata"));
        std::fs::copy(src, &dst)?;
        Ok(dst)
    }

    /// 从字节安装（下载完成后落盘）
    pub fn install_from_bytes(&self, bytes: &[u8]) -> Result<PathBuf> {
        // 防「假成功」：空包/错误页/极小文件不得当模型装入
        if bytes.len() < 2048 {
            anyhow::bail!("模型数据过小（{} 字节），下载可能失败", bytes.len());
        }
        // 常见错误页/HTML
        let head = &bytes[..bytes.len().min(64)];
        if head.starts_with(b"<") || head.starts_with(b"<!DOCTYPE") {
            anyhow::bail!("内容是 HTML 而非模型文件（可能被网关拦截）");
        }
        let dst_dir = self.root();
        std::fs::create_dir_all(&dst_dir)?;
        let lang = self.lang();
        let dst = dst_dir.join(format!("{lang}.traineddata"));
        std::fs::write(&dst, bytes)?;
        Ok(dst)
    }

    pub fn uninstall(&self) -> Result<()> {
        if let OcrModelStatus::Installed { data_file, .. } = self.status() {
            let _ = std::fs::remove_file(data_file);
        }
        Ok(())
    }

    /// 构建当前引擎（未装模型 → Null）
    pub fn build_engine(&self) -> Box<dyn OcrEngine> {
        match self.status() {
            OcrModelStatus::Installed { .. } => Box::new(TesseractCliOcr::new(
                self.root(),
                self.lang(),
            )),
            OcrModelStatus::NotInstalled => Box::new(NullOcr),
        }
    }
}

/// 页 OCR 结果磁盘缓存（键：book 配置 hash + 页）
#[derive(Default)]
pub struct OcrPageCache {
    dir: Mutex<Option<PathBuf>>,
}

impl OcrPageCache {
    pub fn set_dir(&self, dir: impl Into<PathBuf>) {
        *self.dir.lock().unwrap() = Some(dir.into());
    }

    fn path_for(&self, key: &str) -> Option<PathBuf> {
        let dir = self.dir.lock().unwrap().clone()?;
        Some(dir.join(format!("{key}.txt")))
    }

    pub fn get(&self, key: &str) -> Option<String> {
        let p = self.path_for(key)?;
        std::fs::read_to_string(p).ok().filter(|s| !s.is_empty())
    }

    pub fn put(&self, key: &str, text: &str) -> Result<()> {
        if let Some(p) = self.path_for(key) {
            if let Some(parent) = p.parent() {
                std::fs::create_dir_all(parent)?;
            }
            std::fs::write(p, text)?;
        }
        Ok(())
    }
}

/// 测试用 mock 引擎
pub struct MockOcr {
    pub text: String,
    pub ready: bool,
}

impl OcrEngine for MockOcr {
    fn name(&self) -> &'static str {
        "mock"
    }
    fn is_ready(&self) -> bool {
        self.ready
    }
    fn recognize(&self, _image_bytes: &[u8]) -> Result<String> {
        if !self.ready {
            anyhow::bail!("mock not ready");
        }
        Ok(self.text.clone())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn model_status_not_installed() {
        let tmp = tempfile::tempdir().unwrap();
        let m = OcrModelManager::new(tmp.path());
        assert_eq!(m.status(), OcrModelStatus::NotInstalled);
    }

    #[test]
    fn install_and_status() {
        let tmp = tempfile::tempdir().unwrap();
        let m = OcrModelManager::new(tmp.path());
        let p = m.install_from_bytes(&vec![7u8; 8192]).unwrap();
        assert!(p.exists());
        match m.status() {
            OcrModelStatus::Installed { lang, .. } => assert_eq!(lang, "chi_sim"),
            other => panic!("{:?}", other),
        }
        m.uninstall().unwrap();
        assert_eq!(m.status(), OcrModelStatus::NotInstalled);
    }

    #[test]
    fn install_rejects_empty_and_html() {
        let tmp = tempfile::tempdir().unwrap();
        let m = OcrModelManager::new(tmp.path());
        assert!(m.install_from_bytes(b"").is_err());
        assert!(m.install_from_bytes(b"<html>not a model</html>").is_err());
        // 足够大的假数据可通过（真 traineddata 另验）
        let big = vec![0u8; 4096];
        assert!(m.install_from_bytes(&big).is_ok());
    }

    #[test]
    fn mock_engine_recognize() {
        let e = MockOcr {
            text: "测试文本".into(),
            ready: true,
        };
        assert_eq!(e.recognize(&[]).unwrap(), "测试文本");
    }
}
