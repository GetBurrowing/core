---
title: Play
summary: Playable review builds of game tasks, streamed live into a game-stream canvas.
order: 12
verified_at: "837fba6e"
---

# Play

## What it is

Play lets people play a game task's review build before they approve it. A **play host**, a machine with a GPU connected to Burrow, checks out the task's branch at the exact commit under review, builds it, runs it, and streams the game into a **game-stream canvas** in the task's execution space. People play it in the browser, with a controller, keyboard or touch.

Play is an optional module (apps/game_stream). An operator turns it on for an install. While it is off, the play tools are not listed, game-stream canvases cannot be created, and an existing one shows a placeholder.

### Sessions

A **session** is one running build on one host.

- **What it builds:** the tip of the task's review branch, read when the session starts. The canvas shows that full commit sha and the branch. Play never falls back to the main branch.
- **When it can start:** the task must be in review and its branch pushed.
- **One at a time per host:** a host runs one session. Starting another while it is busy is refused.
- **States:** `building`, `connecting`, `live`, then `ended` or `failed`, each with a one-line detail.
- **Ending:** someone ends it, or the host ends it after a stretch with no input (10 minutes by default, adjustable from 1 to 60). Closing the canvas does not end it.

### The game-stream canvas

Starting a session creates a game-stream canvas and attaches it to the task, so it appears with the task's other canvases.

- **Watching:** opening the canvas always starts you as a spectator. Watching never moves or disconnects anyone.
- **Playing:** on a host that supports several players, the canvas shows a roster of player slots. Join a free slot, leave it, or take over a slot from someone else after a one-line confirmation. On a single-player host, **Play here** takes the stream to your page.
- **After a session ends:** the canvas offers **Start again**, which starts a new session the same way the tool does.

## When to use it

- **Reviewing a game task:** play the exact build you are being asked to approve, instead of reading the diff alone.
- **Checking that a build runs** before handing a task to a person for review.
- **Comparing two tasks:** stop one session before starting the next. A host runs one at a time.
- **Non-game work:** Play is for builds that render a game. Use canvases and screenshots for everything else.

## How agents use it

- Play's tools come in the `play` bundle. It is not granted by default, because it drives real hardware; an admin grants it to the runtimes that need it.
- `play_session_start` starts a session for a task in review. It returns the session id, the canvas and its link, the commit being built and the branch. If the canvas could not be made, the session still runs and the reply says why.
- `play_session_status` reads a session's state, its detail line, elapsed time and commit. Use it to follow a session you started or to explain one that failed.
- `play_session_stop` ends a session. The host stops the game it launched.
- Share the canvas link from `play_session_start` in the task's execution space so reviewers can open it.

## Common mistakes

- **Starting a session for a task that is not in review.** It is refused. Move the task to review and push its branch first.
- **Expecting the latest push to appear in a running session.** A session builds the commit it started with. Start a new session to pick up new commits.
- **Treating "host busy" as a fault.** Another session is running. Stop it, or wait for it to end.
- **Leaving sessions running.** A session holds the host until it is stopped or goes idle. Stop it when play is finished.
- **Expecting a session to survive a Burrow restart.** Live sessions end when Burrow restarts. Start a new one.

_Last verified at 837fba6e._
