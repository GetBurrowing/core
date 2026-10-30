import json
import os
import tomllib

import pytest
from conftest import FakeJobClient, default_context
from test_stage2 import first_new_clip, logged, proj, rerender_job, run

EXACT = 'two words secret transcript'


def edit_job(**kwargs):
    return rerender_job(base_render_id='render-fixture-1',
                        headline={'consumer': 'edit', 'requested_headline': EXACT}, **kwargs)


def test_new_pick_generates_automatically_and_exact_review_field(shim, state_dir):
    client = first_new_clip(shim, state_dir)
    prepared = logged(shim, 'headline_request')[0]
    assert prepared['headline_request']['consumer'] == 'episode'
    assert prepared['headline_request']['requested_headline'] is None
    target = next(c for c in tomllib.loads(logged(shim, 'applied')[-1]['applied'])['clip']
                  if c['id'] == 'c2bbbbbbbb')
    # Independent literal: deleting headline forwarding MUST fail here.
    assert target['headline'] == 'secret transcript words two'
    assert target['packaging'] == 'bbbbbbbbbbbbbbbb'
    assert prepared['request_mode'] == 0o600
    assert not list((state_dir / 'tmp').glob('headline-request*'))
    assert not list((shim.home / 'profiles').glob('*-job-*'))
    result = client.named('complete')[0][2]
    assert EXACT not in json.dumps(result)
    assert json.loads((state_dir / 'state.json').read_text())['clips']['clip-job-01']['headline_receipt']['status'] == 'applied'


def test_edit_exact_text_ordering_and_stale_variant_is_not_success(shim, state_dir):
    first_new_clip(shim, state_dir)
    n = len(shim.calls())
    client = FakeJobClient(jobs=[edit_job()])
    assert run(client, state_dir)['status'] == 'done'
    calls = shim.calls()[n:]
    prepare = next(i for i, c in enumerate(calls) if c['argv'][:2] == ['hooks', 'prepare-review'])
    apply = next(i for i, c in enumerate(calls) if i > prepare and '--apply' in c['argv'])
    verify = next(i for i, c in enumerate(calls) if '--check-applied' in c['argv'])
    final = next(i for i, c in enumerate(calls) if c['argv'][0] == 'finalize')
    assert prepare < apply < verify < final
    assert calls[prepare]['headline_request']['consumer'] == 'edit'
    assert calls[prepare]['headline_request']['requested_headline'] == 'two words secret transcript'
    target = next(c for c in tomllib.loads(calls[apply]['applied'])['clip'] if c['id'] == 'c2bbbbbbbb')
    assert target['headline'] == 'two words secret transcript'
    assert '--regenerate' in calls[final]['argv']
    assert all(c['env'].get('CLIP_NO_CONTENT') == '1' for c in calls)
    assert all('CLIP_RUNNER_TOKEN' not in c['env'] for c in calls)


def test_regenerate_uses_same_generation_boundary(shim, state_dir):
    first_new_clip(shim, state_dir)
    client = FakeJobClient(jobs=[rerender_job(base_render_id='render-fixture-1',fix={'operation':'regenerate_headline'})])
    assert run(client, state_dir)['status'] == 'done'
    request = logged(shim, 'headline_request')[-1]['headline_request']
    assert request['consumer'] == 'regenerate'
    assert request['requested_headline'] is None
    assert request['base_render_id'] == 'render-fixture-1'


@pytest.mark.parametrize('change,expected', [
    ({'headline_voice': None}, 'HEADLINE_VOICE_MISSING'),
    ({'base_render_id': 'newer-render'}, 'HEADLINE_BASE_STALE'),
])
def test_missing_voice_or_stale_base_never_completes(shim, state_dir, change, expected):
    first_new_clip(shim, state_dir)
    n = len(shim.calls())
    client = FakeJobClient(jobs=[edit_job()])
    def context(runner, job):
        return {**default_context(runner, job), **change}
    assert run(client, state_dir, context_for=context)['code'] == expected
    assert not client.named('complete')
    assert not any(c['argv'][0] == 'finalize' for c in shim.calls()[n:])
    assert not list((shim.home / 'profiles').glob('*-job-*'))


def test_empty_and_export_requests_fail(shim, state_dir):
    first_new_clip(shim, state_dir)
    for headline, code in [({'consumer':'edit','requested_headline':' '},'HEADLINE_EMPTY'),
                           ({'consumer':'edit','requested_headline':EXACT,'export_text':True},'HEADLINE_PRIVACY_EXPORT_REFUSED')]:
        client = FakeJobClient(jobs=[rerender_job(base_render_id='base-1',headline=headline)])
        assert run(client, state_dir)['code'] == code
        assert not client.named('complete')


def test_unsupported_receipt_does_not_finalize_or_leak(shim, state_dir):
    first_new_clip(shim, state_dir)
    shim.script(hooks={'stdout': {'status':'prepared','applied_headline':'private text'}})
    n=len(shim.calls())
    client=FakeJobClient(jobs=[edit_job()])
    assert run(client,state_dir)['code']=='HEADLINE_OUTPUT_UNSUPPORTED'
    assert not client.named('complete')
    assert 'private text' not in json.dumps(client.calls)
    assert not any(c['argv'][0]=='finalize' for c in shim.calls()[n:])
    assert not list((state_dir/'tmp').glob('headline-request*'))


def test_unbacked_edit_failure_has_no_completion_or_text(shim,state_dir,monkeypatch):
    first_new_clip(shim,state_dir)
    monkeypatch.setenv('FAKE_HEADLINE_UNBACKED','1')
    client=FakeJobClient(jobs=[edit_job()])
    assert run(client,state_dir)['code']=='HEADLINE_UNBACKED'
    assert not client.named('complete')
    assert EXACT not in json.dumps(client.calls)


def test_stale_existing_video_cannot_claim_render_success(shim,state_dir,monkeypatch):
    first_new_clip(shim,state_dir)
    video=proj(shim)/'final'/'02_secret-title-two.mp4'
    os.utime(video,ns=(1,1))
    monkeypatch.setenv('FAKE_SKIP_RENDER','1')
    client=FakeJobClient(jobs=[edit_job()])
    assert run(client,state_dir)['code']=='HEADLINE_RENDER_MISSING'
    assert not client.named('complete')


def test_request_forwards_exact_independent_headline_literal(state_dir):
    from types import SimpleNamespace

    import clip_runner
    runner = SimpleNamespace(headline_capability=True, tmp_dir=lambda: state_dir,
                             context={'base_render_id':'render-fixture-1','headline_voice':{'revision':'fixture-8','direction':'Comedy; incomplete.'}},
                             review_entry={'id':'c2bbbbbbbb','start':305.,'end':340.})
    request = clip_runner._headline_request(runner,edit_job(),'edit')
    assert request['requested_headline'] == 'two words secret transcript'


@pytest.mark.parametrize('style,expected', [('karaoke','karaoke'),('none','phrase-pop')])
def test_headline_enables_captions_without_overwriting_style(shim,state_dir,monkeypatch,style,expected):
    monkeypatch.setenv('FAKE_CAPTION_STYLE',style)
    first_new_clip(shim,state_dir)
    profile=tomllib.loads(logged(shim,'imported')[-1]['imported'])
    assert profile['captions']['style']==expected
    assert profile['captions']['hook_title'] is True
    final=next(c for c in reversed(shim.argvs()) if c[0]=='finalize')
    assert final[final.index('--captions')+1]==expected
