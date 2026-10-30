"""Exact persisted song/gain, private download and cleanup on every path."""
import json,http.server,threading
from pathlib import Path
import pytest
from conftest import FakeJobClient
from test_stage2 import first_new_clip,rerender_job,run

@pytest.fixture
def song_server():
 class Handler(http.server.BaseHTTPRequestHandler):
  def do_GET(self):
   self.send_response(200);self.end_headers();self.wfile.write(b'RIFF0000WAVEtest-audio')
  def log_message(self,*a):pass
 server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
 threading.Thread(target=server.serve_forever,daemon=True).start()
 yield 'http://127.0.0.1:'+str(server.server_address[1])+'/signed-secret-token'
 server.shutdown();server.server_close()

def music_job(enabled=True,gain=-18):
 return rerender_job(appearance=True,candidate_id='c2bbbbbbbb',
   music={'enabled':enabled,'file_id':'song-id','level_db':gain},
   clip_overrides={'mapped':{'captions.style':'plain'},'unmapped':[]})

def client_for(job,url):
 c=FakeJobClient(jobs=[job]);c.replies['social_clip_job_source']={'file_id':'song-id','project_id':'project-files-1','url':url,'content_type':'audio/wav','byte_size':22}
 return c

@pytest.mark.parametrize('gain',[-60,-18,0])
def test_exact_music_profile_private_download_and_cleanup(shim,state_dir,song_server,gain,monkeypatch):
 first_new_clip(shim,state_dir)
 c=client_for(music_job(gain=gain),song_server)
 # correct byte size is checked independently against the actual HTTP fixture.
 c.replies['social_clip_job_source']['byte_size']=len(b'RIFF0000WAVEtest-audio')
 for key in ('BURROW_TOKEN','BURROW_API_TOKEN','CF_ACCESS_CLIENT_ID','CF_ACCESS_CLIENT_SECRET'):
  monkeypatch.setenv(key,'secret-burrow-token')
 result=run(c,state_dir)
 assert result['status']=='done'
 imports=[x for x in shim.calls() if x['argv'][:2]==['profile','import']]
 text=imports[-1]['imported']
 assert '[music]' in text and 'enabled = true' in text and f'level_db = {gain}' in text
 assert 'audio.target_lufs' not in text
 assert 'track.audio' in text
 assert not list(state_dir.rglob('track.audio')) and not list(state_dir.rglob('track.part'))
 assert not list((shim.home/'profiles').glob('*-job-*'))
 assert c.named('request')[0][1:] == ('social_clip_job_source',{'job_id':'job-02','asset':'music'})
 for path in state_dir.rglob('*.json'):
  assert 'signed-secret-token' not in path.read_text() and 'secret-burrow-token' not in path.read_text()
 assert 'signed-secret-token' not in json.dumps(shim.calls())
 assert all(not any(k.startswith(('BURROW_','CF_ACCESS_')) for k in x['env']) for x in shim.calls())

@pytest.mark.parametrize('change,code',[
 ({'file_id':'foreign'},'MUSIC_ASSET_INVALID'),
 ({'project_id':'foreign'},'MUSIC_ASSET_INVALID'),
 ({'content_type':'video/mp4'},'MUSIC_ASSET_INVALID'),
 ({'byte_size':999999999},'MUSIC_ASSET_INVALID'),
 ({'byte_size':3},'MUSIC_DOWNLOAD_SIZE'),
 ({'url':'file:///etc/passwd'},'MUSIC_URL_INVALID'),
 ({'url':'http://127.0.0.1:1/private-token'},'MUSIC_DOWNLOAD_FAILED'),
])
def test_bad_asset_and_download_fail_safely(shim,state_dir,song_server,change,code):
 first_new_clip(shim,state_dir)
 c=client_for(music_job(),song_server);c.replies['social_clip_job_source'].update(change)
 r=run(c,state_dir)
 assert r['status']=='failed' and r['code']==code
 assert not list(state_dir.rglob('track.audio')) and not list(state_dir.rglob('track.part'))
 assert not list((shim.home/'profiles').glob('*-job-*'))
 assert 'private-token' not in json.dumps(c.named('fail'))

def test_mute_preserves_gain_without_downloading_and_unsupported_cli_fails(shim,state_dir,song_server,monkeypatch):
 first_new_clip(shim,state_dir)
 c=client_for(music_job(False,-42),song_server)
 assert run(c,state_dir)['status']=='done'
 assert not c.named('request')
 assert 'enabled = false' in [x for x in shim.calls() if x['argv'][:2]==['profile','import']][-1]['imported']
 monkeypatch.setenv('FAKE_MUSIC_ENABLED','cloud')
 c=client_for(music_job(),song_server)
 assert run(c,state_dir)['code']=='MUSIC_CLI_UNSUPPORTED'
 assert not c.named('request')

def test_render_failure_cleans_music_and_profile(shim,state_dir,song_server):
 first_new_clip(shim,state_dir)
 shim.script(finalize={'exit':1})
 c=client_for(music_job(),song_server);c.replies['social_clip_job_source']['byte_size']=len(b'RIFF0000WAVEtest-audio')
 assert run(c,state_dir)['status']=='failed'
 assert not list(state_dir.rglob('track.audio')) and not list((shim.home/'profiles').glob('*-job-*'))
