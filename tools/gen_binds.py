#!/usr/bin/env python3
"""
Regenerates D-RadeonProRender bindings from the upstream RadeonProRender.h.

Translates:
  * `typedef ...`        -> aliases in source/bindbc/rpr/bind/types.d
  * `#define RPR_X N`    -> grouped manifest constants in types.d
  * `extern RPR_API_ENTRY <ret> <name>(<args>);` -> FnBind[] entries in core.d
                          (consumed by joinFnBinds mixin from bindbc-common)

Run from the repo root once after updating the SDK:
  python3 tools/gen_binds.py /path/to/RadeonProRenderSDK/RadeonProRender/inc/RadeonProRender.h
"""

import argparse
import pathlib
import re
import sys
from collections import OrderedDict
from textwrap import dedent

HDR_RE_FUNC   = re.compile(r'^\s*extern\s+RPR_API_ENTRY\s+(.+?)\s+(rpr[A-Za-z0-9_]+)\s*\((.*)\)\s*;\s*$')
HDR_RE_TYPDEF = re.compile(r'^\s*typedef\s+(.+?)\s+(rpr_[A-Za-z0-9_]+)\s*;\s*$')
HDR_RE_DEFINE = re.compile(r'^\s*#define\s+(RPR_[A-Z0-9_]+)\s+(.+?)\s*(?://.*)?$')

# C -> D type translations. Apply in order, on whole signature strings.
# Most rpr_* aliases stay verbatim; only const/pointer syntax needs care.
def c2d_type(s: str) -> str:
    s = s.strip()
    # normalize whitespace
    s = re.sub(r'\s+', ' ', s)
    # `const TYPE *` and `TYPE const *` -> `const(TYPE)*`
    s = re.sub(r'\bconst\s+([A-Za-z_][A-Za-z_0-9]*)\s*\*', r'const(\1)*', s)
    s = re.sub(r'\b([A-Za-z_][A-Za-z_0-9]*)\s+const\s*\*', r'const(\1)*', s)
    # tidy space before *
    s = re.sub(r'\s*\*', r'*', s)
    # Remaining `const` (on value types, e.g. `rpr_image_format const`) has no
    # ABI effect — drop it so the D parser doesn't choke. Use a negative
    # lookahead so we don't eat `const` inside an already-translated `const(T)*`.
    s = re.sub(r'\bconst\b(?!\s*\()', '', s)
    s = re.sub(r'\s+', ' ', s).strip()
    return s


def c2d_params(params: str) -> str:
    params = params.strip()
    if params == '' or params == 'void':
        return ''
    # split on commas at top level (RPR sigs have no nested parens)
    out = []
    for p in params.split(','):
        p = p.strip()
        if not p:
            continue
        # last identifier is the name; everything before is the type
        m = re.match(r'^(.*?)\s+([A-Za-z_][A-Za-z_0-9]*)\s*$', p)
        if not m:
            # fallback: whole thing as type
            out.append(c2d_type(p))
            continue
        ty, nm = m.group(1), m.group(2)
        out.append(f'{c2d_type(ty)} {nm}')
    return ', '.join(out)


HDR_RE_STRUCT_BEGIN = re.compile(r'^\s*struct\s+(_rpr_[A-Za-z0-9_]+)\s*$')

def parse_structs(header_text: str):
    """Return list[(name, [(d_type, field_name), ...])]."""
    structs = []
    lines = header_text.splitlines()
    i = 0
    while i < len(lines):
        m = HDR_RE_STRUCT_BEGIN.match(lines[i])
        if not m:
            i += 1
            continue
        name = m.group(1)
        # next non-empty line must be `{`
        i += 1
        while i < len(lines) and lines[i].strip() == '':
            i += 1
        if i >= len(lines) or lines[i].strip() != '{':
            continue
        i += 1
        fields = []
        while i < len(lines) and not lines[i].strip().startswith('}'):
            field_line = lines[i].strip().rstrip(';').strip()
            if field_line and not field_line.startswith('//'):
                fm = re.match(r'^(.*?)\s+([A-Za-z_][A-Za-z_0-9]*)$', field_line)
                if fm:
                    fields.append((c2d_type(fm.group(1)), fm.group(2)))
            i += 1
        structs.append((name, fields))
        i += 1
    return structs


def parse_header(header_text: str):
    typedefs = []     # list[(c_lhs, alias)]
    defines  = []     # list[(name, value)]
    funcs    = []     # list[(ret, name, params)]

    for line in header_text.splitlines():
        # ignore the RPR_API_ENTRY define itself
        if '#define RPR_API_ENTRY' in line and 'extern' not in line:
            continue

        m = HDR_RE_FUNC.match(line)
        if m:
            ret, name, params = m.group(1), m.group(2), m.group(3)
            funcs.append((c2d_type(ret), name, c2d_params(params)))
            continue

        m = HDR_RE_TYPDEF.match(line)
        if m:
            lhs, alias = m.group(1).strip(), m.group(2)
            typedefs.append((lhs, alias))
            continue

        m = HDR_RE_DEFINE.match(line)
        if m:
            name, value = m.group(1), m.group(2).strip()
            # skip version / api defines that are not enum-shaped
            if name in ('RPR_API_VERSION', 'RPR_API_VERSION_MINOR', 'RPR_API_ENTRY'):
                continue
            # skip macros that look like function-like / contain reference to another macro chain
            if value.startswith('"') or '\\' in value:
                continue
            defines.append((name, value))

    return typedefs, defines, funcs


