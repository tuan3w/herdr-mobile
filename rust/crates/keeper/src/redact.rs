//! What an alert hook is told about a request: its first line, with secrets
//! masked, cut short. Ported from the python `redact_line`
//! (`keeper_script.dart` 454-477) rule for rule; the python used regular
//! expressions, this has none (a regex engine would be the largest thing in
//! the binary), so each rule is a small matcher that mimics its pattern's
//! greedy, backtracking behaviour on the bounded counts the patterns have.
//! Every matcher is linear in the line (at most 300 characters here).

/// The line a hook may see: at most 120 characters, no line breaks, secrets
/// masked (a URL's user and password, `Bearer`/`Basic` tokens, `key=value`
/// pairs whose key names a secret, well-known token shapes, and any long
/// mixed letter-and-digit word).
#[must_use]
pub fn redact_line(text: &str) -> String {
    let mut line = String::new();
    let head: String = text.chars().take(2000).collect();
    for part in split_lines(&head) {
        let part = part.trim();
        if !part.is_empty() {
            line = part.chars().take(300).collect();
            break;
        }
    }
    let mut chars: Vec<char> = line.chars().collect();
    for rule in [userinfo, bearer, secret_kv, known_token, long_word] {
        chars = sub(&chars, rule);
    }
    let collapsed = collapse_whitespace(&chars);
    truncate(&collapsed, 120)
}

/// Python's `str.splitlines` without keeping the ends.
fn split_lines(text: &str) -> impl Iterator<Item = &str> {
    text.split(|c: char| {
        matches!(
            c,
            '\n' | '\r'
                | '\u{b}'
                | '\u{c}'
                | '\u{1c}'
                | '\u{1d}'
                | '\u{1e}'
                | '\u{85}'
                | '\u{2028}'
                | '\u{2029}'
        )
    })
}

fn truncate(text: &str, n: usize) -> String {
    if text.chars().count() <= n {
        return text.to_string();
    }
    let mut out: String = text.chars().take(n - 1).collect();
    out.push('\u{2026}');
    out
}

fn collapse_whitespace(chars: &[char]) -> String {
    let mut out = String::with_capacity(chars.len());
    let mut in_space = false;
    for &c in chars {
        if c.is_whitespace() {
            if !in_space {
                out.push(' ');
            }
            in_space = true;
        } else {
            out.push(c);
            in_space = false;
        }
    }
    out
}

/// A rule: at `i`, the end of its match and what replaces it, or `None`.
type Rule = fn(&[char], usize) -> Option<(usize, String)>;

/// `re.sub`: leftmost matches, none overlapping.
fn sub(chars: &[char], rule: Rule) -> Vec<char> {
    let mut out = Vec::with_capacity(chars.len());
    let mut i = 0;
    while i < chars.len() {
        match rule(chars, i) {
            Some((end, replacement)) if end > i => {
                out.extend(replacement.chars());
                i = end;
            }
            _ => {
                out.push(chars[i]);
                i += 1;
            }
        }
    }
    out
}

// -- character classes --------------------------------------------------------

fn is_word(c: char) -> bool {
    c.is_alphanumeric() || c == '_'
}

/// `\b`: a word character on exactly one side of `i`.
fn boundary(s: &[char], i: usize) -> bool {
    let before = i > 0 && is_word(s[i - 1]);
    let after = i < s.len() && is_word(s[i]);
    before != after
}

/// Characters from `i` on for which `class` holds, at most `cap`.
fn run(s: &[char], i: usize, cap: usize, class: impl Fn(char) -> bool) -> usize {
    s[i.min(s.len())..]
        .iter()
        .take(cap)
        .take_while(|c| class(**c))
        .count()
}

fn starts_with_ignore_case(s: &[char], i: usize, word: &str) -> bool {
    let n = word.chars().count();
    i + n <= s.len()
        && s[i..i + n]
            .iter()
            .zip(word.chars())
            .all(|(a, b)| a.eq_ignore_ascii_case(&b))
}

fn text(s: &[char], from: usize, to: usize) -> String {
    s[from..to].iter().collect()
}

// -- the rules ---------------------------------------------------------------

