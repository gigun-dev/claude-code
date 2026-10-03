#!/usr/bin/env python3
"""Publish immutable artifacts before switching the authenticated latest page."""
import hashlib,json,os,plistlib,subprocess,sys,tempfile,urllib.request,zipfile
from datetime import datetime,timezone
from pathlib import Path

HERE=Path(__file__).resolve().parent

def command(args,**kwargs):
    result=subprocess.run(args,cwd=HERE,capture_output=True,**kwargs)
    if result.returncode:
        raise RuntimeError(f'{args[0]} failed (exit {result.returncode})')
    return result.stdout

def notify(info,url):
    secret_path=os.environ.get('BARK_ENV_FILE')
    if not secret_path:return
    raw=command(['age','-d','-i',(os.environ.get('BARK_IDENTITY') or str(Path.home()/'.ssh/id_ed25519')),secret_path]).decode()
    secrets=dict(line.split('=',1) for line in raw.splitlines() if '=' in line and not line.startswith('#'))
    key,iv=secrets['BARK_ENCRYPT_KEY'],secrets['BARK_ENCRYPT_IV']
    route=secrets.get('BARK_PUSH_URL') or 'https://api.day.app/'+secrets['BARK_DEVICE_KEY']
    if not route.startswith('https://'):raise RuntimeError('Bark requires HTTPS')
    target=url.replace('https://','x-safari-https://',1) if info['ios'] else url
    payload=json.dumps({'title':f"{info['name']} 検証版 {info['version']}",'body':info['message']+'\n'+url,'url':target,'group':'ota-deploy','isArchive':'1'},ensure_ascii=False).encode()
    cipher=command(['openssl','enc','-aes-256-cbc','-K',key.encode().hex(),'-iv',iv.encode().hex(),'-base64','-A'],input=payload).decode()
    body=json.dumps({'ciphertext':cipher,'iv':iv}).encode()
    req=urllib.request.Request(route,data=body,headers={'Content-Type':'application/json','User-Agent':'Mozilla/5.0 (compatible; ota-deploy/0.2)'})
    with urllib.request.urlopen(req,timeout=20) as response:result=json.load(response)
    if result.get('code')!=200:raise RuntimeError('Bark did not accept the notification')
    print('Bark accepted the distribution notification (device delivery remains to be confirmed)')

def publish():
    origin=os.environ['OTA_PUBLIC_ORIGIN'].rstrip('/')
    if not origin.startswith('https://') or '/' in origin[8:]:raise RuntimeError('OTA_PUBLIC_ORIGIN must be an HTTPS origin')
    slug=os.environ['APP_SLUG']
    if not slug or any(c not in 'abcdefghijklmnopqrstuvwxyz0123456789-' for c in slug):raise RuntimeError('Invalid APP_SLUG')
    public=Path(sys.argv[1]);files=[f for platform,f in [('ios','app.ipa'),('android','app.apk')] if platform in os.environ['BUILT'].split() and (public/f).exists()]
    if not files:raise RuntimeError('No artifacts')
    digest=hashlib.sha256()
    for name in files:digest.update(name.encode());digest.update((public/name).read_bytes())
    release=digest.hexdigest()
    info={'slug':slug,'name':os.environ['APP_NAME'],'version':os.environ['BUILD'],'bundleId':os.environ.get('IOS_BUNDLE_ID',''),'release':release,'ios':'app.ipa' in files,'android':'app.apk' in files,'publishedAt':datetime.now(timezone.utc).isoformat(),'message':os.environ.get('OTA_MESSAGE','')}
    if info['ios']:
        with zipfile.ZipFile(public/'app.ipa') as z:
            path=next(n for n in z.namelist() if n.count('/')==2 and n.endswith('.app/Info.plist'))
            p=plistlib.loads(z.read(path));info['version']=str(p['CFBundleVersion']);info['bundleId']=p['CFBundleIdentifier']
    bucket=os.environ.get('OTA_R2_BUCKET','ota-distribution')
    def upload(path,key):
        command(['bunx','--no-install','wrangler','--config',os.environ['OTA_WRANGLER_CONFIG'],'r2','object','put',f'{bucket}/{key}','--file',str(path),'--remote'])
    prefix=f'{slug}/releases/{release}'
    for name in files:upload(public/name,f'{prefix}/{name}')
    with tempfile.TemporaryDirectory(prefix='ota-release-') as tmp:
        metadata=Path(tmp)/'release.json';metadata.write_text(json.dumps(info,ensure_ascii=False))
        upload(metadata,f'{prefix}/release.json')
        upload(metadata,f'{slug}/latest.json')
    url=f'{origin}/{slug}/'
    print('Published '+url)
    try:notify(info,url)
    except Exception:
        print("Build published, but Bark notification failed",file=sys.stderr)
        sys.exit(2)

if __name__=='__main__':
    try:publish()
    except Exception as e:
        # HTTP errors can contain secret route URLs. Report only the failure class.
        print('Cloudflare publication/notification failed: '+type(e).__name__,file=sys.stderr)
        sys.exit(1)
