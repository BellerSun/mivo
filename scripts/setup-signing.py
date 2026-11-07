#!/usr/bin/env python3
"""Create a persistent, local-only code-signing identity; never regenerate it implicitly."""
import hashlib
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import sys
import tempfile

NAME = 'Mivo Local Development'
CONFIG_DIR = Path.home() / '.config/mivo'
CONFIG = CONFIG_DIR / 'signing.json'
KEYCHAIN = Path.home() / 'Library/Keychains/login.keychain-db'


def run(args, *, data=None):
    result = subprocess.run(args, input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise RuntimeError(f'{Path(args[0]).name} failed: {result.stderr.decode(errors="replace").strip()}')
    return result.stdout


def export_identity(openssl, temp):
    # Explicit PKCS#12 algorithms work in both LibreSSL and OpenSSL 3,
    # without OpenSSL 3's -legacy option or its legacy provider.
    run([openssl, 'pkcs12', '-export', '-keypbe', 'PBE-SHA1-3DES',
         '-certpbe', 'PBE-SHA1-3DES', '-macalg', 'sha1', '-name', NAME,
         '-inkey', str(temp / 'key.pem'), '-in', str(temp / 'cert.pem'),
         '-passin', f'file:{temp / "password"}', '-passout', f'file:{temp / "password"}',
         '-out', str(temp / 'identity.p12')])


def main():
    os.umask(0o077)
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    openssl = shutil.which('openssl')
    if not openssl:
        raise RuntimeError('OpenSSL or system LibreSSL is required to configure local signing.')
    if CONFIG.exists():
        config = json.loads(CONFIG.read_text())
        print('Existing signing identity preserved:', config['identity'])
        return
    # Do not create another identity if setup stopped after importing the original.
    existing = subprocess.run(['security', 'find-certificate', '-c', NAME, '-p', str(KEYCHAIN)],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if existing.returncode not in (0, 44):
        raise RuntimeError('Cannot inspect the login keychain. Unlock it before setting up signing; no replacement identity was created.')
    if existing.returncode == 0:
        cert_pem = existing.stdout
        print('Reusing existing certificate from the login keychain.')
    else:
        with tempfile.TemporaryDirectory(prefix='mivo-signing-') as folder:
            temp = Path(folder)
            password = secrets.token_urlsafe(48)
            (temp / 'password').write_text(password + '\n' + password + '\n')
            (temp / 'openssl.cnf').write_text('''[req]
prompt = no
distinguished_name = dn
x509_extensions = codesign
[dn]
CN = Mivo Local Development
[codesign]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid
''')
            run([openssl, 'req', '-new', '-x509', '-newkey', 'rsa:3072', '-sha256', '-days', '3650',
                 '-keyout', str(temp / 'key.pem'), '-out', str(temp / 'cert.pem'),
                 '-passout', f'file:{temp / "password"}', '-config', str(temp / 'openssl.cnf')])
            export_identity(openssl, temp)
            run(['security', 'import', str(temp / 'identity.p12'), '-k', str(KEYCHAIN),
                 '-f', 'pkcs12', '-P', password, '-T', '/usr/bin/codesign'])
            cert_pem = (temp / 'cert.pem').read_bytes()
        print('Private key imported into the login keychain; temporary private files removed.')
    cert_der = run([openssl, 'x509', '-outform', 'DER'], data=cert_pem)
    identity = hashlib.sha1(cert_der).hexdigest().upper()
    certificate = CONFIG_DIR / 'signing-public.pem'
    certificate.write_bytes(cert_pem)
    config = {'identity': identity, 'keychain': str(KEYCHAIN), 'name': NAME,
              'certificate': str(certificate), 'scope': 'local-development'}
    # Public metadata only. No private key or password is persisted outside Keychain.
    CONFIG.write_text(json.dumps(config, indent=2) + '\n')
    print('Signing identity:', identity)
    print('Configuration:', CONFIG)
    print('No system trust settings were changed.')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
