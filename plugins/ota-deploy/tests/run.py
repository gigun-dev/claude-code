#!/usr/bin/env python3
"""Exercise the packaged CLI without building apps or changing Tailscale Serve."""
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile

PLUGIN = Path(__file__).resolve().parents[1]
SCRIPT = PLUGIN / 'bin/ota-deploy.sh'


def run(args, cwd, env, success=True):
    result = subprocess.run(args, cwd=cwd, env=env, text=True, capture_output=True, timeout=20)
    assert (result.returncode == 0) == success, result.stdout + result.stderr
    return result


with tempfile.TemporaryDirectory(prefix='ota-deploy-test-') as directory:
    root = Path(directory)
    mocks = root / 'mocks'
    mocks.mkdir()
    for name, content in {
        'curl': '#!/bin/sh\nexit 0\n',
        'tailscale': '#!/bin/sh\nprintf "%s\\n" "$*" >> "$OTA_TEST_CALLS"\n',
    }.items():
        file = mocks / name
        file.write_text(content)
        file.chmod(0o755)
    env = dict(os.environ, PATH=str(mocks) + ':' + os.environ['PATH'],
               OTA_HOME=str(root / 'generated'), OTA_TEST_CALLS=str(root / 'serve-calls'),
               GIT_AUTHOR_NAME='Fixture', GIT_AUTHOR_EMAIL='fixture@example.invalid',
               GIT_COMMITTER_NAME='Fixture', GIT_COMMITTER_EMAIL='fixture@example.invalid')
    missing = run(['bash', str(SCRIPT), str(root / 'missing.conf')], root, env, success=False)
    assert 'config not found' in missing.stderr
    assert not (root / 'generated').exists()

    repo = root / 'fixture-repo'
    repo.mkdir()
    run(['git', 'init', '-q'], repo, env)
    run(['git', 'commit', '-qm', 'Initial fixture', '--allow-empty'], repo, env)
    apk = root / 'fixture.apk'
    ipa = root / 'fixture.ipa'
    apk.write_bytes(b'fixture apk; not an installable app')
    ipa.write_bytes(b'fixture ipa; not an installable app')
    conf = root / 'fixture.conf'
    conf.write_text(f'''APP_NAME="Fixture App"
APP_SLUG="fixture"
PLATFORMS="android"
TS_HOST="fixture.example.ts.net"
PORT="18787"
IOS_BUNDLE_ID="dev.example.fixture"
GIT_REPO="{repo}"
''')
    run(['bash', str(SCRIPT), str(conf), '--apk', str(apk)], repo, env)
    public = root / 'generated/public/fixture'
    state = root / 'generated/state/fixture'
    assert (public / 'app.apk').read_bytes() == apk.read_bytes()
    page = (public / 'index.html').read_text()
    assert 'Download for Android' in page and 'Install on iPhone' not in page
    assert '{{' not in page
    assert 'Initial fixture' in page

    run(['git', 'commit', '-qm', 'Fix <card> & input', '--allow-empty'], repo, env)
    run(['bash', str(SCRIPT), str(conf), '--apk', str(apk)], repo, env)
    assert (state / 'build-number').read_text().strip() == '2'
    assert 'Fix &lt;card&gt; &amp; input' in (public / 'index.html').read_text()
    assert len((state / 'builds.tsv').read_text().splitlines()) == 2

    ios_conf = root / 'ios.conf'
    ios_conf.write_text(conf.read_text().replace('APP_SLUG="fixture"', 'APP_SLUG="ios-fixture"'))
    run(['bash', str(SCRIPT), str(ios_conf), '--ios', '--ipa', str(ipa)], repo, env)
    ios_public = root / 'generated/public/ios-fixture'
    assert (ios_public / 'app.ipa').read_bytes() == ipa.read_bytes()
    manifest = plistlib.loads((ios_public / 'manifest.plist').read_bytes())['items'][0]
    assert manifest['metadata']['bundle-identifier'] == 'dev.example.fixture'
    assert manifest['assets'][0]['url'] == 'https://fixture.example.ts.net/ios-fixture/app.ipa'
    assert 'itms-services://' in (ios_public / 'index.html').read_text()
    assert not (ios_public / 'app.apk').exists()
    assert (state / 'build-number').read_text().strip() == '2'

    before = (state / 'builds.tsv').read_bytes()
    run(['bash', str(SCRIPT), str(conf), '--serve-only'], repo, env)
    assert (state / 'builds.tsv').read_bytes() == before
    assert (root / 'serve-calls').read_text().splitlines() == ['serve --bg 18787'] * 4
    # A failed cloud upload must preserve the working local distribution and history.
    python = mocks / 'python3'
    import shutil
    python.write_text('#!/bin/sh\ncase "$1" in *cloudflare/publish.py) exit 1;; esac\nexec ' + shutil.which('python3') + ' "$@"\n')
    python.chmod(0o755)
    cloud = root / 'cloud.conf'
    cloud.write_text(conf.read_text() + 'OTA_PUBLIC_ORIGIN="https://install.example.invalid"\n')
    old_page = (public / 'index.html').read_bytes()
    run(['bash', str(SCRIPT), str(cloud), '--apk', str(apk)], repo, env, success=False)
    assert (public / 'index.html').read_bytes() == old_page
    assert (state / 'builds.tsv').read_bytes() == before
    assert (state / 'cloudflare-public/app.apk').read_bytes() == apk.read_bytes()
    print('PASS: missing config; APK/page; incremental changelog; isolated IPA/manifest; serve-only')
