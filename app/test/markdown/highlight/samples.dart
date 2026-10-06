/// ~15-line realistic samples per language, shared by the golden, invariant
/// and perf tests.
const Map<String, String> samples = {
  'dart': r'''
import 'package:flutter/widgets.dart';

/// A counter that never goes below [min].
class Counter extends ChangeNotifier {
  Counter({this.min = 0}) : _value = min;

  final int min;
  int _value;
  static const double kScale = 1.5e3;

  int get value => _value;

  void decrement({bool force = false}) {
    if (_value > min || force) _value--; // never negative
    final label = r'raw\n' + 'it\'s $_value' + """multi
line""";
    notifyListeners();
  }
}
''',
  'js': r'''
// load the config
import { readFile } from 'node:fs/promises';

const PORT = 0x1F90;
async function main(args) {
  const text = await readFile(args[0], "utf8");
  const re = /^(\d+)\s*=\s*"([^"]*)"$/gm;
  /* block
     comment */
  for (const line of text.split('\n')) {
    if (re.test(line) && line.length > 3.5) console.log(`got ${line}`);
  }
  return null;
}
main(process.argv.slice(2)).catch(() => process.exit(1));
''',
  'ts': r'''
export interface Options {
  readonly name: string;
  retries?: number;
}

type Handler = (opts: Options) => Promise<void>;

@Injectable()
export class Runner<T extends Options> {
  private count: number = 0;
  constructor(private readonly handler: Handler) {}

  async run(opts: T): Promise<boolean> {
    // retry loop
    for (let i = 0; i < (opts.retries ?? 3); i++) {
      await this.handler(opts);
    }
    return true;
  }
}
''',
  'python': r'''
#!/usr/bin/env python3
"""Tiny CLI.

Second docstring line.
"""
import argparse
from pathlib import Path

@dataclass
class Job:
    name: str
    retries: int = 3

def main(argv: list[str] | None = None) -> int:
    path = Path(argv[0]) if argv else None  # optional
    text = f"hello {path!r}" + r'\d+' + b'raw'
    if path is not None and 0x10 < 1_000.5e-3:
        print(text, len(text), True)
    return 0
''',
  'shell': r'''
#!/usr/bin/env bash
set -euo pipefail
# build the thing
NAME="herdr" VERSION=1.2
export PATH="$HOME/bin:$PATH"
for f in src/*.sh; do
  if [[ -f "$f" && ${#f} -gt 3 ]]; then
    echo 'processing' "$f" | tee -a build.log >&2
  fi
done
cat <<-EOF > out.txt
  hello $NAME
EOF
grep -rn --include=*.dart "TODO" lib/ || true
curl -fsSL https://example.com/x.sh \
  | sh -s -- -y
''',
  'console': r'''
$ cd herdr-mobile
$ flutter test --no-pub test/markdown/ # run
00:03 +42: All tests passed!
# a comment
$ echo "done" > log.txt
''',
  'json': r'''
{
  "name": "herdr-mobile",
  "version": "1.2.0",
  "private": true,
  "ratio": -0.5e-2,
  "count": 42,
  "note": "line\n\"quoted\" \u00e9",
  "tags": ["a", "b"],
  "nested": { "ok": false, "none": null }
}
''',
  'jsonc': r'''
{
  // trailing comment
  "a": 1, /* inline */ "b": [true, null]
}
''',
  'yaml': r'''
# CI config
name: build
on:
  push:
    branches: [main, "release/*"]
env:
  NODE_VERSION: 20
  DEBUG: true
  EMPTY: ~
jobs:
  test:
    steps:
      - uses: actions/checkout@v4
      - name: Run
        run: |
          npm ci
          npm test
      - run: echo "done" # trailing
anchors: &base
  key: 'single'
ref: *base
''',
  'toml': r'''
# project
[package]
name = "herdr"
version = "0.3.1"
edition = 2021
authors = ["A <a@b.c>", 'lit']
published = false

[dependencies.serde]
version = "1.0"
features = [
  "derive",
  "rc",
]
released = 1979-05-27T07:32:00Z
text = """
multi
line"""
[[bin]]
path = "src/main.rs"
''',
  'sql': r'''
-- active users
SELECT u.id, u.name, COUNT(o.id) AS orders
FROM users u
LEFT JOIN orders o ON o.user_id = u.id
WHERE u.created_at > '2024-01-01' AND u.name <> 'O''Brien'
GROUP BY u.id, u.name
HAVING COUNT(o.id) >= 10 /* big */
ORDER BY orders DESC
LIMIT 25;

CREATE TABLE IF NOT EXISTS "events" (
  id BIGSERIAL PRIMARY KEY,
  payload JSONB NOT NULL DEFAULT '{}',
  at TIMESTAMPTZ DEFAULT now()
);
''',
  'rust': r'''
use std::collections::HashMap;

/// A tiny cache.
#[derive(Debug, Clone)]
pub struct Cache<'a, K> {
    items: HashMap<K, &'a str>,
    hits: u64,
}

impl<'a, K: std::hash::Hash + Eq> Cache<'a, K> {
    pub fn get(&mut self, key: &K) -> Option<&'a str> {
        /* count */
        self.hits += 1u64;
        let raw = r#"say "hi""#;
        let c = 'x';
        println!("{} {}", raw, 0xFF_u8);
        self.items.get(key).copied()
    }
}
''',
  'go': r'''
package main

import (
	"fmt"
	"os"
)

// Server holds state.
type Server struct {
	Addr string
	Port int
}

func (s *Server) Start() error {
	msg := `raw
string`
	if s.Port == 0 {
		return fmt.Errorf("bad port %d: %w", s.Port, os.ErrInvalid)
	}
	var r rune = 'a'
	fmt.Println(msg, r, 3.14, nil)
	return nil
}
''',
  'c': r'''
#include <stdio.h>
#include "util.h"

#define MAX_LEN 256

/* sum an array */
static int sum(const int *xs, size_t n) {
    int total = 0;
    for (size_t i = 0; i < n; i++) {
        total += xs[i]; // add
    }
    return total;
}

int main(void) {
    char c = '\n';
    printf("total=%d\n", sum(NULL, 0u));
    return 0;
}
''',
  'cpp': r'''
#include <vector>
#include <string>

namespace app {

template <typename T>
class Box {
public:
  explicit Box(T v) : value_(std::move(v)) {}
  const T& get() const noexcept { return value_; }
private:
  T value_;
};

}  // namespace app

int main() {
  std::vector<std::string> names{"a", "b"};
  auto n = nullptr;
  return names.size() > 0x2 ? 1 : 0;
}
''',
  'java': r'''
package com.example;

import java.util.List;

@SuppressWarnings("unchecked")
public final class Main {
    private static final int LIMIT = 10;

    /** Entry point. */
    public static void main(String[] args) {
        List<String> names = List.of("a", "b");
        char c = '\t';
        String text = """
            hello
            """;
        for (String s : names) System.out.println(s + 1.5f);
    }
}
''',
  'kotlin': r'''
package app

import kotlin.math.max

@Serializable
data class User(val name: String, val age: Int = 0)

fun main(args: Array<String>) {
    val users = listOf(User("a", 1), User("b", 2))
    /* nested /* comment */ still */
    val oldest = users.maxOfOrNull { it.age } ?: 0
    val raw = """
        raw text
    """
    println("max: ${max(oldest, 3)} ${raw.length}")
}
''',
  'swift': r'''
import SwiftUI

@main
struct DemoApp: App {
    @State private var count: Int = 0

    var body: some Scene {
        WindowGroup {
            Text("Count: \(count)") // label
        }
    }

    func bump(by step: Int = 1) -> Bool {
        guard step > 0 else { return false }
        count += step
        #if DEBUG
        print("bumped", 0x10)
        #endif
        return true
    }
}
''',
  'html': r'''
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <!-- page title -->
  <title>Hello &amp; welcome</title>
</head>
<body class='main' data-x=5>
  <a href="https://example.com/?a=1&b=2" target=_blank>link</a>
  <input type="text" disabled />
</body>
</html>
''',
  'xml': r'''
<?xml version="1.0" encoding="UTF-8"?>
<config xmlns:x="urn:x">
  <entry key="a">1</entry>
  <!-- multi
       line -->
  <empty/>
</config>
''',
  'css': r'''
@import url(theme.css);
:root { --accent: #1a73e8; }
/* layout */
.card > .title:hover, #main a[href^="http"] {
  margin: 0 auto;
  padding: 1.5em 12px;
  color: var(--accent);
  background: url("img/bg.png") no-repeat !important;
  transition: all 0.3s ease-in-out;
}
@media (min-width: 600px) {
  .card { width: calc(100% - 2rem); }
}
''',
  'scss': r'''
$gap: 8px;
// mixin
@mixin flex($dir: row) {
  display: flex;
  flex-direction: $dir;
}
.nav {
  @include flex(column);
  &:hover { color: darken(#336, 10%); }
  .item-#{$i} { margin: $gap * 2; }
}
''',
  'diff': r'''
diff --git a/lib/main.dart b/lib/main.dart
index 83db48f..bf2a3c1 100644
--- a/lib/main.dart
+++ b/lib/main.dart
@@ -10,7 +10,7 @@ void main() {
   runApp(const App());
-  print('old');
+  print('new');
 }
\ No newline at end of file
''',
  'markdown': r'''
# Title

Some *emphasis*, **strong**, `code span` and snake_case_name.
See [the docs](https://example.com/a_b) or https://example.org/x.

> quoted text
- [x] done item
1. numbered with `ticks`

---
```dart
var x = 1; # not a heading in a fence
```
''',
  'dockerfile': r'''
# syntax=docker/dockerfile:1
FROM node:20-alpine AS build
WORKDIR /app
ENV NODE_ENV=production PORT=8080
COPY --from=deps /app/node_modules ./node_modules
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*
EXPOSE 8080
CMD ["node", "server.js"]
ENTRYPOINT echo "$PORT" | sh
''',
  'make': r'''
# build
CC := gcc
CFLAGS ?= -O2 -Wall
SRC = main.c \
      util.c

.PHONY: all clean

all: app

app: $(SRC:.c=.o)
	@echo "linking $@"
	$(CC) $(CFLAGS) -o $@ $^

clean:
	-rm -f app *.o
ifeq ($(OS),Windows_NT)
endif
''',
};