/// `(\b[a-z][a-z0-9+.-]{0,20}://)[^/\s:@]{1,100}:[^/\s@]+@` → `\1***@`
fn userinfo(s: &[char], p: usize) -> Option<(usize, String)> {
    if !s[p].is_ascii_alphabetic() || !boundary(s, p) {
        return None;
    }
    let scheme = run(s, p + 1, 20, |c| {
        c.is_ascii_alphanumeric() || matches!(c, '+' | '.' | '-')
    });
    let colon = p + 1 + scheme;
    if !starts_with_ignore_case(s, colon, "://") {
        return None;
    }
    let user_at = colon + 3;
    let user = run(s, user_at, 100, |c| {
        !(matches!(c, '/' | ':' | '@') || c.is_whitespace())
    });
    let sep = user_at + user;
    if user == 0 || s.get(sep) != Some(&':') {
        return None;
    }
    let pass_at = sep + 1;
    let pass = run(s, pass_at, usize::MAX, |c| {
        !(matches!(c, '/' | '@') || c.is_whitespace())
    });
    let at = pass_at + pass;
    if pass == 0 || s.get(at) != Some(&'@') {
        return None;
    }
    Some((at + 1, format!("{}***@", text(s, p, colon + 3))))
}

/// `\b(bearer|basic)\s{1,3}[A-Za-z0-9._~+/=-]{6,}` → `\1 ***`
fn bearer(s: &[char], p: usize) -> Option<(usize, String)> {
    if !boundary(s, p) {
        return None;
    }
    let word = ["bearer", "basic"]
        .into_iter()
        .find(|w| starts_with_ignore_case(s, p, w))?;
    let after = p + word.len();
    let spaces = run(s, after, 3, char::is_whitespace);
    if spaces == 0 {
        return None;
    }
    // The spaces are taken whole: a shorter count leaves a space where the
    // token must begin.
    let token_at = after + spaces;
    let token = run(s, token_at, usize::MAX, |c| {
        c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '~' | '+' | '/' | '=' | '-')
    });
    if token < 6 {
        return None;
    }
    Some((token_at + token, format!("{} ***", text(s, p, after))))
}

fn is_kv_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | '-')
}

/// The ends a secret-naming word can have at `i`, in the pattern's order:
/// `token|secret|passw(?:or)?d|api[_-]?key|auth|credential|private[_-]?key`
/// (case-insensitive; an optional part is tried present first).
fn secret_words(s: &[char], i: usize) -> Vec<usize> {
    let mut ends = Vec::new();
    if starts_with_ignore_case(s, i, "token") {
        ends.push(i + 5);
    }
    if starts_with_ignore_case(s, i, "secret") {
        ends.push(i + 6);
    }
    if starts_with_ignore_case(s, i, "passw") {
        if starts_with_ignore_case(s, i + 5, "or") && starts_with_ignore_case(s, i + 7, "d") {
            ends.push(i + 8);
        }
        if starts_with_ignore_case(s, i + 5, "d") {
            ends.push(i + 6);
        }
    }
    // `api[_-]?key`, then `auth` and `credential`, then `private[_-]?key`.
    let keyed = |ends: &mut Vec<usize>, word: &str| {
        let len = word.len();
        if !starts_with_ignore_case(s, i, word) {
            return;
        }
        if s.get(i + len).is_some_and(|c| matches!(c, '_' | '-'))
            && starts_with_ignore_case(s, i + len + 1, "key")
        {
            ends.push(i + len + 4);
        }
        if starts_with_ignore_case(s, i + len, "key") {
            ends.push(i + len + 3);
        }
    };
    keyed(&mut ends, "api");
    if starts_with_ignore_case(s, i, "auth") {
        ends.push(i + 4);
    }
    if starts_with_ignore_case(s, i, "credential") {
        ends.push(i + 10);
    }
    keyed(&mut ends, "private");
    ends
}

/// `"[^"]*"|'[^']*'|\S+` at `i`: the end of the value.
fn value_end(s: &[char], i: usize) -> Option<usize> {
    let first = *s.get(i)?;
    if first == '"' || first == '\'' {
        if let Some(close) = s[i + 1..].iter().position(|c| *c == first) {
            return Some(i + 1 + close + 1);
        }
    }
    let n = run(s, i, usize::MAX, |c| !c.is_whitespace());
    (n > 0).then_some(i + n)
}

