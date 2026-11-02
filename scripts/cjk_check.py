#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Chinese-text integrity check for this repo.

Why: the channel that writes into this repo has repeatedly swapped individual Chinese
characters for look-alikes -- in text it was not asked to touch. Observed here:
褶->裁/要, 撒->鞰, 阳->日, 锚->锦/锤, 颊->膣, 绝->绘/绍, and one case where 眼镜 lost a
character. Compilation is unaffected and no test fails, yet the docs are where this
project records its capability limits, so rot there is rot in the honesty layer.

Three precise things, and one thing deliberately NOT done:

  1. known-artifact scan: the exact wrong-but-valid strings seen in this repo.
  2. encoding scan: a file that is not valid UTF-8 means a mangled write landed.
  3. --expect <file> <term...>: after editing CJK text, assert the intended terms are
     still present, verbatim. This is the check that actually catches a fresh swap,
     because it compares against what the edit was supposed to say.

  NOT done: a statistical "rare character / bigram outlier" sweep. Tried first and
  measured: 244 findings over 142 files on a tree with no known corruption --
  ordinary words like 重启/面颊/创建 all match the shape. A check that cannot tell
  signal from noise is worse than no check, so it was removed rather than tuned
  into a list of exemptions. If it is ever revisited, it must first beat the
  `--self-test` clean-prose assertion below.

Findings are advisory by default; --strict makes them fail the run.
Every hit prints the codepoint, since the Windows console renders CJK as mojibake
while the file on disk is fine (and vice versa).

Usage:
    python scripts/cjk_check.py [--strict] [--self-test]
    python scripts/cjk_check.py --expect docs/pixcake-parity.md 祛黑眼圈 锚点 面颊
