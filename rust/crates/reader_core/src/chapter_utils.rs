use regex::Regex;

/// Chapter information extracted from title
#[derive(Debug, Clone)]
pub struct ChapterInfo {
    pub title: String,
    pub pure_title: String,
    pub chapter_number: i32,
}

impl ChapterInfo {
    pub fn new(title: String) -> Self {
        let pure_title = get_pure_chapter_name(&title);
        let chapter_number = extract_chapter_number(&title);
        Self {
            title,
            pure_title,
            chapter_number,
        }
    }
}

/// Extract chapter number from title
/// Supports:
/// - 第123章
/// - 第一百二十三章
/// - 001、002
pub fn extract_chapter_number(title: &str) -> i32 {
    let title = full_to_half(title).replace(char::is_whitespace, "");

    // Pattern 1: 第XXX章/节/篇/回/集/话
    let pattern1 = Regex::new(
        r"第([\d零〇一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]+)[章节篇回集话]",
    )
    .unwrap();

    if let Some(caps) = pattern1.captures(&title) {
        if let Some(num_str) = caps.get(1) {
            return chinese_num_to_int(num_str.as_str());
        }
    }

    // Pattern 2: 001、002 or similar prefix patterns
    let pattern2 = Regex::new(
        r"^(?:[\d零〇一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]+[,:、])*([\d零〇一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]+)[,:、：]",
    )
    .unwrap();

    if let Some(caps) = pattern2.captures(&title) {
        if let Some(num_str) = caps.get(1) {
            return chinese_num_to_int(num_str.as_str());
        }
    }

    -1
}

/// Get pure chapter name (remove chapter number prefix and brackets)
pub fn get_pure_chapter_name(title: &str) -> String {
    if title.is_empty() {
        return String::new();
    }

    let mut result = full_to_half(title);

    // Remove whitespace
    result = result.replace(char::is_whitespace, "");

    // Remove chapter number prefix: 第XXX章 pattern
    let regex_chapter = Regex::new(
        r"^.*?第[\d零〇一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]+[章节篇回集话]\s*",
    )
    .unwrap();
    result = regex_chapter.replace(&result, "").to_string();

    // Remove number prefix: 001、002 pattern
    let regex_number = Regex::new(
        r"^[\d零〇一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]+[,:、：]\s*",
    )
    .unwrap();
    result = regex_number.replace(&result, "").to_string();

    // Remove brackets and their content (simple approach)
    let brackets = [
        ('【', '】'),
        ('〖', '〗'),
        ('《', '》'),
        ('〔', '〕'),
        ('[', ']'),
        ('{', '}'),
        ('(', ')'),
    ];
    
    for (open, close) in &brackets {
        while let Some(start) = result.find(*open) {
            if let Some(end) = result[start..].find(*close) {
                result.replace_range(start..start + end + close.len_utf8(), "");
            } else {
                break;
            }
        }
    }

    // Remove non-alphanumeric and non-CJK characters
    let regex_other = Regex::new(r"[^\w\u4E00-\u9FEF〇\u3400-\u4DBF]").unwrap();
    result = regex_other.replace_all(&result, "").to_string();

    result
}

/// Convert full-width characters to half-width
fn full_to_half(s: &str) -> String {
    s.chars()
        .map(|c| {
            let code = c as u32;
            if code == 0x3000 {
                // Full-width space -> half-width space
                ' '
            } else if (0xFF01..=0xFF5E).contains(&code) {
                // Full-width ASCII -> half-width ASCII
                char::from_u32(code - 0xFEE0).unwrap_or(c)
            } else {
                c
            }
        })
        .collect()
}

