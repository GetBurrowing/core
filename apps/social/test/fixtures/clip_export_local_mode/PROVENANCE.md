# clip_export_local_mode: a real export, from a synthetic project

`export.json` is the unedited output of the real exporter, `clip project export-intake`,
run against a SYNTHETIC local-mode project. There is no real media and no guest or episode
content: the "videos" in `videos/` are a few ASCII bytes, and the project is made by
`generate_project.py` in this folder. The exporter only reads the project and hashes the
captioned file; nothing was uploaded or sent anywhere.

## How it was generated

```
# the podcast clip tool's exporter (clip-agent)
# clip, version 0.9.0; Python 3.12.14; uv sync --frozen --python 3.12 --extra dev
cd clip-agent
HOME=<empty dir> CLIP_AGENT_HOME=<empty dir>/.clip-agent \
  .venv/bin/python generate_project.py PROJECT_DIR
HOME=<empty dir> CLIP_AGENT_HOME=<empty dir>/.clip-agent \
  .venv/bin/clip project export-intake PROJECT_DIR --out export.json
```

The two files in `videos/` are `PROJECT_DIR/final/01_Synthetic-clip-one.mp4` and
`02_Synthetic-clip-two.mp4`, copied byte for byte. Their SHA-256 and sizes equal the
`sha256` and `size_bytes` in `export.json` (checked with `shasum -a 256` and `wc -c` when
the fixture was made).

## What it shows
- local mode: no `title`, no `speakers` on any entry (the exporter withholds them);
- clip 1 is cut and unapproved, clip 2 is approved with a recorded approval and
  `approver_recorded: false`, clip 3 has no rendered file and is listed under `skipped`;
- the real field names and types, so the Elixir side is tested against the exporter and not
  against a hand-written guess.

To refresh it, regenerate with the commands above on a newer clip tool and replace both
`export.json` and `videos/`. If the exporter's shape changes, the pairing tests that read
this folder should fail.
