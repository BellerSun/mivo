#!/usr/bin/env python3
"""Read pinned public signing metadata. Never generate or fall back to ad-hoc signing."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

try:
    config_path = Path.home() / '.config/mivo/signing.json'
    config = json.loads(config_path.read_text())
    if not config.get('identity') or not config.get('keychain'):
        raise ValueError('Signing metadata is incomplete.')
    certificate = Path(config['certificate'])
    der = subprocess.run(['openssl', 'x509', '-in', str(certificate), '-outform', 'DER'],
                         check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout
    if hashlib.sha1(der).hexdigest().upper() != config['identity'].upper():
        raise ValueError('Certificate fingerprint does not match pinned identity.')
    field = sys.argv[1]
    if field not in ('identity', 'keychain'):
        raise ValueError('Unsupported metadata field.')
    print(config[field])
except Exception:
    print('Mivo signing identity is missing or invalid. Run ./scripts/setup-signing.py. '
          'The existing identity must be preserved; ad-hoc fallback is disabled.', file=sys.stderr)
    sys.exit(1)
