//! `json.dumps` of python's standard library, for the fixtures that must put the
//! same bytes on a pipe as the python programs they replace: `ensure_ascii`
//! (every non-ASCII character is a `\uXXXX` escape, astral ones as surrogate
//! pairs), optionally `sort_keys`, and either the default separators (`", "`
//! and `": "`) or the compact ones (`","` and `":"`).

use serde_json::Value;
use std::fmt::Write;

/// Which of python's `json.dumps` spellings to produce.
#[derive(Clone, Copy)]
pub struct Style {
    /// `separators=(",", ":")` instead of the default `(", ", ": ")`.
    pub compact: bool,
    pub sort_keys: bool,
}

/// `json.dumps(value)`.
pub const DEFAULT: Style = Style {
    compact: false,
    sort_keys: false,
};
/// `json.dumps(value, separators=(",", ":"))`.
pub const COMPACT: Style = Style {
    compact: true,
    sort_keys: false,
};
/// `json.dumps(value, sort_keys=True)`.
pub const SORTED: Style = Style {
    compact: false,
    sort_keys: true,
};

pub fn dumps(value: &Value, style: Style) -> String {
    let mut out = String::new();
    write_value(&mut out, value, style);
    out
}

fn write_value(out: &mut String, value: &Value, style: Style) {
    match value {
        Value::Null => out.push_str("null"),
        Value::Bool(true) => out.push_str("true"),
        Value::Bool(false) => out.push_str("false"),
        Value::Number(n) => {
            let _ = write!(out, "{n}");
        }
        Value::String(s) => write_string(out, s),
        Value::Array(items) => {
            out.push('[');
            for (i, item) in items.iter().enumerate() {
                if i > 0 {
                    out.push_str(if style.compact { "," } else { ", " });
                }
                write_value(out, item, style);
            }
            out.push(']');
        }
        Value::Object(map) => {
            out.push('{');
            let mut entries: Vec<(&String, &Value)> = map.iter().collect();
            if style.sort_keys {
                entries.sort_by(|a, b| a.0.cmp(b.0));
            }
            for (i, (key, item)) in entries.into_iter().enumerate() {
                if i > 0 {
                    out.push_str(if style.compact { "," } else { ", " });
                }
                write_string(out, key);
                out.push_str(if style.compact { ":" } else { ": " });
                write_value(out, item, style);
            }
            out.push('}');
        }
    }
}

fn write_string(out: &mut String, s: &str) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{8}' => out.push_str("\\b"),
            '\u{c}' => out.push_str("\\f"),
            c if (c as u32) < 0x20 => {
                let _ = write!(out, "\\u{:04x}", c as u32);
            }
            c if c.is_ascii() => out.push(c),
            c => {
                let mut units = [0u16; 2];
                for unit in c.encode_utf16(&mut units) {
                    let _ = write!(out, "\\u{unit:04x}");
                }
            }
        }
    }
    out.push('"');
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn matches_python_spelling() {
        let v = json!({"b": [1, 2.5, null, true], "a": "é→\u{1F600}\n\u{1}\"\\"});
        assert_eq!(
            dumps(&v, DEFAULT),
            r#"{"b": [1, 2.5, null, true], "a": "\u00e9\u2192\ud83d\ude00\n\u0001\"\\"}"#
        );
        assert_eq!(
            dumps(&v, COMPACT),
            r#"{"b":[1,2.5,null,true],"a":"\u00e9\u2192\ud83d\ude00\n\u0001\"\\"}"#
        );
        assert_eq!(
            dumps(&v, SORTED),
            r#"{"a": "\u00e9\u2192\ud83d\ude00\n\u0001\"\\", "b": [1, 2.5, null, true]}"#
        );
        assert_eq!(dumps(&json!({}), DEFAULT), "{}");
        assert_eq!(dumps(&json!([]), DEFAULT), "[]");
    }
}
