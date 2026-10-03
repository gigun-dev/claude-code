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
    # Native export failure must never publish a new page or advance its build number.
    asc = mocks / 'asc'
    asc.write_text('''#!/usr/bin/env python3
import json,os,sys,shutil
from pathlib import Path
args=sys.argv[1:]
with open(os.environ['OTA_ASC_CALLS'],'a') as log: log.write(json.dumps(args)+'\\n')
action=args[1]
if os.environ.get('OTA_ASC_FAIL')==action: sys.exit(1)
if action=='archive': Path(args[args.index('--archive-path')+1]).mkdir()
elif action=='export': shutil.copyfile(os.environ['OTA_ASC_IPA'],args[args.index('--ipa-path')+1])
else: sys.exit(2)
''')
    asc.chmod(0o755)
    native_env = dict(env, OTA_ASC_CALLS=str(root / 'asc-calls'), OTA_ASC_IPA=str(ipa))
    native = root / 'native.conf'
    native.write_text(conf.read_text().replace('APP_SLUG="fixture"', 'APP_SLUG="native"') +
                      'IOS_PROJECT="Project With Spaces.xcodeproj"\nIOS_SCHEME="Fixture"\n')
    run(['/bin/bash', str(SCRIPT), str(native), '--ios'], repo, native_env)
    import json
    calls = [json.loads(line) for line in (root / 'asc-calls').read_text().splitlines()]
    assert calls[0][calls[0].index('--project') + 1] == 'Project With Spaces.xcodeproj'
    assert calls[1][calls[1].index('--method') + 1] == 'release-testing'
    native_public = root / 'generated/public/native'
    assert (native_public / 'app.ipa').read_bytes() == ipa.read_bytes()
    saved_page = (native_public / 'index.html').read_bytes()
    serve_calls = (root / 'serve-calls').read_bytes()
    run(['/bin/bash', str(SCRIPT), str(native), '--ios'], repo,
        dict(native_env, OTA_ASC_FAIL='export'), success=False)
    assert (native_public / 'index.html').read_bytes() == saved_page
    assert (root / 'generated/state/native/build-number').read_text().strip() == '1'
    assert (root / 'serve-calls').read_bytes() == serve_calls
    print('PASS: prebuilt distribution; Cloudflare failure isolation; ASC Ad Hoc export and failure')
