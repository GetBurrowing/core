"""Isolated render boundary test: seeded transcript/proposal, real CLI/ffmpeg, real helper edit."""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--helper', required=True, type=Path, help='Canonical skill helper extracted byte-for-byte')
parser.add_argument('--clip', required=True, type=Path, help='Compatible installed clip binary')
parser.add_argument('--output', required=True, type=Path, help='Private fixture/evidence directory')
args = parser.parse_args()
ROOT = args.helper.resolve().parent
sys.path.insert(0, str(ROOT))
import clip_runner

D = args.output.resolve()
D.mkdir(exist_ok=True)
os.environ['CLIP_AGENT_HOME'] = str(D / 'tool-home')
os.environ['CLIP_NO_CONTENT'] = '1'
from clip_agent.config import load_config
from clip_agent.manifest import Candidate, ProjectManifest, SourceInfo, save_manifest

BIN = str(args.clip.resolve())

def cli(*args):
    p = subprocess.run([BIN, *map(str,args)],capture_output=True,text=True)
    (D/'cli-log.jsonl').open('a').write(json.dumps({'args':list(map(str,args)),'exit':p.returncode,'stdout':p.stdout})+'\n')
    if p.returncode:
        raise RuntimeError(f'CLI failed {args[0]} exit={p.returncode}; see local log')
    return p.stdout

source = D/'source.mp4'
subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-y','-f','lavfi','-i','color=c=0x202020:s=360x640:r=30:d=5',
                '-f','lavfi','-i','sine=frequency=440:duration=5','-c:v','libx264','-pix_fmt','yuv420p','-c:a','aac','-shortest',str(source)],check=True)
profile = D/'fixture-profile.toml'
profile.write_text('extends = "how-to-computer"\n[brain]\nbackend="ollama"\n[privacy]\nmode = "local"\n[reframe]\nmode="off"\nwidth=360\nheight=640\n[editing]\npunch="off"\n[captions]\nstyle="phrase-pop"\nhook_title=true\nsize_frac=0.05\n[output]\nrequire_approval=true\n[publish]\nenabled=false\n')
cli('profile','import',profile,'--name','burrow-fixture','--force','--yes')
cfg=load_config(profile='burrow-fixture')
project=D/'project'
(project/'candidates').mkdir(parents=True,exist_ok=True)
shutil.copy2(source,project/'candidates/01_fixture.mp4')
text='We shipped the app and the team celebrated'
tokens=[{'text':' '+word,'offsets':{'from':int(i*500),'to':int(i*500+450)},'p':1.0} for i,word in enumerate(text.split())]
(project/'fixture.json').write_text(json.dumps({'transcription':[{'text':text,'offsets':{'from':0,'to':4500},'tokens':tokens}]}))
c=Candidate(id='abc123',rank=1,start=0,end=5,title='We shipped the app',titles=['We shipped the app'],filename='01_fixture.mp4',status='cut',cut_fingerprint='fixture-cut')
m=ProjectManifest(name='project',source=SourceInfo(path=str(source),fingerprint=hashlib.sha256(source.read_bytes()).hexdigest(),probe={'duration':5.0,'fps':30.0}),config_resolved=cfg.model_dump(mode='json'),transcript_cache_key='fixture',caption_style='none',candidates=[c])
save_manifest(project,m)
cli('review',project,'--overwrite','--profile','burrow-fixture')
p=project/'review.toml';p.write_text(p.read_text().replace('decision = "pending"','decision = "approve"'))
cli('review',project,'--apply','--profile','burrow-fixture')
cli('finalize',project,'--profile','burrow-fixture','--captions','phrase-pop','--regenerate')
video=project/'final/01_fixture.mp4'
assert video.exists(), 'initial output missing'
shutil.copy2(video,D/'before.mp4')
class Client:
    def progress(self,*a,**k):pass
job={'id':'fixture-edit','kind':'rerender','clip_id':'fixture-clip','profile_id':'fixture-profile',
     'payload':{'clip_user_profile':'burrow-fixture','candidate_id':'abc123','source_id':'fixture-source','in_s':0.,'out_s':5.,
                'base_render_id':'fixture-render-1','headline':{'consumer':'edit','requested_headline':'The team celebrated'}}}
r=clip_runner.Runner(Client(),state_dir=D/'runner',clip_bin=BIN,uploader=lambda *a:'fixture-file',install_signal_handlers=False)
r._job=job
r.context={'base_render_id':'fixture-render-1','headline_voice':{'revision':'fixture-8','direction':'Comedy and positivity; remaining voice rules incomplete.'}}
r.headline_capability=json.loads(cli('version','--json'))['headline_review']==1
r.project_path=str(project)
result=clip_runner._render(r,job,project,'abc123',regenerate=True)
assert result['file_id']=='fixture-file'
shutil.copy2(video,D/'after.mp4')
for name in ['before','after']:
    subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-y','-ss','1','-i',str(D/f'{name}.mp4'),'-frames:v','1',str(D/f'{name}.png')],check=True)
from PIL import Image, ImageChops

before=Image.open(D/'before.png').convert('RGB');after=Image.open(D/'after.png').convert('RGB')
# Caption/body remains constant; only the top headline region should change.
top=(0,0,360,230)
assert ImageChops.difference(before.crop(top),after.crop(top)).getbbox() is not None
assert ImageChops.difference(before.crop((0,300,360,640)),after.crop((0,300,360,640))).getbbox() is None
assert not list((D/'tool-home/profiles').glob('*-job-*'))
assert not list((D/'runner/tmp').glob('headline-request*'))
print(json.dumps({'real_cli':json.loads(cli('version','--json'))['version'],'before_sha256':hashlib.sha256((D/'before.mp4').read_bytes()).hexdigest(),'after_sha256':hashlib.sha256((D/'after.mp4').read_bytes()).hexdigest(),'changed_headline_pixels':True,'unchanged_lower_region':True,'result':result},sort_keys=True))