"""
import io
import os
import re
import sys

# Wrong-but-valid characters that have actually appeared as a result of a swap,
# recorded with the term they corrupted. Extend this list whenever a new swap is
# spotted -- it is the only durable form of knowledge about this failure mode.
KNOWN_BAD = {
    '脸膣': '面颊/脸部 (颊 -> 膣)',
    '眼眙': '眼镜 (镜 -> 眙)',
    '鞰谎': '撒谎 (撒 -> 鞰)',
    '祛要': '祛褶 (褶 -> 要)',
    '祛裁': '祛褶 (褶 -> 裁)',
    '锦点': '锚点 (锚 -> 锦)',
    '锤点': '锚点 (锚 -> 锤)',
    '绘不能': '绝不能 (绝 -> 绘)',
    '绍不能': '绝不能 (绝 -> 绍)',
    '限限制': '限制 (duplication)',
    # Four more shapes spotted while writing this very checker (2026-11-02): the
    # swap happens in prose describing the swap, which is how they were caught.
    '仍住': '拦住 (拦 -> 仍)',
    '纠钻': '刁钻 (刁 -> 纠)',
    '脸赧': '脸颊/面颊 (颊 -> 赧)',
    '给不能': '绝不能 (绝 -> 给)',
}

CJK = re.compile(r'[\u4e00-\u9fff]')
SKIP_DIRS = {'.git', 'build', 'DerivedData', '.codeartsdoer'}


def text_files():
    own = os.path.normpath(os.path.abspath(__file__))
    for root, dirs, names in os.walk('.'):
        if set(root.split(os.sep)) & SKIP_DIRS:
            continue
        for n in names:
            if not n.endswith(('.swift', '.md', '.py', '.yml', '.sh')):
                continue
            full = os.path.normpath(os.path.join(root, n))
            # The detector's own file contains every known artifact by definition --
            # scanning it turns the blacklist into a self-inflicted hit list.
            # Both sides must be absolute: `own` is, while the walk yields './...' paths,
            # and comparing the two forms silently never matches.
            if os.path.normpath(os.path.abspath(full)) == own:
                continue
            yield full.replace(os.sep, '/')


def read_text(path):
    """Return (text, None) or (None, reason). Never silently skip a bad file."""
    try:
        return io.open(path, encoding='utf-8').read(), None
    except UnicodeDecodeError as exc:
        return None, 'not valid UTF-8 (%s) -- a mangled write landed' % exc.reason


def scan(files):
    hits = []
    for path in files:
        text, err = read_text(path)
        if err:
            hits.append('%s: %s' % (path, err))
            continue
        for bad, why in KNOWN_BAD.items():
            for m in re.finditer(re.escape(bad), text):
                hits.append('%s:%d: %s -> U+%04X expected %s'
                            % (path, text[:m.start()].count('\n') + 1, bad,
                               ord(bad[-1]), why))
    return hits


def expect(path, terms):
    """Post-edit verification: every intended term must still be in the file."""
    text, err = read_text(path)
    if err:
        return ['%s: %s' % (path, err)]
    hits = []
    for term in terms:
        n = text.count(term)
        if n == 0:
            hits.append('%s: expected term %r is absent -- verify the edit wrote it '
                        'verbatim (this channel has swapped single characters before)'
                        % (path, term))
        else:
            print('  ok %s x%d' % (term, n))
    return hits


def self_test():
    """Injected swaps MUST be flagged; clean prose MUST NOT be; --expect MUST fail
    on a corrupted file and pass on a good one. Without this, a checker that reports
    nothing is indistinguishable from a checker that works."""
    clean = ('面板提供祛黑眼圈与法令纹滑杆，锚点取自虹膜半径，面颊高光只降不升；\n'
             '绝不能在这里放宽阈值，因为遮瑕与眼镜反光是两件事。\n')
    swapped = ('面板提供祛黑眼圈与法令纹滑杆，锦点取自虹膜半径，脸膣高光只降不升；\n'
               '绘不能在这里放宽阈值，因为遮瑕与眼眙反光是两件事。祛要褶也要盯。\n')
    problems = 0
    # scan() takes real paths, so write the two corpora into the temp dir
    tmp = os.path.join(os.environ.get('TEMP', '.'), 'cjk_selftest')
    os.makedirs(tmp, exist_ok=True)
    good = os.path.join(tmp, 'good.md').replace(os.sep, '/')
    bad = os.path.join(tmp, 'bad.md').replace(os.sep, '/')
    io.open(good, 'w', encoding='utf-8').write(clean)
    io.open(bad, 'w', encoding='utf-8').write(swapped)

    hits_clean = scan([good])
    hits_bad = scan([bad])
    if hits_clean:
        problems += 1
        print('self-test FAILED: clean prose flagged -> %s' % hits_clean[0])
    for needle in ('锦点', '膣', '绘不能', '眼眙', '祛要'):
        if not any(needle in h for h in hits_bad):
            problems += 1
            print('self-test FAILED: injected %s not detected' % needle)
    if expect(good, ['锚点', '面颊']):
        problems += 1
        print('self-test FAILED: --expect rejected a clean file')
    if not expect(bad, ['锚点', '面颊']):
        problems += 1
        print('self-test FAILED: --expect passed a corrupted file')
    # a non-UTF-8 file must be reported, not skipped
    broken = os.path.join(tmp, 'broken.md').replace(os.sep, '/')
    io.open(broken, 'wb').write(b'\xe6\x8b\xa0 not utf8 \xff\xfe end')
    if not scan([broken]):
        problems += 1
        print('self-test FAILED: invalid UTF-8 passed silently')
    for p in (good, bad, broken):
        os.remove(p)
    print('self-test: clean=%d injected=%d problems=%d'
          % (len(hits_clean), len(hits_bad), problems))
    return problems


def main(argv):
    if '--self-test' in argv:
        return self_test()
    if '--expect' in argv:
        i = argv.index('--expect')
        path = argv[i + 1]
        terms = [a for a in argv[i + 2:] if not a.startswith('--')]
        hits = expect(path, terms)
        for h in hits:
            print(h)
        print('expect check: %d term(s), %d finding(s)' % (len(terms), len(hits)))
        return 1 if hits else 0
    files = sorted(text_files())
    hits = scan(files)
    for h in hits:
        print(h)
    print('cjk check: %d file(s) scanned, %d finding(s)' % (len(files), len(hits)))
    return 1 if (hits and '--strict' in argv) else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
