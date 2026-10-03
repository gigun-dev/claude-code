import importlib.util,json,os,tempfile,unittest
from pathlib import Path
from unittest.mock import patch
spec=importlib.util.spec_from_file_location('publish',Path(__file__).with_name('publish.py'));module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
class Publication(unittest.TestCase):
 def test_stale_ipa_is_not_published_and_latest_is_last(self):
  with tempfile.TemporaryDirectory() as tmp:
   p=Path(tmp);(p/'app.apk').write_bytes(b'apk');(p/'app.ipa').write_bytes(b'stale ipa')
   env={'OTA_PUBLIC_ORIGIN':'https://ota.example.invalid','APP_SLUG':'test','APP_NAME':'Test','BUILD':'2','BUILT':'android','OTA_WRANGLER_CONFIG':'fixture.json'}
   calls=[]
   with patch.dict(os.environ,env),patch('sys.argv',['publish',tmp]),patch.object(module,'command',side_effect=lambda args,**kwargs:calls.append(args)),patch.object(module,'notify'):
    module.publish()
   self.assertEqual(len(calls),3);self.assertTrue(calls[-1][8].endswith('/latest.json'))
   self.assertFalse(any('/app.ipa' in ' '.join(a) for a in calls))
 def test_upload_failure_never_updates_latest_or_notifies(self):
  with tempfile.TemporaryDirectory() as tmp:
   (Path(tmp)/'app.apk').write_bytes(b'apk')
   env={'OTA_PUBLIC_ORIGIN':'https://ota.example.invalid','APP_SLUG':'test','APP_NAME':'Test','BUILD':'2','BUILT':'android','OTA_WRANGLER_CONFIG':'fixture.json'}
   with patch.dict(os.environ,env),patch('sys.argv',['publish',tmp]),patch.object(module,'command',side_effect=RuntimeError('upload failed')),patch.object(module,'notify') as notify:
    with self.assertRaises(RuntimeError):module.publish()
    notify.assert_not_called()
if __name__=='__main__':unittest.main()
