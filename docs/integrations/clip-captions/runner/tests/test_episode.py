import json
import tomllib

from conftest import PROFILE, FakeJobClient, make_job, make_runner
from test_stage2 import logged


class EpisodeClient(FakeJobClient):
    def request(self, tool, args, wait=None):
        self.calls.append(('request', tool, dict(args)))
        if tool == 'social_clip_job_source':
            return {'url': 'https://files.invalid/private-signed-token'}
        if tool == 'social_clip_job_progress' and 'picks' in args:
            if not hasattr(self, 'children'):
                self.children = []
                for i, pick in enumerate(args['picks']):
                    child = make_job(f'child-{i}', 'new_clip', **pick,
                                     episode_job_id=args['job_id'], headline={'consumer': 'episode'})
                    self.jobs[child['id']] = child
                    self.children.append(child['id'])
            return {'jobs': [dict(self.jobs[k]) for k in self.children]}
        if tool == 'social_clip_job_claim':
            return {'job': self.claim(args['job_id'])}
        if tool == 'social_clip_job_complete':
            self.complete(args['job_id'], {k: v for k, v in args.items() if k != 'job_id'})
            return {'job': dict(self.jobs[args['job_id']])}
        if tool == 'social_clip_job_fail':
            self.fail(args['job_id'], args['error'], args['code'])
            return {'job': dict(self.jobs[args['job_id']])}
        return super().request(tool, args, wait)


def episode():
    job = make_job('episode-parent', 'episode')
    job['clip_id'] = None
    job['payload']['clip_id'] = None
    return job


def test_process_once_then_every_pick_uses_shared_headline_and_fresh_render(shim, state_dir):
    client = EpisodeClient(jobs=[episode()])
    result = make_runner(client, state_dir).poll_once([PROFILE])
    assert result['status'] == 'done', result
    picks = next(c[2]['picks'] for c in client.calls if c[:2] == ('request', 'social_clip_job_progress'))
    assert picks == [{'candidate_id': 'c1aaaaaaaa', 'in_s': 100.0, 'out_s': 130.0},
                     {'candidate_id': 'c2bbbbbbbb', 'in_s': 300.0, 'out_s': 345.0}]
    assert all(set(p) == {'candidate_id', 'in_s', 'out_s'} for p in picks)
    argv = shim.argvs()
    assert sum(a[0] == 'process' for a in argv) == 1
    assert sum(a[0] == 'finalize' for a in argv) == len(picks)
    completed = client.named('complete')
    assert len(completed) == len(picks) + 1
    assert completed[-1][1] == 'episode-parent'
    assert all(c[2]['headline_applied'] is True for c in completed[:-1])
    assert all(client.jobs[k]['status'] == 'done' for k in client.children)
    # Independently authored generated headline literal; never MCP-exported.
    applications = [tomllib.loads(c['applied']) for c in logged(shim, 'applied')]
    assert any(c.get('headline') == 'secret transcript words two' for app in applications for c in app['clip'])
    assert 'secret transcript' not in json.dumps(client.calls)
    assert 'private-signed-token' not in json.dumps(client.calls)
    assert all(c['env'].get('CLIP_NO_CONTENT') == '1' for c in shim.calls())
    assert all('CLIP_RUNNER_TOKEN' not in c['env'] for c in shim.calls())
    assert not any('publish' in str(c[:2]) or 'approve' in str(c[:2]) for c in client.calls)


def test_missing_headline_hook_fails_parent_without_false_child_success(shim, state_dir, monkeypatch):
    monkeypatch.setenv('FAKE_HEADLINE_CAPABILITY', '0')
    client = EpisodeClient(jobs=[episode()])
    result = make_runner(client, state_dir).poll_once([PROFILE])
    assert result['status'] == 'failed'
    assert client.jobs['episode-parent']['status'] == 'failed'
    assert not client.named('complete')


def test_zero_picks_completes_only_parent(shim, state_dir, monkeypatch):
    monkeypatch.setenv('FAKE_EPISODE_ZERO', '1')
    client = EpisodeClient(jobs=[episode()])
    result = make_runner(client, state_dir).poll_once([PROFILE])
    assert result['status'] == 'done'
    assert client.children == []
    assert [c[1] for c in client.named('complete')] == ['episode-parent']
    assert not any(a[0] == 'finalize' for a in shim.argvs())


def test_partial_render_failure_preserves_first_child_and_fails_parent(shim, state_dir):
    import clip_runner
    client = EpisodeClient(jobs=[episode()])
    def upload(runner, job):
        if job['id'] == 'child-1':
            raise clip_runner.ClipError('UPLOAD_FIXTURE_FAILED', 'upload')
        return 'file-success-first'
    result = make_runner(client, state_dir, uploader=upload).poll_once([PROFILE])
    assert result['code'] == 'EPISODE_CHILD_FAILED'
    assert client.jobs['child-0']['status'] == 'done'
    assert client.jobs['child-1']['status'] == 'failed'
    assert client.jobs['episode-parent']['status'] == 'failed'
    assert [c[1] for c in client.named('complete')] == ['child-0']


def test_three_picks_have_exact_review_headlines_before_each_render(shim, state_dir, monkeypatch):
    monkeypatch.setenv('FAKE_EPISODE_THREE', '1')
    client = EpisodeClient(jobs=[episode()])
    result = make_runner(client, state_dir).poll_once([PROFILE])
    applications = [tomllib.loads(c['applied']) for c in logged(shim, 'applied')]
    # Independent exact literals: omission of helper headline forwarding fails
    # this assertion even if a permissive fake marks child completion done.
    applied_headlines = {c['id']: c.get('headline') for app in applications for c in app['clip']}
    assert applied_headlines == {
        'c1aaaaaaaa': 'The demo finally worked',
        'c2bbbbbbbb': 'We fixed the wrong button',
        'c3cccccccc': 'The tiny bug won again',
        'a1dddddddd': None,
    }
    assert result['status'] == 'done', result
    argv = shim.argvs()
    assert sum(a[0] == 'process' for a in argv) == 1
    assert sum(a[0] == 'finalize' for a in argv) == 3
    calls = shim.calls()
    # Every finalize must follow prepare, apply and applied verification.
    last_final = -1
    for final, call in enumerate(calls):
        if call['argv'][0] != 'finalize':
            continue
        window = calls[last_final + 1:final]
        prepared = next(i for i, c in enumerate(window) if c['argv'][:2] == ['hooks', 'prepare-review'] and '--check-applied' not in c['argv'])
        applied = next(i for i, c in enumerate(window) if i > prepared and '--apply' in c['argv'])
        verified = next(i for i, c in enumerate(window) if '--check-applied' in c['argv'])
        assert prepared < applied < verified
        last_final = final
    assert len(client.named('complete')) == 4
    assert all(c[2]['headline_applied'] is True for c in client.named('complete')[:-1])
    assert not any('publish' in str(c[:2]) or 'approve' in str(c[:2]) or 'schedule' in str(c[:2]) for c in client.calls)
