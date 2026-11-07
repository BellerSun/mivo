#!/usr/bin/env python3
"""Exercise PKCS#12 export without touching the user's Keychain or identity."""
from pathlib import Path
import runpy
import secrets
import shutil
import tempfile

setup = runpy.run_path(str(Path(__file__).with_name('setup-signing.py')))
run = setup['run']
tools = {str(Path(tool).resolve()) for tool in ['/usr/bin/openssl', shutil.which('openssl')] if tool}
for tool in sorted(tools):
    with tempfile.TemporaryDirectory(prefix='mivo-signing-tools-') as folder:
        temp = Path(folder)
        temp.chmod(0o700)
        password = secrets.token_urlsafe(48)
        (temp / 'password').write_text(password + '\n' + password + '\n')
        run([tool, 'req', '-new', '-x509', '-newkey', 'rsa:2048', '-sha256', '-days', '1',
             '-subj', '/CN=Mivo Disposable Export Test', '-keyout', str(temp / 'key.pem'),
             '-out', str(temp / 'cert.pem'), '-passout', f'file:{temp / "password"}'])
        setup['export_identity'](tool, temp)
        # Check integrity and read back with every available implementation.
        for reader in sorted(tools):
            run([reader, 'pkcs12', '-in', str(temp / 'identity.p12'), '-info', '-noout',
                 '-passin', f'file:{temp / "password"}'])
        print(f'PASS: PKCS#12 export and cross-reader validation: {tool}')
