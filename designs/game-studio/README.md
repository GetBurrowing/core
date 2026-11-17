# Burrow Play: Studio home

The dev-first Studio home direction was approved on 2026-11-17.
Source prototype: /proto/01a1e83d-fcdd-7000-8e8c-6c015d600c6f/latest/
Original handoff: attachment `01a1e83d-dc82-7000-b34f-3020aee86ca6`, `play-dev-first.zip`.

Studio opens a game project with its existing development conversation in the
center. It embeds Burrow chat rather than introducing another message model.
The chrome is neutral; people, agents and their work carry color. Discover is a
separate destination. Phone navigation uses the existing shared dock component:
Studio / Chat / Playtest / Discover / More. Existing native app versions render
the complete web dock because their native catalog does not know these new keys.

Project playtests resolve an exact commit on the default branch and create a
real Play canvas in the authorized development room. Task review playtests keep
their existing branch-only contract. Neither path changes task state. Starting a
project requires project and room creation permissions and a running Burrow
agent. The setup brief is posted into the new team room; repository and build
readiness are never fabricated. The current implementation offers engine briefs,
not prebuilt engine starter repositories.

All projects, tasks, rooms and canvases are scoped to the signed-in viewer. A
public player community cannot become a development room. Catalog builds remain
published releases; a design illustration is never presented as a live session.
