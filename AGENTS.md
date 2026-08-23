# AGENTS.md - Agent Instructions

## Project Overview

Flutter + Rust cross-platform reader app (Legado Flutter). Uses `flutter_rust_bridge` 2.12.0 for FFI.

## Critical Build Steps

**Always use `fix_sync.ps1` after modifying Rust code:**
```powershell
cd D:\android\example\legado_flutter
.\fix_sync.ps1
```

This script performs the full rebuild cycle: clean → codegen → Rust build → **copy DLL** → Flutter build.

**DLL copy is required** - Rust outputs to `rust/target/release/bridge.dll` but Flutter loads from `rust/crates/bridge/target/release/bridge.dll`. The script handles this automatically.

## Development Commands

| Task | Command |
|------|---------|
| Full rebuild | `.\fix_sync.ps1` |
| Quick rebuild (skip Rust) | `.\build.ps1 -SkipRust` |
| Rust build only | `cd rust && cargo build --release` |
| Flutter only | `flutter run -d windows` |
| Rust tests | `cd rust && cargo test --package <package_name>` |
| FFI codegen | `flutter_rust_bridge_codegen generate` |
| Flutter analyze | `flutter analyze` |

## Architecture

```
rust/crates/
├── book_parser/       # TXT parsing, encoding detection, chapter extraction
├── layout_engine/     # Text layout, pagination, font metrics, glyph cache
├── bridge/            # FFI entry point (api.rs exports to Dart)
├── reader_core/       # Content preprocessing, pagination cache
└── book_source_engine/ # Book source rules (CSS/JSONPath/Regex, no JS engine)
```

- **bridge/api.rs** is the FFI entry point - all Rust functions exposed to Dart live here
- **lib/core/ffi/book_service.dart** wraps Rust calls for Flutter
- Generated FFI code: `lib/core/ffi/rust_bridge.dart/` and `rust/crates/bridge/src/frb_generated.rs`

## Key Gotchas

1. **FFI binding sync**: After changing API signatures in `bridge/src/api.rs`, run `flutter_rust_bridge_codegen generate`
2. **Font loading**: Must call `loadFontFile()` before layout works - default font is `C:\Windows\Fonts\simsun.ttc`
3. **UTF-8 boundaries**: All string slicing in `book_parser` must use `is_char_boundary()` checks - see `docs/BUG_FIXES.md` §5
4. **Pagination cache**: Uses LRU (10 chapters). Call `clear_pagination_cache_for_book()` when switching books
5. **Chinese text**: Full-width spaces `\u{3000}` are 3 bytes - byte offset calculations must account for this
6. **CRLF line endings**: Never accumulate byte offsets via `lines()[i].len() + 1` - `\r` is stripped by `lines()`. Scan raw bytes for `\n` instead - see `docs/BUGFIX_INDEX.md`
7. **Chapter boundaries vs cleaning**: Content cleaning can restructure lines, so chapter positions must be (re)computed on the same text they index into - see `docs/BUGFIX_INDEX.md`

## Testing

- Test book: `D:\android\example\test_book.txt`
- Real-book verification example: `cd rust && cargo run --release --package book_parser --example verify_real_book`
- Rust unit tests: `cargo test --package book_parser`, `cargo test --package reader_core`, `cargo test --package layout_engine`
- Integration test: `cargo test --package reader_core --test pipeline_demo`

## Documentation

- `docs/BUGFIX_INDEX.md` - **Bug 快速查找索引（遇到问题先看这里）**
- `docs/BUG_FIXES.md` - Known issues and fixes (UTF-8 panics, build failures, etc.)
- `docs/bugfixes/` - Individual incident reports (dated)
- `docs/design/` - Design docs for each Rust module
- Historical reports are in `docs/archive/` (do not maintain)

## Conventions

- Code comments are in Chinese
- Windows PowerShell for build scripts
- Rust edition 2021, Flutter SDK ^3.12.2
- State management: Riverpod
- No JS engine in book source rules (only CSS selectors, JSONPath, Regex)
