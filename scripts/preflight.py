#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""One entry point for every check that costs zero CI minutes.

The development machine has no Swift toolchain, so the authoritative compile/test
step is GitHub Actions on a macOS runner -- billed at 5x, and this account has run
out of minutes twice while waiting on it. Everything here runs locally, in seconds,
and catches the classes of mistake that used to cost a full round each:

  lex      -- unbalanced delimiters, unterminated strings/comments, and the two
             shapes that burned real rounds: an array literal with brackets in the
             wrong order, and a double quote pasted inside a string literal.
  wiring   -- parameter fields vs CodingKeys/decode/encode/clamp/knownKeys, a
             parameter group no render path consumes, an engine with no call site
             (the "哑资产" shape), requires prefixes not kept by the sync filter,
             documented tokens that code no longer emits, a model manifest purpose
             that contradicts whether a task reads that weight, an entry reachable
             only from EditorModel while no panel calls it, a doc that still calls a
             shipped capability a gap, and documented test-case counts vs the tree.
             Self-test the checker itself with: python scripts/wiring_check.py --self-test
  cjk      -- known look-alike character swaps in Chinese prose, and files that are
             not valid UTF-8.
  manifest -- scripts/fetch_models.py --list (the model manifest is the single source
             of truth for weights; CI validates it too, but failing here is free).
  ps1      -- PowerShell parser for the CI helper scripts (PS 5.1 mangles BOM-less
             UTF-8, so those scripts are kept ASCII).

WHAT THIS DOES NOT PROVE -- printed on purpose, because a green local run is
tempting to read as "verified":
  * it does not compile. Type errors, protocol conformance, wrong argument labels,
    API signature drift and any runtime trap (e.g. the UInt8 subtraction one) still
    need the macOS runner.
  * it does not run the test suite, and it cannot measure performance -- a timing
    claim needs the Release configuration, which only CI (or a real Mac) provides.

Usage:
    python scripts/preflight.py            # run everything
    python scripts/preflight.py lex wiring # run a subset
Exit code = number of failing checks.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import swift_lex_check   # noqa: E402
import wiring_check      # noqa: E402
import cjk_check         # noqa: E402

PY = sys.executable


def run_lex():
    files = sorted(swift_lex_check.repo_files())
    n = 0
    for f in files:
        n += len(swift_lex_check.check_path(f))
    return n, '%d swift files' % len(files)


def run_wiring():
    # wiring_check.main() prints its findings and returns the count; its lex pass is
    # the same one run_lex already did, so reuse the exit code as the finding count.
    return wiring_check.main(), ('parameters, render wiring, tokens, manifest claims, '
                                 'UI entries, doc gap claims, test counts')


def run_cjk():
    files = sorted(cjk_check.text_files())
    hits = cjk_check.scan(files)
    for h in hits:
        print(h)
    return len(hits), '%d text files' % len(files)


def decode(raw):
    """Child tools here print Chinese, and on this box they use the console codepage
    (GBK), not UTF-8. `text=True` + UTF-8 decoding crashes the reader thread and
    silently yields an empty string -- which then looks like "no output, but rc=0".
    Take bytes and decode with a fallback so the note is real."""
    for enc in ('utf-8', 'gbk'):
        try:
            return raw.decode(enc)
        except UnicodeDecodeError:
            continue
    return raw.decode('utf-8', 'replace')


def run_manifest():
    r = subprocess.run([PY, os.path.join(HERE, 'fetch_models.py'), '--list'],
                       capture_output=True, cwd=os.path.dirname(HERE))
    out = decode(r.stdout or b'')
    err = decode(r.stderr or b'')
    lines = [l for l in out.strip().split('\n') if l.strip()]
    if r.returncode:
        print((err or out).strip()[-600:])
    note = lines[-1] if lines else 'no output from --list (rc=%d)' % r.returncode
    # no output is not a pass: say so instead of reporting a blank OK
    return (0 if r.returncode == 0 and lines else 1), note


def run_ps1():
    targets = [os.path.join(HERE, n) for n in
               ('github-bootstrap.ps1', 'make-app-icon.ps1', 'ci-status.ps1',
                'ci-failure-detail.ps1', 'ci-errors.ps1', 'ci-rerun.ps1', 'ci-wait.ps1')]
    r = subprocess.run(['powershell', '-File', os.path.join(HERE, 'syntax-check.ps1')]
                       + [t for t in targets if os.path.exists(t)],
                       capture_output=True, cwd=os.path.dirname(HERE))
    print(decode(r.stdout or b'').strip())
    return r.returncode, '%d ps1 scripts' % len(targets)


CHECKS = [('lex', run_lex), ('wiring', run_wiring), ('cjk', run_cjk),
          ('manifest', run_manifest), ('ps1', run_ps1)]


def main(argv):
    wanted = [a for a in argv[1:] if not a.startswith('-')] or [n for n, _ in CHECKS]
    failed = 0
    for name, fn in CHECKS:
        if name not in wanted:
            continue
        print('== %s ==' % name)
        try:
            count, note = fn()
        except Exception as exc:                    # a crashing check is a failure
            count, note = 1, 'checker crashed: %r' % (exc,)
        status = 'OK  ' if count == 0 else 'FAIL(%s)' % count
        print('-- %s %s: %s\n' % (status, name, note))
        if count:
            failed += 1
    print('preflight: %d check(s) failed' % failed)
    # Kept ASCII on purpose: the Windows console renders CJK as mojibake here, and a
    # caveat nobody can read is not a caveat.
    print('NOT proved by preflight: it does not COMPILE (types, protocol conformance, '
          'argument labels, runtime traps still need the macOS runner), it does not run '
          'the test suite, and it cannot back any performance claim (timing must be '
          'measured in Release).')
    return failed


if __name__ == '__main__':
    sys.exit(1 if main(sys.argv) else 0)
