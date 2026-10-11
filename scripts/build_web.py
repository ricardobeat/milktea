#!/usr/bin/env python3
"""Compile portable examples with the browser runtime, using native target sources."""
import argparse
import gzip
import json
import os
import re
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'web/build'
# These targets need facilities outside the cell renderer.
UNSUPPORTED = {
    'ai-harness': 'native HTTP/curl', 'file-picker': 'host filesystem',
    'taro': 'QuickJS and native HTTP', 'minecraft': 'QuickJS/native services',
    'wolf3d': 'QuickJS/native services', 'wolf3d-server': 'native server/SQLite',
    'nineslice': 'kitty graphics', 'squiggle': 'kitty graphics',
    'oiia-player': 'native image/video loading', 'glb-viewer': 'native asset loading',
    'doom-fire-donut': 'native asset loading',
}


def read_leb(data, offset):
    value, shift = 0, 0
    while True:
        byte = data[offset]
        offset += 1
        value |= (byte & 127) << shift
        if byte < 128:
            return value, offset
        shift += 7


def leb(value):
    out = bytearray()
    while value >= 128:
        out.append((value & 127) | 128)
        value >>= 7
    out.append(value)
    return out


def browser_exports(path):
    """Keep the browser ABI; native library exports need not keep code alive."""
    data = path.read_bytes()
    if data[:8] != b'\0asm\x01\0\0\0':
        raise ValueError(f'{path}: not a WebAssembly module')
    out = bytearray(data[:8])
    offset = 8
    while offset < len(data):
        start = offset
        section = data[offset]
        size, payload = read_leb(data, offset + 1)
        offset = payload + size
        if section != 7:
            out.extend(data[start:offset])
            continue
        count, cursor = read_leb(data, payload)
        entries = []
        for _ in range(count):
            entry = cursor
            length, cursor = read_leb(data, cursor)
            name = data[cursor:cursor + length].decode('utf8')
            cursor += length + 1  # name and external kind
            _, cursor = read_leb(data, cursor)  # index; references stay intact
            if name in ('memory', '_initialize') or name.startswith('mt_'):
                entries.append(data[entry:cursor])
        content = leb(len(entries)) + b''.join(entries)
        out.append(7)
        out.extend(leb(len(content)))
        out.extend(content)
    path.write_bytes(out)


def build(name, config, optimizer, engine=False):
    files = set()
    for pattern in [*config['sources'], 'xray/**', 'boba/**', 'milktea-web/**']:
        files.update(p for p in ROOT.glob(pattern + '/*.c3' if pattern.endswith('/**') else pattern) if p.suffix == '.c3')
    mains = [p for p in files if re.search(r'^fn\s+int\s+main\s*\(', p.read_text(), re.M)]
    if engine:
        entries = []
    else:
        if len(mains) != 1:
            raise SystemExit(f'{name}: expected one main(), found {len(mains)}')
        module = re.search(r'module\s+([\w:]+)', mains[0].read_text())[1]
        entry = OUT / f'{name}-entry.c3'
        entry.write_text(f'module web_entry;\nimport {module};\n'
                         f'fn void boot() @wasm("mt_boot") {{ @pool() {{ (void){module}::main(); }}; }}\n')
        entries = [str(entry.relative_to(ROOT))]
    cmd = ['c3c', 'compile', *[str(p.relative_to(ROOT)) for p in sorted(files)],
           *entries, *(['-D', 'MILKTEA_JS'] if engine else []), '-D', 'MILKTEA_WEB', '--target', 'wasm32',
           '--link-libc=no', '--no-entry', '--reloc=none', '-Oz',
           '-o', str((OUT / name).relative_to(ROOT)), '-z', '--allow-undefined',
           '-z', '--strip-all']
    subprocess.run(cmd, cwd=ROOT, check=True)
    wasm = OUT / f'{name}.wasm'
    browser_exports(wasm)
    compiled_size = wasm.stat().st_size
    if optimizer:
        optimized = OUT / f'{name}.optimized.wasm'
        subprocess.run([optimizer, str(wasm), '-Oz', '--enable-bulk-memory', '--enable-nontrapping-float-to-int',
                        '--enable-sign-ext', '--strip-debug', '--strip-producers',
                        '-o', str(optimized)], check=True)
        # Retain the smaller artifact if a pass grows this particular program.
        if optimized.stat().st_size < wasm.stat().st_size:
            optimized.replace(wasm)
        else:
            optimized.unlink()
    data = wasm.read_bytes()
    compressed = gzip.compress(data, compresslevel=9, mtime=0)
    wasm.with_suffix('.wasm.gz').write_bytes(compressed)
    result = {'compilerBytes': compiled_size, 'wasmBytes': len(data),
              'gzipBytes': len(compressed)}
    print(f'  {compiled_size:,} -> {len(data):,} bytes ({result["gzipBytes"]:,} with gzip)', flush=True)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--engine', action='store_true', help='build reusable milktea.wasm for JavaScript models')
    parser.add_argument('examples', nargs='*', help='example names (default: all portable examples)')
    parser.add_argument('--wasm-opt', default=os.environ.get('WASM_OPT') or shutil.which('wasm-opt'),
                        help='optional Binaryen wasm-opt path (also detected on PATH or through WASM_OPT)')
    args = parser.parse_args()
    if args.engine:
        OUT.mkdir(parents=True, exist_ok=True)
        build('milktea', {'sources': ['milktea/**', 'glaze/**', 'dye/**', 'tgp/**']}, args.wasm_opt, engine=True)
        return
    targets = {k.removeprefix('examples/'): v for k, v in json.loads((ROOT / 'project.json').read_text())['targets'].items() if k.startswith('examples/')}
    names = args.examples or [n for n in targets if n not in UNSUPPORTED]
    OUT.mkdir(parents=True, exist_ok=True)
    manifest = OUT / 'examples.json'
    sizes = json.loads(manifest.read_text()).get('sizes', {}) if manifest.exists() else {}
    if not args.wasm_opt:
        print('Stripping metadata and unused exports; install wasm-opt for an additional size pass.', flush=True)
    for name in names:
        if name not in targets:
            parser.error(f'unknown example: {name}')
        if name in UNSUPPORTED:
            parser.error(f'{name}: requires {UNSUPPORTED[name]}')
        print(f'Building web/{name}', flush=True)
        sizes[name] = build(name, targets[name], args.wasm_opt)
    if not args.examples:
        print('Building reusable web/milktea engine', flush=True)
        build('milktea', {'sources': ['milktea/**', 'glaze/**', 'dye/**', 'tgp/**']}, args.wasm_opt, engine=True)
    # Keep previously built examples available when building just one target.
    available = [n for n in targets if n not in UNSUPPORTED and (OUT / f'{n}.wasm').exists()]
    manifest.write_text(json.dumps({'examples': available, 'unsupported': UNSUPPORTED,
                                   'sizes': sizes}, indent=2) + '\n')


if __name__ == '__main__':
    main()
