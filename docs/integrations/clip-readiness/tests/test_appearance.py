"""Independent explicit-style contract, privacy and missing-original guard."""
import json
import pytest
from conftest import FakeJobClient
from test_stage2 import first_new_clip, logged, rerender_job, run

@pytest.mark.parametrize('style', ['plain', 'phrase-pop', 'karaoke'])
def test_appearance_explicit_style_wins_and_keeps_original_project(shim,state_dir,style):
    first_new_clip(shim,state_dir)
    n=len(shim.calls())
    job=rerender_job(appearance=True,base_render_id='render-base',candidate_id='c2bbbbbbbb',
        clip_overrides={'mapped':{'captions.style':style},'unmapped':[]})
    client=FakeJobClient(jobs=[job])
    assert run(client,state_dir)['status']=='done'
    calls=shim.calls()[n:]
    final=next(c['argv'] for c in calls if c['argv'][0]=='finalize')
    assert final[final.index('--captions')+1]==style
    assert '--regenerate' in final
    assert '--profile' in final
    assert not any(c['argv'][0]=='process' for c in calls)
    assert not any(c['argv'][:2]==['hooks','prepare-review'] for c in calls)
    assert all(c['env'].get('CLIP_NO_CONTENT')=='1' for c in calls)
    assert all('CLIP_RUNNER_TOKEN' not in c['env'] for c in calls)
    assert not list((shim.home/'profiles').glob('*-job-*'))
    assert 'secret transcript' not in json.dumps(client.named('complete'))

def test_appearance_missing_original_project_never_reprocesses_submitted_media(shim,state_dir):
    client=FakeJobClient(jobs=[rerender_job(appearance=True,clip_overrides={'mapped':{'captions.style':'plain'},'unmapped':[]})])
    assert run(client,state_dir)['status']=='failed'
    assert client.named('fail')[0][3]=='APPEARANCE_PROJECT_MISSING'
    assert not any(c['argv'][0] in ('process','finalize') for c in shim.calls())

def test_appearance_missing_exact_candidate_is_not_replaced_by_best_overlap(shim,state_dir):
    first_new_clip(shim,state_dir)
    job=rerender_job(appearance=True,candidate_id='missing',clip_overrides={'mapped':{'captions.style':'plain'},'unmapped':[]})
    client=FakeJobClient(jobs=[job])
    assert run(client,state_dir)['status']=='failed'
    assert client.named('fail')[0][3]=='BASE_CANDIDATE_MISSING'


def test_deleted_current_revision_uses_authoritative_next_revision(shim, state_dir):
    first_new_clip(shim, state_dir)
    job = rerender_job(expected_rev=3, appearance=True, candidate_id='c2bbbbbbbb', clip_overrides={'mapped': {'captions.style': 'plain'}, 'unmapped': []})
    context = {'clip_rev': 1, 'clip_next_rev': 3, 'project_id': 'project-files-1'}
    assert run(FakeJobClient(jobs=[job]), state_dir, context_for=lambda r, j: context)['status'] == 'done'
    stale = rerender_job(expected_rev=2, appearance=True)
    assert run(FakeJobClient(jobs=[stale]), state_dir, context_for=lambda r, j: context)['code'] == 'REV_MISMATCH'
