"""Literal style/capability forwarding tests across existing helper protocol."""

import json
import pytest
from conftest import FakeJobClient
from test_stage2 import first_new_clip, rerender_job, run

CAPABILITY = {
    "version": "0.9.0",
    "headline_review": 1,
    "content_free": 2,
    "caption_treatments": 1,
    "caption_styles": [
        "none",
        "plain",
        "phrase-pop",
        "karaoke",
        "type-on",
        "focus-word",
        "editorial-punch",
    ],
    "caption_renderer": {
        "sha256": "9074e59c4c38ddcfafd804f66cd72958cb3e28e3a992426c10e0446de53dbdd4",
        "temporal_sha256": "385f5e446c09bd06bb5fb11aaa4228fa95e47fa808e1c1d750bf6633d039aee7",
    },
}


def caption_job(style, appearance=True):
    return rerender_job(
        appearance=appearance,
        base_render_id="render-base",
        candidate_id="c2bbbbbbbb",
        look={"cap": {"style": style}},
        clip_overrides={"mapped": {}, "unmapped": []},
    )


@pytest.mark.parametrize("style", ["type-on", "focus-word", "editorial-punch"])
def test_dynamic_style_overrides_saved_none_in_profile_and_finalize(
    shim, state_dir, style, monkeypatch
):
    first_new_clip(shim, state_dir)
    monkeypatch.setenv("FAKE_CAPTION_STYLE", "none")
    shim.script(version={"stdout": CAPABILITY})
    n = len(shim.calls())
    client = FakeJobClient(jobs=[caption_job(style)])
    assert run(client, state_dir)["status"] == "done"
    calls = shim.calls()[n:]
    final = next(c["argv"] for c in calls if c["argv"][0] == "finalize")
    assert final[final.index("--captions") + 1] == style
    imports = [c for c in calls if c["argv"][:2] == ["profile", "import"]]
    assert any(f'style = "{style}"' in c.get("imported", "") for c in imports)
    assert not any(c["argv"][0] == "process" for c in calls)
    assert not list((shim.home / "profiles").glob("*-job-*"))
    assert all(c["env"].get("CLIP_NO_CONTENT") == "1" for c in calls)
    assert all("CLIP_RUNNER_TOKEN" not in c["env"] for c in calls)
    assert "secret transcript" not in json.dumps(client.calls)


@pytest.mark.parametrize(
    "change",
    [
        "missing",
        "palette-only",
        "wrong-source",
        "wrong-temporal",
        "boolean",
        "malformed",
    ],
)
def test_unqualified_exact_cli_fails_before_upload(shim, state_dir, change):
    first_new_clip(shim, state_dir)
    info = json.loads(json.dumps(CAPABILITY))
    if change == "missing":
        info.pop("caption_treatments")
    elif change == "palette-only":
        info["caption_styles"].remove("focus-word")
    elif change == "wrong-source":
        info["caption_renderer"]["sha256"] = "0" * 64
    elif change == "wrong-temporal":
        info["caption_renderer"]["temporal_sha256"] = "0" * 64
    elif change == "boolean":
        info["caption_treatments"] = True
    else:
        info["caption_renderer"] = "invalid"
    shim.script(version={"stdout": info})
    n = len(shim.calls())
    client = FakeJobClient(jobs=[caption_job("type-on")])
    assert run(client, state_dir)["code"] == "CAPTION_CLI_UNSUPPORTED"
    assert not any(c["argv"][0] == "finalize" for c in shim.calls()[n:])
    assert not client.named("complete")
    assert not any(c[0] == "request" and c[1] == "file_add" for c in client.calls)
    assert not list((shim.home / "profiles").glob("*-job-*"))


def test_unknown_style_is_not_silently_replaced(shim, state_dir):
    first_new_clip(shim, state_dir)
    assert (
        run(FakeJobClient(jobs=[caption_job("palette")]), state_dir)["code"]
        == "CAPTION_STYLE_UNSUPPORTED"
    )


@pytest.mark.parametrize("style", ["type-on", "focus-word", "editorial-punch"])
def test_new_clip_immutable_style_survives_headline_and_empty_delta(
    shim, state_dir, style
):
    shim.script(version={"stdout": CAPABILITY})
    client = first_new_clip(shim, state_dir, look={"cap": {"style": style}})
    final = next(
        c["argv"] for c in reversed(shim.calls()) if c["argv"][0] == "finalize"
    )
    assert final[final.index("--captions") + 1] == style
    assert client.named("complete")


def test_dynamic_finalize_failure_cleans_combined_profile(shim, state_dir):
    first_new_clip(shim, state_dir)
    shim.script(version={"stdout": CAPABILITY}, finalize={"exit": 3})
    client = FakeJobClient(jobs=[caption_job("editorial-punch")])
    assert run(client, state_dir)["status"] == "failed"
    assert not client.named("complete")
    assert not list((shim.home / "profiles").glob("*-job-*"))
    assert not list((state_dir / "tmp").glob("profile*"))


def test_dynamic_generic_rerender_cannot_upload_stale_previous_output(shim, state_dir):
    first_new_clip(shim, state_dir)
    shim.script(version={"stdout": CAPABILITY}, finalize={"exit": 0})
    # A successful CLI command that writes no new output is not rendering success.
    import os

    os.environ["FAKE_SKIP_RENDER"] = "1"
    try:
        client = FakeJobClient(jobs=[caption_job("focus-word", appearance=False)])
        assert run(client, state_dir)["code"] == "CAPTION_RENDER_MISSING"
        assert not client.named("complete")
        assert not any(c[0] == "request" and c[1] == "file_add" for c in client.calls)
        assert not list((shim.home / "profiles").glob("*-job-*"))
    finally:
        os.environ.pop("FAKE_SKIP_RENDER", None)
