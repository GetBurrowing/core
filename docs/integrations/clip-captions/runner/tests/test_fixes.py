import tomllib

import pytest
from conftest import FakeJobClient
from test_stage2 import first_new_clip, logged, rerender_job, run

import clip_runner


@pytest.mark.parametrize('edge,delta,a,b', [('start',-1,304,340),('start',1,306,340),('end',-1,305,339),('end',1,305,341)])
def test_nudge(shim,state_dir,edge,delta,a,b):
    first_new_clip(shim,state_dir)
    client=FakeJobClient(jobs=[rerender_job(in_s=a,out_s=b,fix={'operation':'nudge','edge':edge,'delta_s':delta})])
    assert run(client,state_dir)['status']=='done'
    applied=tomllib.loads(logged(shim,'applied')[-1]['applied'])
    target=next(c for c in applied['clip'] if c['id']=='c2bbbbbbbb')
    assert (target['start'],target['end'])==(a,b)
    result=client.named('complete')[0][2]
    assert (result['actual_in_s'],result['actual_out_s'])==(a,b)
    assert target['packaging']=='bbbbbbbbbbbbbbbb'
    assert target['captions']=='2222222222222222'


def test_caption_one_position_only_and_local_privacy(shim,state_dir,monkeypatch):
    monkeypatch.setenv('FAKE_PRIVACY','local')
    monkeypatch.setenv('CLIP_RUNNER_TOKEN','secret-agent-token')
    first_new_clip(shim,state_dir)
    client=FakeJobClient(jobs=[rerender_job(in_s=305,out_s=340,fix={'operation':'caption_word','caption_fixes':{'position':2,'original':'words','replacement':'terms'}})])
    assert run(client,state_dir)['status']=='done'
    text=logged(shim,'applied')[-1]['applied']
    rows=tomllib.loads(text)['clip']
    assert rows[1]['transcript']=='secret transcript terms two'
    assert 'transcript' not in rows[0]
    assert all(c['env'].get('CLIP_NO_CONTENT')=='1' for c in shim.calls())
    assert all('CLIP_RUNNER_TOKEN' not in c['env'] for c in shim.calls())
    result=client.named('complete')[0][2]
    assert all(result[k] is None for k in clip_runner.META_KEYS)
    assert 'secret transcript' not in str(result)


def test_stale_word_no_apply_or_complete(shim,state_dir):
    first_new_clip(shim,state_dir)
    before=len(logged(shim,'applied'))
    client=FakeJobClient(jobs=[rerender_job(fix={'operation':'caption_word','caption_fixes':{'position':2,'original':'wrong','replacement':'terms'}})])
    assert run(client,state_dir)['code']=='STALE_CAPTION_WORD'
    assert len(logged(shim,'applied'))==before
    assert not client.named('complete')


def test_alternate_is_promoted_then_cut_before_finalize(shim,state_dir):
    first_new_clip(shim,state_dir)
    before=len(shim.argvs())
    client=FakeJobClient(jobs=[rerender_job(fix={'operation':'alternate_cut'})])
    assert run(client,state_dir)['status']=='done'
    calls=shim.argvs()[before:]
    apply=next(i for i,a in enumerate(calls) if a[0]=='review' and '--apply' in a)
    process=next(i for i,a in enumerate(calls) if a[0]=='process')
    final=next(i for i,a in enumerate(calls) if a[0]=='finalize')
    assert apply<process<final
    assert '--resume' in calls[process]
    result=client.named('complete')[0][2]
    assert result['candidate_id']==result['alternate_id']=='a1dddddddd'
    assert (result['actual_in_s'],result['actual_out_s'])==(10,40)


def test_missing_headline_hook_is_actionable_failure_not_intent_success(shim,state_dir):
    first_new_clip(shim,state_dir)
    import os
    os.environ["FAKE_HEADLINE_CAPABILITY"]="0"
    client=FakeJobClient(jobs=[rerender_job(base_render_id='base-1',fix={'operation':'regenerate_headline'})])
    assert run(client,state_dir)['code']=='HEADLINE_CLI_UNSUPPORTED'
    assert not client.named('complete')
    os.environ.pop('FAKE_HEADLINE_CAPABILITY',None)


def test_missing_review_contract_rejected(shim,state_dir):
    from fake_clip import REVIEW_FIXTURE
    review=clip_runner.ReviewFile(REVIEW_FIXTURE)
    entry=review.by_id('c2bbbbbbbb')
    with pytest.raises(ValueError):
        review.set_fields(entry,captions='fake-hash')


def test_caption_truncated_excerpt_fails_before_apply(shim,state_dir,monkeypatch):
    first_new_clip(shim,state_dir)
    original=clip_runner.ReviewFile
    class Truncated(original):
        def __init__(self,text):
            super().__init__(text)
            self.by_id('c2bbbbbbbb').fields['said']='secret transcript…'
    monkeypatch.setattr(clip_runner,'ReviewFile',Truncated)
    client=FakeJobClient(jobs=[rerender_job(fix={'operation':'caption_word','caption_fixes':{'position':0,'original':'secret','replacement':'public'}})])
    assert run(client,state_dir)['code']=='CAPTION_CONTRACT_UNSUPPORTED'
    assert not client.named('complete')


def test_missing_base_hash_fails_before_apply(shim,state_dir,monkeypatch):
    first_new_clip(shim,state_dir)
    original=clip_runner.ReviewFile
    class OldContract(original):
        def __init__(self,text):
            super().__init__(text)
            self.by_id('c2bbbbbbbb').fields.pop('packaging',None)
    monkeypatch.setattr(clip_runner,'ReviewFile',OldContract)
    client=FakeJobClient(jobs=[rerender_job(fix={'operation':'nudge'})])
    assert run(client,state_dir)['code']=='REVIEW_CONTRACT_UNSUPPORTED'
    assert not client.named('complete')


def test_base_candidate_is_never_silently_substituted(shim,state_dir):
    first_new_clip(shim,state_dir)
    client=FakeJobClient(jobs=[rerender_job(candidate_id='missing',fix={'operation':'nudge'})])
    assert run(client,state_dir)['code']=='BASE_CANDIDATE_MISSING'
    assert not client.named('complete')