/// Convert Chinese number string to integer
fn chinese_num_to_int(s: &str) -> i32 {
    // First try to parse as regular number
    if let Ok(num) = s.parse::<i32>() {
        return num;
    }

    // Chinese number conversion
    let mut result = 0;
    let mut current_section = 0; // Current section value (before 十/百/千)
    let mut current_digit = 0; // Current digit value (一/二/三...)

    for c in s.chars() {
        match c {
            '零' | '〇' => {
                // Zero resets current digit but keeps section
                current_digit = 0;
            }
            '一' | '壹' => current_digit = 1,
            '二' | '两' | '贰' => current_digit = 2,
            '三' | '叁' => current_digit = 3,
            '四' | '肆' => current_digit = 4,
            '五' | '伍' => current_digit = 5,
            '六' | '陆' => current_digit = 6,
            '七' | '柒' => current_digit = 7,
            '八' | '捌' => current_digit = 8,
            '九' | '玖' => current_digit = 9,
            '十' | '拾' => {
                if current_digit == 0 {
                    current_digit = 1;
                }
                current_section += current_digit * 10;
                current_digit = 0;
            }
            '百' | '佰' => {
                if current_digit == 0 {
                    current_digit = 1;
                }
                current_section += current_digit * 100;
                current_digit = 0;
            }
            '千' | '仟' => {
                if current_digit == 0 {
                    current_digit = 1;
                }
                current_section += current_digit * 1000;
                current_digit = 0;
            }
            '万' => {
                if current_digit > 0 {
                    current_section += current_digit;
                    current_digit = 0;
                }
                if current_section == 0 {
                    current_section = 1;
                }
                result += current_section * 10000;
                current_section = 0;
            }
            '亿' => {
                if current_digit > 0 {
                    current_section += current_digit;
                    current_digit = 0;
                }
                if current_section == 0 {
                    current_section = 1;
                }
                result += current_section * 100000000;
                current_section = 0;
            }
            _ => {}
        }
    }

    // Add remaining values
    result += current_section + current_digit;

    if result == 0 {
        -1
    } else {
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_extract_chapter_number() {
        assert_eq!(extract_chapter_number("第1章 开始"), 1);
        assert_eq!(extract_chapter_number("第123章 战斗"), 123);
        assert_eq!(extract_chapter_number("第一章 序幕"), 1);
        assert_eq!(extract_chapter_number("第十章 转折"), 10);
        assert_eq!(extract_chapter_number("第一百二十三章"), 123);
        assert_eq!(extract_chapter_number("001、序章"), 1);
        assert_eq!(extract_chapter_number("042：决战"), 42);
        assert_eq!(extract_chapter_number("无章节号的标题"), -1);
    }

    #[test]
    fn test_get_pure_chapter_name() {
        assert_eq!(get_pure_chapter_name("第1章 开始"), "开始");
        assert_eq!(get_pure_chapter_name("第123章 战斗"), "战斗");
        assert_eq!(get_pure_chapter_name("001、序章"), "序章");
        assert_eq!(get_pure_chapter_name("第一章【VIP】"), ""); // Brackets removed
        assert_eq!(
            get_pure_chapter_name("第42章 最终决战（上）"),
            "最终决战" // Brackets removed
        );
        assert_eq!(
            get_pure_chapter_name("第10章 VIP章节"),
            "VIP章节"
        );
    }

    #[test]
    fn test_chinese_num_to_int() {
        assert_eq!(chinese_num_to_int("一"), 1);
        assert_eq!(chinese_num_to_int("十"), 10);
        assert_eq!(chinese_num_to_int("一十"), 10);
        assert_eq!(chinese_num_to_int("二十"), 20);
        assert_eq!(chinese_num_to_int("一百"), 100);
        assert_eq!(chinese_num_to_int("一百二十三"), 123);
        assert_eq!(chinese_num_to_int("一千"), 1000);
        assert_eq!(chinese_num_to_int("九千九百九十九"), 9999);
        assert_eq!(chinese_num_to_int("123"), 123);
    }

    #[test]
    fn test_full_to_half() {
        assert_eq!(full_to_half("ＡＢＣ"), "ABC");
        assert_eq!(full_to_half("１２３"), "123");
        assert_eq!(full_to_half("（）"), "()");
        assert_eq!(full_to_half("　"), " "); // Full-width space
    }

    #[test]
    fn test_chapter_info() {
        let info = ChapterInfo::new("第1章 开始".to_string());
        assert_eq!(info.chapter_number, 1);
        assert_eq!(info.pure_title, "开始");

        let info2 = ChapterInfo::new("第一百二十三章 大战".to_string());
        assert_eq!(info2.chapter_number, 123);
        assert_eq!(info2.pure_title, "大战");
        
        let info3 = ChapterInfo::new("第10章 VIP章节【特别篇】".to_string());
        assert_eq!(info3.chapter_number, 10);
        assert_eq!(info3.pure_title, "VIP章节");
    }
}
