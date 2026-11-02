#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Lexer-level Swift check: balanced delimiters, terminated literals.

Why this exists: there is no Swift toolchain on the development machine, so every
syntax mistake costs a full macOS CI round (5x billed minutes) to discover, and a
syntax error also aborts compilation, hiding every later file's type errors. Two
shapes of mistake burned real rounds here:

  * an array literal whose brackets were ordered wrong  (`["...")]`)
  * a double quote pasted inside a string literal, which truncates the literal and
    makes the compiler complain hundreds of lines away from the cause

Both are decidable without a parser or SDK. Naive brace counting cannot see them,
because Swift has nestable block comments, string interpolation (code again, inside
a string), multi-line strings, and raw strings whose terminator repeats the opener.
So this is a small frame-stack scanner: every opened construct pushes a frame.

v1 tracked interpolation without a delimiter frame and mis-paired the closing
paren, producing 66 false positives on files that CI compiles clean -- which is
the reason `--self-test` is mandatory here: a checker that reports nothing is not
a checker that works. `--self-test` asserts it catches each of the known shapes
AND stays silent on the tricky-but-valid ones.

Not caught (still needs a compiler): type errors, protocol conformance, wrong
argument labels, API signature drift, optional handling.

Usage:
    python scripts/swift_lex_check.py              # whole repo
    python scripts/swift_lex_check.py a.swift ...  # specific files
    python scripts/swift_lex_check.py --self-test  # verify the checker itself
Exit code = number of findings.
"""
import io
import os
import sys

# Frame kinds
CODE = 'code'
STRING = 'string'        # "..."      (interp allowed)
MULTI = 'multi'          # """..."""  (interp allowed)
RAW = 'raw'              # #"..."# / ##"..."##  (interp allowed with \#( )
LINE = 'line'            # // ...
BLOCK = 'block'          # /* ... */ nestable

OPEN = {'{': '}', '(': ')', '[': ']'}
CLOSE = {'}': '{', ')': '(', ']': '['}


class Frame(object):
    __slots__ = ('kind', 'line', 'stack', 'quote', 'hashes', 'depth', 'is_interp', 'start')

    def __init__(self, kind, line, quote='', hashes=0, is_interp=False, start=0):
        self.kind = kind
        self.line = line
        self.quote = quote        # '"' or '"""'
        self.hashes = hashes      # raw string hash count
        self.depth = 1            # block comment nesting
        self.is_interp = is_interp
        self.start = start        # offset where the literal content begins
        self.stack = []           # delimiters, CODE frames only


def scan(name, src):
    return _scan(name, src)[0]


def string_literals(name, src):
    """Contents of every string literal, so callers can grep text without hitting
    comments or code (a `[no_xxx]` in a comment is not an emitted token)."""
    return _scan(name, src)[1]


def _scan(name, src):
    """Return (findings, literals) for one Swift source string."""
    out = []
    literals = []
    frames = [Frame(CODE, 1)]
    line = 1
    i = 0
    spins = 0
    n = len(src)

    def fail(msg):
        out.append('%s:%d: %s' % (name, line, msg))

    def cur():
        return frames[-1]

    while i < n:
        # 看门狗：任何分支漏写 `i += 1` 都会变成死循环而不是一个错报，而挂住
        # 比错报难查得多（已经在这上面挂过两次）。宁可直接报信。
        spins += 1
        if spins > 4 * (n + 1):
            fail('scanner stuck at offset %d (a branch forgot to advance) ' % i
                 + '-- fix swift_lex_check.py, not the Swift source')
            break
        ch = src[i]
        if ch == '\n':
            line += 1
            if cur().kind == LINE:
                frames.pop()
            i += 1
            continue

        f = cur()
        rest = src[i:i + 3]

        # ---------------- comment frames ----------------
        if f.kind == BLOCK:
            if src.startswith('/*', i):
                f.depth += 1
                i += 2
                continue
            if src.startswith('*/', i):
                f.depth -= 1
                i += 2
                if f.depth == 0:
                    frames.pop()
                continue
            i += 1
            continue
        if f.kind == LINE:
            i += 1
            continue          # anything but a newline is comment body

        # ---------------- string frames ----------------
        if f.kind in (STRING, MULTI, RAW):
            # raw string: a quote run by exactly `hashes` '#' closes it
            if f.kind == RAW:
                if ch == '"':
                    j = i + 1
                    while j < n and src[j] == '#':
                        j += 1
                    if j - i - 1 == f.hashes:
                        literals.append(src[f.start:i])
                        frames.pop()
                        i = j
                        continue
                if ch == '\\' and src[i + 1:i + 3] == '#(':   # \#( ) interpolation
                    frames.append(Frame(CODE, line, is_interp=True))
                    i += 3
                    continue
                i += 1
                continue
            if f.kind == MULTI and rest == '"""':
                literals.append(src[f.start:i])
                frames.pop()
                i += 3
                continue
            if f.kind == STRING and ch == '"':
                literals.append(src[f.start:i])
                frames.pop()
                i += 1
                continue
            if ch == '\\':
                if src[i + 1:i + 2] == '(':
                    frames.append(Frame(CODE, line, is_interp=True))
                    i += 2
                    continue
                i += 2          # escaped char
                continue
            i += 1
            continue
        
        # ---------------- code frames ----------------
        # comments
        if src.startswith('//', i):
            frames.append(Frame(LINE, line))
            i += 2
            continue
        if src.startswith('/*', i):
            frames.append(Frame(BLOCK, line))
            i += 2
            continue
        # raw string open: #" or ##"
        if ch == '#':
            j = i
            while j < n and src[j] == '#':
                j += 1
            hashes = j - i
            if j < n and src[j] == '"':
                frames.append(Frame(RAW, line, hashes=hashes, start=j + 1))
                i = j + 1
                continue
            i += 1               # #selector / #if / #available
            continue
        # plain and multi-line strings
        if rest == '"""':
            frames.append(Frame(MULTI, line, quote='"""', start=i + 3))
            i += 3
            continue
        if ch == '"':
            frames.append(Frame(STRING, line, quote='"', start=i + 1))
            i += 1
            continue
        # char literal, skip so an apostrophe cannot swallow the rest of a line
        if ch == "'":
            j = i + 1
            if j + 1 < n and src[j] == '\\':
                j += 2
            if j < n and src[j] == "'":
                i = j + 1
                continue
            i += 1
            continue
        # delimiters
        if ch in OPEN:
            f.stack.append((ch, line))
            i += 1
            continue
        if ch in CLOSE:
            if not f.stack:
                # an interpolation frame ends at its own unmatched ')'
                if f.is_interp and ch == ')':
                    frames.pop()
                    i += 1
                    if frames and frames[-1].kind in (STRING, MULTI, RAW):
                        pass
                    continue
                fail("unexpected '%s'" % ch)
                i += 1
                continue
            opener, oline = f.stack[-1]
            if opener != CLOSE[ch]:
                fail("'%s' does not match '%s' opened on line %d" % (ch, opener, oline))
                i += 1
                continue
            f.stack.pop()
            i += 1
            continue
        # 兜底：任何没进上面分支的字符都前进一格。宁可少报一个形态，
        # 也不能因某个没考虑的分支就地死循环（v1 就是这么挂在第一个字符串上的）。
        i += 1

    for fr in frames:
        if fr.kind == CODE and fr.stack:
            for opener, oline in fr.stack:
                fail("unclosed '%s' opened on line %d" % (opener, oline))
        elif fr.kind in (STRING, MULTI):
            fail('unterminated %s string literal opened on line %d'
                 % ('multi-line' if fr.kind == MULTI else 'string', fr.line))
        elif fr.kind == RAW:
            fail('unterminated raw string opened on line %d' % fr.line)
        elif fr.kind == BLOCK:
            fail('unterminated block comment opened on line %d' % fr.line)
    return out, literals


