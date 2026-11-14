import base64
import os
from pathlib import Path
import plistlib
import re
import sys


def redact(text, secrets):
    for secret in sorted(secrets, key=len, reverse=True):
        if secret:
            text = text.replace(secret, '[REDACTED]')
    text = re.sub(r'-----BEGIN [^-]*PRIVATE KEY-----.*?-----END [^-]*PRIVATE KEY-----',
                  '[REDACTED PRIVATE KEY]', text, flags=re.DOTALL)
    text = re.sub(r'\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+', '[REDACTED JWT]', text)
    text = re.sub(r'(?i)\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]+', r'\1 [REDACTED]', text)
    return re.sub(r'(?im)((?:authorization|password|access.?token|session.?token|client.?secret)'
                  r'["\s:=]+)[^\n<]+', r'\1[REDACTED]', text)


def collect(destination):
    secrets = {os.environ.get(name, '') for name in ('ASC_KEY_ID', 'ASC_ISSUER_ID', 'ASC_KEY_P8')}
    key = Path(os.environ.get('KEY_PATH', '/nonexistent'))
    if key.is_file():
        pem = key.read_text()
        secrets.update((pem, base64.b64encode(pem.encode()).decode()))
        secrets.update(line for line in pem.splitlines() if len(line) > 20)
    roots = {Path(os.environ[name]) for name in ('TMPDIR', 'RUNNER_TEMP') if os.environ.get(name)}
    bundles = {bundle.resolve() for root in roots for bundle in root.glob('*.xcdistributionlogs')
               if bundle.is_dir() and not bundle.is_symlink()}
    count = skipped = 0
    for index, bundle in enumerate(sorted(bundles)):
        for source in bundle.rglob('*'):
            if source.is_symlink() or not source.is_file():
                continue
            data = source.read_bytes()
            try:
                text = plistlib.dumps(plistlib.loads(data)).decode() if data.startswith(b'bplist') else data.decode('utf-8-sig')
            except (UnicodeError, ValueError):
                skipped += 1
                continue
            relative = redact(str(source.relative_to(bundle)), secrets)
            target = destination / f'{index}.xcdistributionlogs' / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(redact(text, secrets))
            count += 1
    print(f'Collected {count} sanitized diagnostic files; omitted {skipped} non-text files.')


if __name__ == '__main__':
    collect(Path(sys.argv[1]))