/// `(\s{0,3}[=:]\s{0,3}|\s{1,3})` then the value, from `r`: where the value
/// starts and ends.
fn separator_and_value(s: &[char], r: usize) -> Option<(usize, usize)> {
    let before = run(s, r, 3, char::is_whitespace);
    for a in (0..=before).rev() {
        let at = r + a;
        if s.get(at).is_some_and(|c| matches!(c, '=' | ':')) {
            let after = run(s, at + 1, 3, char::is_whitespace);
            for b in (0..=after).rev() {
                let start = at + 1 + b;
                if let Some(end) = value_end(s, start) {
                    return Some((start, end));
                }
            }
        }
    }
    for a in (1..=before).rev() {
        let start = r + a;
        if let Some(end) = value_end(s, start) {
            return Some((start, end));
        }
    }
    None
}

/// `\b([A-Za-z0-9_.-]{0,40}(?:token|secret|…)[A-Za-z0-9_.-]{0,40})(sep)(value)`
/// → `\1\2***`
fn secret_kv(s: &[char], p: usize) -> Option<(usize, String)> {
    if !boundary(s, p) {
        return None;
    }
    let prefix = run(s, p, 40, is_kv_char);
    for k in (0..=prefix).rev() {
        for word_end in secret_words(s, p + k) {
            let suffix = run(s, word_end, 40, is_kv_char);
            for l in (0..=suffix).rev() {
                if let Some((start, end)) = separator_and_value(s, word_end + l) {
                    return Some((end, format!("{}***", text(s, p, start))));
                }
            }
        }
    }
    None
}

/// `\b(?:sk-[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9]{16,}|xox[abprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16})`
/// → `***` (case-sensitive)
fn known_token(s: &[char], p: usize) -> Option<(usize, String)> {
    if !boundary(s, p) {
        return None;
    }
    let at = |i: usize| s.get(i).copied();
    let masked = |end: usize| Some((end, "***".to_string()));
    if at(p) == Some('s') && at(p + 1) == Some('k') && at(p + 2) == Some('-') {
        let n = run(s, p + 3, usize::MAX, |c| {
            c.is_ascii_alphanumeric() || matches!(c, '_' | '-')
        });
        if n >= 12 {
            return masked(p + 3 + n);
        }
    }
    if at(p) == Some('g')
        && at(p + 1) == Some('h')
        && at(p + 2).is_some_and(|c| matches!(c, 'p' | 'o' | 'u' | 's' | 'r'))
        && at(p + 3) == Some('_')
    {
        let n = run(s, p + 4, usize::MAX, |c| c.is_ascii_alphanumeric());
        if n >= 16 {
            return masked(p + 4 + n);
        }
    }
    if at(p) == Some('x')
        && at(p + 1) == Some('o')
        && at(p + 2) == Some('x')
        && at(p + 3).is_some_and(|c| matches!(c, 'a' | 'b' | 'p' | 'r' | 's'))
        && at(p + 4) == Some('-')
    {
        let n = run(s, p + 5, usize::MAX, |c| {
            c.is_ascii_alphanumeric() || c == '-'
        });
        if n >= 10 {
            return masked(p + 5 + n);
        }
    }
    if s[p..].starts_with(&['A', 'K', 'I', 'A']) {
        let n = run(s, p + 4, 16, |c| {
            c.is_ascii_digit() || c.is_ascii_uppercase()
        });
        if n == 16 {
            return masked(p + 20);
        }
    }
    None
}

