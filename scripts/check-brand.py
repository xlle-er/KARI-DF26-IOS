#!/usr/bin/env python3
"""Reject former project branding in publishable source and file names."""
from pathlib import Path
import subprocess
root = Path(__file__).resolve().parents[1]
result = subprocess.run(['git', '-C', str(root), 'ls-files', '-z'], capture_output=True)
assert result.returncode == 0, 'Run in a Git checkout after staging publishable sources'
former = bytes([108, 111, 111, 105])
patterns = [former, former.decode().encode('utf-16le'), former.decode().encode('utf-16be')]
issues = []
paths = [Path(p) for p in result.stdout.decode().split('\0') if p]
assert paths, 'No indexed files: refusing an empty scan'
for relative in paths:
    path = root / relative
    if former in str(relative).lower().encode(): issues.append(str(relative) + ': filename')
    if path.is_file() and any(p in path.read_bytes().lower() for p in patterns): issues.append(str(relative) + ': content')
assert not issues, '\n'.join(issues)
print(f'PASS: {len(paths)} publishable files and paths contain only current branding')
