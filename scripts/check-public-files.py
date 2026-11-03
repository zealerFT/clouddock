#!/usr/bin/env python3
"""Check the public source file set without reading local app data or credentials."""
import argparse
from pathlib import Path, PurePosixPath
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SOURCE_ITEMS = [
    'Package.swift', 'version.json', 'README.md', 'README.zh-CN.md', 'LICENSE',
    'CHANGELOG.md', 'AGENTS.md', 'INSTALL.txt', 'THIRD_PARTY_NOTICES.txt',
    'requirements-qa.txt', '.gitignore', '.gitattributes', '.github',
    'Sources', 'Tests', 'scripts', 'docs/PUBLISHING.md', 'docs/DEVELOPMENT.md',
    'docs/assets', 'docs/screenshots', 'docs/releases',
]
PRIVATE_PARTS = {'.git', '.build', '.swiftpm', 'dist', 'vendor', 'ai-dev',
                 '.qa-venv', '.venv', '__pycache__', 'node_modules', 'Credentials'}
RULES = {
    'personal absolute path': re.compile(r'/(?:Users|home)/[A-Za-z0-9_.-]+/'),
    'cloud access key': re.compile(r'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b|\bLTAI[A-Za-z0-9]{16,}\b'),
    'GitHub token': re.compile(r'\bgh[pousr]_[A-Za-z0-9]{20,}\b|\bgithub_pat_[A-Za-z0-9_]{30,}\b'),
    'private key payload': re.compile(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----\s+[A-Za-z0-9+/=\s]{100,}'),
}


def public_paths():
    if (ROOT / '.git').exists():
        output = subprocess.check_output(['git', 'ls-files', '-z'], cwd=ROOT)
        return sorted(Path(p) for p in output.decode().split('\0') if p)
    paths = []
    for item in SOURCE_ITEMS:
        path = ROOT / item
        files = path.rglob('*') if path.is_dir() else [path]
        for file in files:
            if file.is_file() and not any(p in PRIVATE_PARTS for p in file.relative_to(ROOT).parts) and file.suffix != '.pyc' and file.name != '.DS_Store':
                paths.append(file.relative_to(ROOT))
    return sorted(paths)


def check(paths):
    failures = []
    if not paths:
        return ['No public files found; stage the intended source files first.']
    for relative in paths:
        path = ROOT / relative
        name = PurePosixPath(relative.as_posix()).name
        if (any(p in PRIVATE_PARTS for p in relative.parts)
                or name.startswith('.env') and name != '.env.example'
                or name in {'state.json', '.DS_Store'} or name.startswith('audit.jsonl')
                or path.suffix.lower() in {'.vault', '.key', '.pem', '.p12', '.p8', '.log', '.pyc'}
                or re.match(r'(?:service-account.*|.*-credentials)\.json$', name)):
            failures.append(f'{relative}: private or generated file')
            continue
        if path.is_symlink() or not path.is_file():
            failures.append(f'{relative}: missing file or symlink')
            continue
        data = path.read_bytes()
        try:
            content = data.decode('utf-8')
        except UnicodeDecodeError:
            if path.suffix.lower() != '.png':
                failures.append(f'{relative}: unexpected binary; review before publishing')
            continue
        for label, rule in RULES.items():
            for match in rule.finditer(content):
                line = content.count('\n', 0, match.start()) + 1
                failures.append(f'{relative}:{line}: {label}')
    return failures


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--list', action='store_true', help='Print checked relative paths for the source archive')
    args = parser.parse_args()
    paths = public_paths()
    failures = check(paths)
    if failures:
        raise SystemExit('\n'.join(failures))
    print('\n'.join(p.as_posix() for p in paths) if args.list else f'Public source checks passed ({len(paths)} files). Review intentional changes before publishing.')
