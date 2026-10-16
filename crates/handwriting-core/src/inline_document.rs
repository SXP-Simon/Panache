use crate::{Error, Limits, Result};
use std::ops::Range;

// 2026-10-16：图片负载与正文分开计量，扫描时不为 base64 分配字符索引。
pub(crate) fn image_payloads(text: &str) -> Vec<Range<usize>> {
    let mut spans = Vec::new();
    let mut fence: Option<(char, usize)> = None;
    let mut offset = 0;
    for line in text.split_inclusive('\n') {
        let trimmed = line.trim();
        let delimiter = trimmed
            .chars()
            .next()
            .filter(|c| "`~".contains(*c))
            .map(|c| (c, trimmed.chars().take_while(|v| *v == c).count()))
            .filter(|(_, n)| *n >= 3);
        if fence.is_some() || delimiter.is_some() {
            if let Some(open) = fence {
                if delimiter.is_some_and(|close| close.0 == open.0 && close.1 >= open.1) {
                    fence = None;
                }
            } else {
                fence = delimiter;
            }
            offset += line.len();
            continue;
        }
        let mut i = 0;
        let mut next_close = None;
        while i < line.len() {
            if let Some(end) = literal_end(line, i) {
                i = end;
                continue;
            }
            if line[i..].starts_with("![") {
                let alt_end =
                    (i + 2..line.len().min(i + 1026)).find(|&j| line.as_bytes()[j] == b']');
                if let Some(end) = alt_end.filter(|end| line.as_bytes().get(end + 1) == Some(&b'('))
                {
                    let start = end + 2;
                    if next_close.is_none_or(|end| end < start) {
                        next_close = line[start..].find(')').map(|j| start + j);
                    }
                    if let Some(close) = next_close {
                        let data = &line[start..close];
                        if valid_image_data(data) {
                            spans.push(offset + start..offset + close);
                            i = close + 1;
                            continue;
                        }
                    }
                }
            }
            i += line[i..].chars().next().unwrap().len_utf8();
        }
        offset += line.len();
    }
    spans
}
fn literal_end(s: &str, start: usize) -> Option<usize> {
    let rest = &s[start..];
    if rest.starts_with('`') {
        let count = rest.bytes().take_while(|b| *b == b'`').count();
        return Some(
            rest[count..]
                .find(&rest[..count])
                .map_or(s.len(), |end| start + count + end + count),
        );
    }
    if start > 0
        && s[..start]
            .chars()
            .next_back()
            .is_some_and(|c| !c.is_whitespace() && !"([{\"'=:：，；".contains(c))
    {
        return None;
    }
    let direct = rest.starts_with("http://")
        || rest.starts_with("https://")
        || rest.starts_with("www.")
        || rest.starts_with('/')
        || rest.starts_with('\\')
        || (rest.as_bytes().get(1) == Some(&b':')
            && rest.as_bytes().get(2).is_some_and(|b| b"/\\".contains(b)));
    let length = rest
        .char_indices()
        .find(|(_, c)| c.is_whitespace() || (!direct && "()[]{}\"'=:：，；".contains(*c)))
        .map_or(rest.len(), |(i, _)| i);
    let word = &rest[..length];
    let bare = word.trim_end_matches(|c| ")]},;。；，".contains(c));
    let date = bare
        .chars()
        .all(|c| c.is_ascii_digit() || "/-.".contains(c))
        && bare.matches('/').count() >= 2;
    let path = word.starts_with('/')
        || word.starts_with("./")
        || word.starts_with("../")
        || word.contains(":\\")
        || (word.as_bytes().get(1) == Some(&b':') && word.as_bytes().get(2) == Some(&b'/'))
        || word.starts_with("\\\\")
        || (word.contains('/')
            && (word.contains('_') || word.rsplit('/').next().is_some_and(|v| v.contains('.'))));
    (date || path || word.contains("://") || word.starts_with("www.")).then_some(start + length)
}
fn valid_image_data(data: &str) -> bool {
    let Some(rest) = data.strip_prefix("data:image/") else {
        return false;
    };
    let Some((mime, payload)) = rest.split_once(";base64,") else {
        return false;
    };
    if mime.is_empty()
        || !mime
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b".+-".contains(&b))
        || payload.is_empty()
    {
        return false;
    }
    let mut count = 0;
    let mut padding = 0;
    let mut last_value = 0u8;
    for b in payload.bytes() {
        if b.is_ascii_whitespace() {
            continue;
        }
        count += 1;
        if b == b'=' {
            padding += 1;
            if padding > 2 {
                return false;
            }
        } else if padding > 0 || !(b.is_ascii_alphanumeric() || b"+/".contains(&b)) {
            return false;
        } else {
            last_value = match b {
                b'A'..=b'Z' => b - b'A',
                b'a'..=b'z' => b - b'a' + 26,
                b'0'..=b'9' => b - b'0' + 52,
                b'+' => 62,
                _ => 63,
            };
        }
    }
    count > 0
        && count % 4 == 0
        && (padding == 0
            || (padding == 1 && last_value & 3 == 0)
            || (padding == 2 && last_value & 15 == 0))
}

