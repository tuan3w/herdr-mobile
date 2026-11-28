//! Reads lines from a byte stream without trusting them: a byte that is not
//! UTF-8 is replaced, not fatal; a line longer than the cap is skipped
//! without being held in memory; an empty line is nothing. The viewer's
//! `BufRead::lines` ended the whole session at the first bad byte; the
//! daemon needs the same leniency on the agent's pipes and the clients'
//! sockets.

use std::io::{self, BufRead, Read};

/// One line of a stream, read leniently with a hard cap.
pub struct Lines<R: Read> {
    reader: io::BufReader<R>,
    cap: usize,
}

impl<R: Read> Lines<R> {
    #[must_use]
    pub fn new(reader: R, cap: usize) -> Self {
        Lines {
            reader: io::BufReader::with_capacity(64 * 1024, reader),
            cap,
        }
    }
}

impl<R: Read> Iterator for Lines<R> {
    type Item = io::Result<String>;

    fn next(&mut self) -> Option<Self::Item> {
        let mut line: Vec<u8> = Vec::new();
        let mut oversize = false;
        loop {
            let chunk = match self.reader.fill_buf() {
                Ok(c) => c,
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                Err(e) => return Some(Err(e)),
            };
            if chunk.is_empty() {
                return if oversize || line.is_empty() {
                    None
                } else {
                    Some(Ok(finish(&line)))
                };
            }
            let (take, found) = match chunk.iter().position(|b| *b == b'\n') {
                Some(i) => (i + 1, true),
                None => (chunk.len(), false),
            };
            if !oversize {
                if line.len() + take > self.cap {
                    // Too long to hold: forget what was read and skip to its end.
                    oversize = true;
                    line.clear();
                } else {
                    line.extend_from_slice(&chunk[..take]);
                }
            }
            self.reader.consume(take);
            if found {
                if oversize || line.iter().all(u8::is_ascii_whitespace) {
                    oversize = false;
                    line.clear();
                    continue;
                }
                return Some(Ok(finish(&line)));
            }
        }
    }
}

fn finish(bytes: &[u8]) -> String {
    let mut s = String::from_utf8_lossy(bytes).into_owned();
    if s.ends_with('\n') {
        s.pop();
        if s.ends_with('\r') {
            s.pop();
        }
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_and_drops_blank() {
        let lines: Vec<String> = Lines::new(b"a\n\nb\r\n".as_slice(), 100)
            .map_while(Result::ok)
            .collect();
        assert_eq!(lines, vec!["a", "b"]);
    }

    #[test]
    fn caps_long_lines() {
        // A 50-byte line over a 10-byte cap is skipped; the next survives.
        let mut buf = vec![b'x'; 50];
        buf.push(b'\n');
        buf.extend_from_slice(b"ok\n");
        let lines: Vec<String> = Lines::new(buf.as_slice(), 10)
            .map_while(Result::ok)
            .collect();
        assert_eq!(lines, vec!["ok"]);
    }

    #[test]
    fn a_trailing_line_without_newline_is_returned() {
        let lines: Vec<String> = Lines::new(b"tail".as_slice(), 100)
            .map_while(Result::ok)
            .collect();
        assert_eq!(lines, vec!["tail"]);
    }

    #[test]
    fn non_utf8_is_replaced_not_fatal() {
        let mut buf = b"h\xFFi\n".to_vec();
        buf.extend_from_slice(b"next\n");
        let lines: Vec<String> = Lines::new(buf.as_slice(), 100)
            .map_while(Result::ok)
            .collect();
        assert_eq!(lines.len(), 2);
        assert_eq!(lines[1], "next");
    }
}