def render_structs(structs):
    out = []
    for name, fields in structs:
        out.append(f'struct {name} {{')
        for ty, nm in fields:
            out.append(f'    {ty} {nm};')
        out.append('}\n')
    return '\n'.join(out)


def render_typedefs(typedefs):
    # Translate primitive C types to D primitives.
    c2d = {
        'char':                 'char',
        'unsigned char':        'ubyte',
        'int':                  'int',
        'unsigned int':         'uint',
        'long int':             'long',
        'long unsigned int':    'ulong',
        'short int':            'short',
        'short unsigned int':   'ushort',
        'float':                'float',
        'double':               'double',
        'long long int':        'long',
        'void *':               'void*',
    }
    lines = []
    for lhs, alias in typedefs:
        lhs_n = re.sub(r'\s+', ' ', lhs).strip()
        if lhs_n in c2d:
            rhs = c2d[lhs_n]
        elif lhs_n.endswith('*'):
            rhs = c2d_type(lhs_n)
        else:
            # likely already an rpr_* alias
            rhs = lhs_n
        lines.append(f'alias {alias} = {rhs};')
    return '\n'.join(lines)


# Group #defines by leading token after RPR_, so a few clean enum blocks
# emerge instead of one giant flat list.
def render_defines(defines):
    groups = OrderedDict()
    for name, value in defines:
        # group key = "RPR_" + first 1-2 segments to keep readable buckets
        m = re.match(r'RPR_([A-Z]+(?:_[A-Z]+)?)', name)
        key = m.group(1) if m else 'MISC'
        groups.setdefault(key, []).append((name, value))

    out = []
    for key, items in groups.items():
        out.append(f'// {key}')
        out.append('enum : rpr_uint {')
        for name, value in items:
            out.append(f'    {name} = {value},')
        out.append('}\n')
    return '\n'.join(out)


def render_funcs(funcs):
    rows = []
    for ret, name, params in funcs:
        rows.append('    {q{' + ret + '}, q{' + name + '}, q{' + params + '}},')
    return '\n'.join(rows)


TYPES_HEADER = dedent('''\
    /// Auto-generated by tools/gen_binds.py from RadeonProRender.h.
    /// Do not edit by hand — re-run the generator after updating the SDK.
    module bindbc.rpr.bind.types;

    // size_t comes from druntime's implicit `object` import — no extra import
    // needed, and avoiding `core.stdc.stddef.size_t` keeps overload sets clean
    // inside joinFnBinds-generated mixins.

    extern (C):

    // --- typedefs ----------------------------------------------------------
''')

CORE_HEADER = dedent('''\
    /// Auto-generated by tools/gen_binds.py from RadeonProRender.h.
    /// Do not edit by hand — re-run the generator after updating the SDK.
    module bindbc.rpr.bind.core;

    import bindbc.rpr.bind.types;
    import bindbc.rpr.codegen;

    mixin(joinFnBinds((){
        FnBind[] ret = [
''')

CORE_FOOTER = dedent('''\
        ];
        return ret;
    }()));
''')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('header', type=pathlib.Path)
    ap.add_argument('--out', type=pathlib.Path,
                    default=pathlib.Path(__file__).resolve().parent.parent
                                                 / 'source' / 'bindbc' / 'rpr' / 'bind')
    args = ap.parse_args()

    text = args.header.read_text()
    typedefs, defines, funcs = parse_header(text)
    structs = parse_structs(text)

    args.out.mkdir(parents=True, exist_ok=True)

    types_d = TYPES_HEADER \
        + '\n// --- structs ---------------------------------------------------------\n\n' \
        + render_structs(structs) \
        + '\n// --- typedef aliases -------------------------------------------------\n\n' \
        + render_typedefs(typedefs) \
        + '\n\n// --- #define constants ------------------------------------------------\n\n' \
        + render_defines(defines)
    (args.out / 'types.d').write_text(types_d)

    core_d = CORE_HEADER + render_funcs(funcs) + '\n' + CORE_FOOTER
    (args.out / 'core.d').write_text(core_d)

    print(f'typedefs: {len(typedefs)}')
    print(f'#defines: {len(defines)}')
    print(f'functions: {len(funcs)}')
    print(f'wrote: {args.out / "types.d"}')
    print(f'wrote: {args.out / "core.d"}')


if __name__ == '__main__':
    sys.exit(main())