pub fn validate(text: &str, limits: &Limits) -> Result<()> {
    // 2026-10-16：总字节上限先于扫描生效；畸形标记和代码示例仍按正文计数。
    let total_limit = usize::try_from(limits.max_archive_bytes).unwrap_or(usize::MAX);
    let image_encoded_limit = (limits.max_file_bytes.saturating_add(2) / 3).saturating_mul(4);
    let aggregate_encoded_limit = (total_limit.saturating_add(2) / 3).saturating_mul(4);
    if text.len() > aggregate_encoded_limit.saturating_add(limits.max_text_chars.saturating_mul(4))
    {
        return Err(Error::new("upload_limit", "插图总数据超过限制"));
    }
    let spans = image_payloads(text);
    let mut chars = 0;
    let mut previous = 0;
    let mut total = 0usize;
    for span in spans {
        chars += text[previous..span.start].chars().count();
        let data = &text[span.clone()];
        let payload = data.split_once(";base64,").unwrap().1;
        let encoded_bytes = payload.bytes().filter(|b| !b.is_ascii_whitespace()).count();
        let decoded_bytes = encoded_bytes / 4 * 3 - payload.bytes().filter(|b| *b == b'=').count();
        if payload.len() > image_encoded_limit || decoded_bytes > limits.max_file_bytes {
            return Err(Error::new("upload_limit", "单张插图超过限制"));
        }
        total = total.saturating_add(decoded_bytes);
        if total > total_limit {
            return Err(Error::new("upload_limit", "插图总数据超过限制"));
        }
        // 标记、替代文本和 MIME 描述仍占用正文额度，仅二进制负载豁免。
        chars += data.len() - payload.len();
        previous = span.end;
    }
    chars += text[previous..].chars().count();
    if chars > limits.max_text_chars {
        return Err(Error::new("text_limit", "文本过长"));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn body_and_image_limits_are_independent_and_literals_cannot_bypass_them() {
        let limits = Limits {
            max_text_chars: 100,
            max_file_bytes: 6,
            max_archive_bytes: 8,
            ..Limits::default()
        };
        let image = "![图](data:image/png;base64,AAAA)";
        validate(&image.repeat(2), &limits).unwrap();
        assert_eq!(
            validate(&image.repeat(3), &limits).unwrap_err().code,
            "upload_limit"
        );
        assert_eq!(
            validate("![图](data:image/png;base64,AAAAAAAAAAAA)", &limits)
                .unwrap_err()
                .code,
            "upload_limit"
        );
        assert_eq!(
            validate(&"字".repeat(101), &limits).unwrap_err().code,
            "text_limit"
        );
        let body_limit = Limits {
            max_text_chars: 50,
            ..Limits::default()
        };
        let large = format!("![图](data:image/png;base64,{})", "AAAA".repeat(100));
        validate(&large, &body_limit).unwrap();
        for literal in [
            format!("`{large}`"),
            format!("```\n{large}\n```"),
            format!("https://example.com/{large}"),
            large.trim_end_matches(')').to_owned(),
            large.replace("AAAA", "!AAA"),
            large.replace("base64,", "base64,\n"),
        ] {
            assert_eq!(
                validate(&literal, &body_limit).unwrap_err().code,
                "text_limit",
                "{literal}"
            );
        }
        assert!(!valid_image_data("data:image/png;base64,AB=="));
        assert!(!valid_image_data("data:image/png;base64,AAA=AA=="));
        assert!(!valid_image_data("data:image/png;base64,"));
    }
}