/// `\b(?=[A-Za-z0-9_-]{0,300}\d)(?=[A-Za-z0-9_-]{0,300}[A-Za-z])[A-Za-z0-9_-]{28,}\b`
/// → `***`: a long word that has both a digit and a letter.
fn long_word(s: &[char], p: usize) -> Option<(usize, String)> {
    let class = |c: char| c.is_ascii_alphanumeric() || matches!(c, '_' | '-');
    if !boundary(s, p) {
        return None;
    }
    let len = run(s, p, usize::MAX, class);
    if len < 28 {
        return None;
    }
    // The lookaheads see at most 300 characters before the digit or letter.
    let window = &s[p..p + len.min(301)];
    if !window.iter().any(char::is_ascii_digit) || !window.iter().any(char::is_ascii_alphabetic) {
        return None;
    }
    // Greedy, then back off to the nearest `\b`.
    (28..=len)
        .rev()
        .find(|n| boundary(s, p + n))
        .map(|n| (p + n, "***".to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};

    #[test]
    fn secrets_in_a_command_are_masked_whole() {
        let line = redact_line(
            "curl -H \"Authorization: Bearer abcdef1234567890\" https://u:pw@x.io?token=zzz1234 sk-abcdefghijklmnop12",
        );
        assert!(line.starts_with("curl -H"), "{line}");
        for secret in [
            "abcdef1234567890",
            "pw@",
            "zzz1234",
            "sk-abcdefghijklmnop12",
        ] {
            assert!(!line.contains(secret), "{secret} in {line}");
        }
        assert!(line.chars().count() <= 120, "{line}");
    }

    #[test]
    fn each_rule_masks_what_the_python_pattern_masked() {
        assert_eq!(
            redact_line("git clone https://bob:hunter2@host/r.git"),
            "git clone https://***@host/r.git"
        );
        assert_eq!(
            redact_line("Authorization: Bearer abcdef123"),
            "Authorization: *** ***"
        );
        assert_eq!(
            redact_line("curl -u BASIC dXNlcjpwYXNz"),
            "curl -u BASIC ***"
        );
        assert_eq!(redact_line("api_key=abc"), "api_key=***");
        assert_eq!(
            redact_line("PASSWORD: \"two words\" next"),
            "PASSWORD: *** next"
        );
        assert_eq!(redact_line("my-secret   'x y' z"), "my-secret *** z");
        assert_eq!(
            redact_line("export GITHUB_TOKEN ghp_0123456789abcdefABCD"),
            "export GITHUB_TOKEN ***"
        );
        assert_eq!(redact_line("ghp_0123456789abcdefABCD alone"), "*** alone");
        assert_eq!(
            redact_line("AKIAABCDEFGHIJKLMNOP and xoxb-1234567890-abc"),
            "*** and ***"
        );
        assert_eq!(
            redact_line("id 0123456789abcdefghij0123456789ab done"),
            "id *** done"
        );
        // No digit: a long word that is only letters is a word.
        let words = "abcdefghijklmnopqrstuvwxyzabcdefgh";
        assert_eq!(redact_line(words), words);
        assert_eq!(redact_line("Run: ls -la"), "Run: ls -la");
        assert_eq!(redact_line("Pick one?"), "Pick one?");
    }

    #[test]
    fn the_first_non_empty_line_is_what_is_kept() {
        assert_eq!(
            redact_line("\n \r\n  hello   world \nsecond"),
            "hello world"
        );
        assert_eq!(redact_line(""), "");
        assert_eq!(redact_line("   \n \n"), "");
        let long = "x ".repeat(200);
        let cut = redact_line(&long);
        assert_eq!(cut.chars().count(), 120);
        assert!(cut.ends_with('\u{2026}'));
    }

    #[test]
    fn hostile_lines_are_instant_and_the_secret_is_masked_whole() {
        let cases = [
            "a.".repeat(50_000),
            "token".repeat(20_000),
            format!("Authorization: Bearer {}", "b".repeat(100_000)),
            format!("api_key={}", "k".repeat(100_000)),
            format!("http://u:{}@x", "p".repeat(100_000)),
            "A1".repeat(14) + &(" ".to_string() + &"A1".repeat(14)).repeat(5000),
            format!("{}late line", "\n".repeat(50_000)),
        ];
        for case in &cases {
            let t0 = Instant::now();
            let r = redact_line(case);
            assert!(t0.elapsed() < Duration::from_millis(1500), "{r}");
            assert!(r.chars().count() <= 120, "{r}");
        }
        assert_eq!(redact_line(&cases[2]), "Authorization: *** ***");
        assert_eq!(redact_line(&cases[3]), "api_key=***");
        // The line is looked for in the first 2000 characters only.
        assert_eq!(redact_line(&cases[6]), "");
    }
}