def check_path(path):
    rel = path.replace(os.sep, '/')
    return scan(os.path.basename(rel), read_file(path))


def read_file(path):
    return io.open(path, encoding='utf-8', errors='replace').read()


def string_literals_of(path):
    rel = path.replace(os.sep, '/')
    return string_literals(os.path.basename(rel), read_file(path))


# --------------------------------------------------------------------------
# Self test: the checker must catch the real shapes and stay quiet otherwise.
GOOD = [
    ('plain interpolation', 'func f() -> String { "\\(a.b(1))" }\n'),
    ('nested interp in dict-ish', 'let x = ["k": "\\(m["n"])", "p": "\\(q.r(2))"]\n'),
    ('raw string with quotes', 'let j = #"{"a":[1,2],"b":"c"}"#\n'),
    ('raw string interp', 'let k = #"{ "v": \\#(value) }"#\n'),
    ('multi-line with quotes', 'let s = """\n he said "hi" (unbalanced (\n """\n'),
    ('nestable block comment', 'let y = 1 /* a /* b */ still comment */ + 2\n'),
    ('string in comment', '// note "unclosed ( bracket\n'),
    ('closure inside call', 'arr.map { v in f(g(v), h: [1, 2]) }\n'),
    ('apostrophe in comment', "// don't break the scanner\nlet z = 2\n"),
    ('interpolation with closure', 'print("\\([1,2].map { $0 * 2 })")\n'),
]
BAD = [
    # 括号错配：`[ ... )` 要报成"不匹配"，而不是默默吃掉
    ('bracket misorder', 'let a = ["x": 1)]\n', 'does not match'),
    # 字面量里嵌双引号：字符串提前结束，剩下的变成代码 + 末尾未闭合字符串
    ('quote inside literal', 'XCTAssertTrue(ok, "it said "no")\n', 'unterminated string'),
    ('unclosed brace', 'func f() {\n', "unclosed '{'"),
    ('stray close', 'let a = 1 }\n', "unexpected '}'"),
    ('unterminated string', 'let a = "abc\n', 'unterminated string'),
    ('unterminated block', 'let a = 1 /* oops\n', 'unterminated block comment'),
    ('unterminated raw', 'let a = #"abc"\n', 'unterminated raw string'),
]


def self_test():
    bad = 0
    for label, src in GOOD:
        got = scan('<good:%s>' % label, src)
        if got:
            bad += 1
            print('FALSE POSITIVE  %-28s %s' % (label, got[0]))
    for label, src, needle in BAD:
        got = scan('<bad:%s>' % label, src)
        if not got:
            bad += 1
            print('MISSED          %-28s (%s)' % (label, needle))
        elif needle not in ' '.join(got):
            bad += 1
            print('WRONG SHAPE     %-28s got %s want %s' % (label, got[0], needle))
    print('self-test: %d good + %d bad cases, %d problems'
          % (len(GOOD), len(BAD), bad))
    return bad


def repo_files():
    for root, dirs, names in os.walk('.'):
        parts = set(root.split(os.sep))
        if {'.git', 'build', 'DerivedData', '.codeartsdoer'} & parts:
            continue
        for name in sorted(names):
            if name.endswith('.swift'):
                yield os.path.join(root, name)


def main(argv):
    if '--self-test' in argv:
        return self_test()
    files = [a for a in argv[1:]] or sorted(repo_files())
    findings = []
    for f in files:
        findings += check_path(f)
    for x in findings:
        print(x)
    print('%d swift files checked, %d findings' % (len(files), len(findings)))
    return len(findings)


if __name__ == '__main__':
    sys.exit(1 if main(sys.argv) else 0)
