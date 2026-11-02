#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Parameter/engine wiring checks that need no compiler.

Every one of these corresponds to a bug that passed the full test suite here, because
the suite asserts engine behaviour and parameter storage but not the *wiring*:

  * a field added to a parameters struct but missing from CodingKeys / decode /
    encode / knownKeys  -> "stored in UI, lost on save" or "our own key reported as
    unknown in the preset report"
  * a parameter group that no render path consumes -> the slider moves, nothing
    changes (this is the single most common defect shape in this repo's history)
  * an engine with `apply` but no call site        -> a dead asset ("哑资产"):
    implementation, tests and docs all green, feature does not exist
  * a `requires` prefix written but not filtered by the sync rules (or the reverse)
  * a missing-asset token (`[no_*]`, `[fallback:*]`) that never reached the docs,
    or a documented token that no longer exists in code

Exit code = number of findings. Output is ASCII so it survives the Windows console
codepage; the strings it reads are UTF-8.
"""
import io
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from swift_lex_check import check_path, string_literals_of  # noqa: E402

DOMAIN = 'ImageCake/Domain'
IMAGING = 'ImageCake/Imaging'
UI = 'ImageCake/UI'
SOURCES = ['ImageCake', 'Tests']
DOCS = ['README.md', 'docs']

PARAM_STRUCT_RE = re.compile(r'(?:public )?struct (\w+Parameters)\s*:')
# Stored properties only: `[ ^\n=]` must not cross newlines, otherwise
# `public var isSkinNeutral: Bool {` (a computed property) swallows the next `=`.
FIELD_RE = re.compile(r'^\s{4}public var (\w+)\s*:\s*([^\n={]+)\s*=\s*([^\n{]+)', re.M)
CLAMP_RE = re.compile(r'(\w+)\s*=\s*\1\.clamped')          # also matches `a = ...; b = ...`
APPLY_RE = re.compile(r'^\s{4}static func apply\(', re.M)
TOP_TYPE_RE = re.compile(r'^(?:public |final |fileprivate )*?(?:struct|enum|class|actor) (\w+)', re.M)
PREFIX_RE = re.compile(r'hasPrefix\("([a-z_]+:)"\)')
TOKEN_RE = re.compile(r'\[(no_[a-z0-9_]+|[a-z0-9_]+:[a-z0-9_.-]+)\]')


def read(path):
    return io.open(path, encoding='utf-8', errors='replace').read()


def swift_files():
    for root, dirs, names in os.walk('ImageCake'):
        parts = set(root.split(os.sep))
        if {'.git', 'build'} & parts:
            continue
        for n in sorted(names):
            if n.endswith('.swift'):
                yield os.path.join(root, n).replace(os.sep, '/')


def doc_text():
    chunks = []
    if os.path.exists('README.md'):
        chunks.append(read('README.md'))
    for root, _, names in os.walk('docs'):
        for n in names:
            if n.endswith('.md'):
                chunks.append(read(os.path.join(root, n)))
    return '\n'.join(chunks)


def struct_blocks(src):
    """Yield (struct_name, body) for each *Parameters struct, brace-matched."""
    for m in struct_structures(src):
        yield m


def struct_structures(src):
    out = []
    for m in struct_structures_iter(src):
        out.append(m)
    return out


def struct_structures_iter(src):
    for m in PARAM_STRUCT_RE.finditer(src):
        name = m.group(1)
        brace = src.find('{', m.end())
        if brace < 0:
            continue
        depth = 0
        i = brace
        while i < len(src):
            if src[i] == '{':
                depth += 1
            elif src[i] == '}':
                depth -= 1
                if depth == 0:
                    break
            i += 1
        yield name, src[brace + 1:i], brace


def coding_keys(*blocks):
    """name -> serialized key.

    Two shapes cost real rounds to get wrong here: `case a = "x", b, c = "y"`
    lists several per line, and `enum CodingKeys { case a }` fits on one line, so
    scanning line starts for `case` silently loses entries (and a missing entry
    looks exactly like a real bug in the Swift).
    """
    out = {}
    for block in blocks:
        start = block.find('enum CodingKeys')
        if start < 0:
            continue
        brace = block.find('{', start)
        end = block.find('}', brace)
        if brace < 0 or end < 0:
            continue
        inner = block[brace + 1:end]
        for piece in re.split(r'[\n;]', inner):
            piece = piece.strip()
            if not piece.startswith('case '):
                continue
            # Strip `case ` FIRST, then split: only the leading entry carries the
            # keyword, so splitting before stripping drops every name after the
            # first comma -- which reads exactly like a missing CodingKey.
            for entry in piece[5:].split(','):
                m = re.match(r'\s*(\w+)(?:\s*=\s*"([^"]+)"\s*)?$', entry)
                if m:
                    out[m.group(1)] = m.group(2) or m.group(1)
    return out


def check_parameter_contract(path, findings, seen_structs):
    """Fields of a parameters struct must appear in all of its serialisation sites."""
    src = read(path)
    for name, body, _ in struct_structures(src):
        seen_structs.add(name)
        fields = [(m.group(1), m.group(2).strip(), m.group(3).strip())
                  for m in FIELD_RE.finditer(body)]
        fields = [f for f in fields if 'static' not in f[2]]
        if not fields:
            continue
        # Codable may live in a later `extension X: Codable` OR inside the struct
        # itself; look in both places before claiming a key is missing.
        ext = src[src.find('extension %s: Codable' % name):]
        keys = coding_keys(ext, body)
        decoded = set(re.findall(r'forKey:\s*\.(\w+)',
                                 (ext[ext.find('init(from'):] if 'init(from' in ext else '')
                                  + body))
        encoded = set(re.findall(r'forKey:\s*\.(\w+)',
                                 (ext[ext.find('func encode'):] if 'func encode' in ext else '')
                                  + body))
        clamped = set(CLAMP_RE.findall(body[body.find('func clamp'):] if 'func clamp' in body else ''))
        where = os.path.basename(path)
        for fname, ftype, default in fields:
            if fname in DERIVED_KEYS:
                continue
            if fname not in keys:
                findings.append('%s: %s.%s missing from CodingKeys '
                                '(cannot be stored)' % (where, name, fname))
            elif name == 'EditParameters' and keys[fname] not in doc_known_keys(
                    read('%s/EditParameters.swift' % DOMAIN)):
                findings.append('EditParameters.%s serialises as "%s" which is not in '
                                'knownKeys (our own key would be reported as unknown)'
                                % (fname, keys[fname]))
            if fname not in decoded:
                findings.append('%s: %s.%s not decoded (a saved value would never come back)'
                                % (where, name, fname))
            if fname not in encoded:
                findings.append('%s: %s.%s not encoded (value is dropped on save)'
                                % (where, name, fname))
            if ftype == 'Double' and 'func clamp' in body and fname not in clamped:
                findings.append('%s: %s.%s not clamped (panel/preset can feed out-of-range values)'
                                % (where, name, fname))
    return


# Fields intentionally serialised through derived keys (a struct field with no
# matching CodingKey of its own). Listed here with the reason, so the checker does
# not shout about them and a human does not have to re-derive the answer.
DERIVED_KEYS = {
    'curves': 'stored as curve_x / curve_y (four channels, two parallel arrays)',
}


def doc_known_keys(src):
    # Anchor on the declaration: the word `knownKeys` also appears in comments about
    # keeping it in sync, and a comment match silently truncates the set.
    start = src.find('static let knownKeys')
    if start < 0:
        start = src.find('knownKeys')
    block = src[start:]
    opener = block.find('[')
    block = block[opener:]
    return set(re.findall(r'"([a-z0-9_]+)"', block[:block.find(']')]))


def check_render_wiring(findings):
    """Every parameter group with isNeutral must be consumed by the render path,
    and every group must have a UI entry point."""
    doc = read('%s/ImageDocument.swift' % DOMAIN)
    render = doc[doc.find('func render('):]
    render = render[:render.find('\n    /// ') if '\n    /// ' in render else render.find('\n    static ')]
    edit = read('%s/EditParameters.swift' % DOMAIN)
    groups = [m.group(1) for m in re.finditer(r'public var (\w+) = \w+Parameters\(\)', edit)]
    aliases = dict((m.group(1), m.group(2)) for m in
                   re.finditer(r'let (\w+) = params\.(\w+)', render))
    ui_files = {p: read(p) for p in swift_files() if p.startswith(UI)}
    for g in groups:
        consumed = ('params.%s' % g) in render or g in aliases.values()
        if not consumed:
            findings.append('ImageDocument.render() never reads params.%s '
                            '(parameter stored but nothing consumes it)' % g)
        in_ui = any(('params.%s' % g) in text or ('.%s.' % g) in text
                    for text in ui_files.values())
        if not in_ui:
            findings.append('no UI file references params.%s (a group with no entry point '
                            'is a dead feature)' % g)


def enclosing_type(src, offset):
    """The innermost top-level (column 0) type containing `offset`.

    Nested structs sit at indent 4; attributing a `static func apply` to whichever
    type name happened to appear last in the file points at the wrong owner and
    makes a wired-up engine look like a dead asset.
    """
    best = None
    for m in TOP_TYPE_RE.finditer(src):
        if m.start() >= offset:
            break
        best = m.group(1)
    return best


def check_engine_entries(findings):
    """`static func apply(` in Imaging must be called from outside its own file."""
    files = {p: read(p) for p in swift_files()}
    for path, src in files.items():
        if not path.startswith(IMAGING):
            continue
        for m in APPLY_RE.finditer(src):
            ty = enclosing_type(src, m.start())
            if not ty:
                continue
            needle = '%s.apply(' % ty
            callers = [p for p, s in files.items() if p != path and needle in s]
            if not callers:
                findings.append('%s: %s has apply() but no call site anywhere '
                                '(implementation + tests, no feature)'
                                % (os.path.basename(path), ty))


def check_tokens(findings):
    """Documented tokens must still exist in code.

    Only this direction is checked on purpose. The reverse ("every token the code
    emits must be written up") is noise: docs list a curated subset of the ~40
    tokens, and forcing parity would get the list padded rather than read. The
    direction that actually bit this repo is a doc claiming a token/panel/entry
    that no longer exists in code (a stale "provides the entry point" line).
    """
    code = set()
    for path in swift_files():
        for lit in string_literals_of(path):
            # Tokens sit mid-sentence ("... · [fallback:sky-colour-locus]"), so an
            # anchored match silently finds almost none and every doc token then
            # looks stale.
            code |= set(m.group(0) for m in TOKEN_RE.finditer(lit))
    docs = doc_text()
    documented = set(re.findall(r'\[(?:no_[a-z0-9_]+|[a-z0-9_]+:[a-z0-9_.-]+)\]', docs))
    for tok in sorted(documented - code):
        stem = tok.rstrip(']').split(':')[0]
        if not any(c.startswith(stem) for c in code):
            findings.append('%s is documented but no code emits it any more' % tok)


def check_requires(findings):
    """`requires` prefixes written into params must be handled by the sync filter."""
    all_src = {p: read(p) for p in swift_files()}
    written = set()
    for src in all_src.values():
        for m in re.finditer(r'"([a-z_]+):\\\(', src):
            written.add(m.group(1) + ':')
    kept = set()
    for src in all_src.values():
        kept |= set(PREFIX_RE.findall(src))
    for pref in sorted(written - kept):
        findings.append('requires entry "%s…" is written but ParamSync never keeps it '
                        '(it would be dropped on the first sync)' % pref)
    for pref in sorted(kept - written):
        findings.append('ParamSync filters on "%s" but nothing writes that prefix' % pref)


def main():
    findings = []
    lex_findings = []
    for path in sorted(swift_files()):
        lex_findings += check_path(path)
    findings += lex_findings

    seen = set()
    for name in ('BeautyParameters.swift', 'SceneParameters.swift', 'EditParameters.swift'):
        check_parameter_contract('%s/%s' % (DOMAIN, name), findings, seen)
    check_render_wiring(findings)
    check_engine_entries(findings)
    check_tokens(findings)
    check_requires(findings)

    for f in findings:
        print(f)
    print('wiring check: %d swift files, %d parameter structs, %d findings'
          % (len(list(swift_files())), len(seen), len(findings)))
    return len(findings)


if __name__ == '__main__':
    sys.exit(1 if main() else 0)
