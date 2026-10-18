# ADR 0055: Extension Contract and Build-Time Modules

- **Status:** Proposed (until stage 4's two images both boot; design review by Moore, 2026-09-29)
- **Date:** 2026-09-29
- **Owners:** Team
- **Task:** 01a0ee08-c2ec-7001-89d2-c888d6a7b73e
- **Extends:** [ADR 0053](0053-install-manifest-and-renderers.md) (the install manifest gains a
  module selection; not superseded)
- **Related:** [ADR 0001](0001-repository-shape-and-boundary.md), [ADR 0048](0048-experimentation-substrate.md)

## Context

Every install runs the same core image, and optional product areas are switched on or off by
environment flags read at runtime (`GAME_STREAM_ENABLED`, `MAIL_ENABLED`). A flag leaves the
code, its tools, its canvas kind, its experiment surfaces, its runtime-channel events and its
migrations in every install, and core has to name the feature in every place it gates it.
ADR 0053 made every customer an owned install. An install should therefore be **flavoured at
build time**: a module is either in the build or not, and enabling one later is a config line
plus a deploy.

Play (the `game_stream` review-build streaming feature, task 01a0db5f) is the pilot, because it
is recent, self-contained and small. Meetings, Mail and Social are out of scope here; Social
is expected to be the second consumer.

### What core looks like today

Measured on `origin/main` at `eb30c8593`, 2026-09-29.

**Core is not a Mix umbrella.** There is no root `mix.exs`. `apps/platform` is a standalone
Mix project with its own `deps/`, `_build/` and `mix.lock`, and several things depend on that
layout:

- `apps/platform/Dockerfile` copies `apps/platform/mix.exs` and `apps/platform/mix.lock` into
  the build stage, then `config`, `assets`, `priv` and `lib`.
- CI runs with `working-directory: apps/platform` and caches `apps/platform/deps`.
- `apps/platform/config/config.exs` sets esbuild's `NODE_PATH` to `Path.expand("../deps",
  __DIR__)` in three profiles, which resolves to `apps/platform/deps`.
- test-host's `core-test.sh` runs the suite container with `-w /app/apps/platform`.

**Play registers no rail item and no route.** `canonical_destinations/0` in
`lib/platform_web/components/icon_rail.ex` has no Play entry, and `router.ex` has no play or
game path. A grep of every Play-owned file for `telemetry`, `:telemetry.attach`,
`Responsibilit`, `prompt_template` and `PromptTemplate` returns nothing, so Play has no
telemetry handlers, no responsibility providers and no prompt templates either.

**Inbound references.** The task's falsifier grep, `grep -rlE "Platform\.GameStream\b"
apps/platform/lib | grep -v game_stream`, returns 9 files: `federation.ex`, `application.ex`,
`meetings.ex`, `chat/canvas/kinds.ex`, `federation/play_tools.ex`,
`federation/tool_authorization.ex`, `mix/tasks/platform/seed_play_host.ex`,
`federation/tool_surface.ex` and `platform_web/channels/runtime_channel.ex`. That grep
undercounts, because it matches only the `Platform.GameStream` prefix and drops every path
containing `game_stream`. The full set of places where core names Play is tabled in
[§ Inbound references and the seam that replaces each](#inbound-references-and-the-seam-that-replaces-each).

**Installs.** Read-only, 2026-09-29, on test-host:

| Install | Core container | Image | `GAME_STREAM_ENABLED` | DB | Play versions in `schema_migrations` | `schema_migrations` rows / newest | `game_stream_sessions` rows | runtimes granted `play` | `game_stream.*` experiments |
|---|---|---|---|---|---|---|---|---|---|
| Install A | `core-platform` | `docker.io/example/suite-core:latest` | `true` | `core-postgres` / `core_platform` | `20260926030000` (2026-09-26 09:36:51), `20260928200000` (2026-09-29 07:37:17) | 306 / `20260928230000` | 10 | 2 | 0 |
| Install B | `core-platform-b` | `docker.io/example/suite-core:latest` | unset | `b-postgres` / `b_platform` | `20260926030000` (09:36:41), `20260928200000` (07:36:55) | 306 / `20260928230000` | 0 | 0 | 0 |
| Install C | `core-platform-c` | `docker.io/example/suite-core:latest` | unset | `c-postgres` / `c_platform` | `20260926030000` (09:36:29), `20260928200000` (07:37:06) | 306 / `20260928230000` | 0 | 0 | 0 |
| exp | `core-platform-exp` | `docker.io/library/elixir:1.19-otp-27` (source-mounted) | unset | `core-postgres-exp` / `core_platform_exp` | neither | 221 / `20260804220000` | table absent | not read | not read |

`apps/platform/priv/repo/migrations` holds 306 files on `eb30c8593`, so each of the three
production installs has run every core migration, including both Play migrations and
`20260928230000`, which is newer than either of them. The flag was read from each container's
`Config.Env` (which includes EnvironmentFile values); the migration rows were read with `psql`
as each postgres container's `POSTGRES_USER`. Nothing was written or restarted. test-host deploys by
webhook: a push to the registry restarts every install that pulls the pushed tag.

**All three production installs pull the same tag and disagree on the flag.** No single-tag
image mapping can preserve both behaviours once the flag is gone. See
[§ 9. Install safety at merge](#9-install-safety-at-merge).

## Decision

### 1. A module is its own Mix project; core takes no dependency on it

A module lives in `apps/<module>` (Play: `apps/game_stream`) as a standalone Mix project that
takes core as a **path dependency**: `{:platform, path: "../platform", env: Mix.env()}`. Core
never depends on a module, never names one, and cannot tell whether one exists.

A with-modules build is a thin **release host**, `apps/burrow_release`: a Mix project with no
code of its own whose `deps` are `:platform` plus the selected modules, all by path. Its
config imports core's config and adds the module selection. Its release is the with-modules
image. `apps/platform` by itself remains the without-modules build and the without-modules
image, with **no change to any command**:

- `cd apps/platform && mix compile --warnings-as-errors && mix test`;
- `podman build -f apps/platform/Dockerfile .`;
- the test rig's mix-test wrapper `<branch>` (core-test.sh's `-w /app/apps/platform`).

The spike in [§ Proof](#proof) shows this holds with a module and a release host present, and
that core cannot reference a module without failing its own compile.

**Why a root umbrella (option A) lost.** An umbrella earns its keep by sharing one `deps/`,
one `_build/`, one `mix.lock` and one `config/` across children. Sharing them means setting
`deps_path`, `build_path`, `lockfile` and `config_path` in `apps/platform/mix.exs`, which moves
`apps/platform/deps` and `apps/platform/mix.lock`. That breaks the Dockerfile's `COPY
apps/platform/mix.exs apps/platform/mix.lock`, the CI deps cache and the esbuild `NODE_PATH`,
which is exactly what the binding constraint forbids. The spike ran the umbrella **without**
those settings (step S9 in [§ Proof](#proof)). It compiles, and `apps/platform` still compiles
alone, but:

- the root creates a **third** `deps/`, `_build/` and `mix.lock`, shared with nothing in
  `apps/platform`, so the umbrella shares nothing the constraint allows it to share;
- an umbrella child can no longer be built on its own (S9c: `apps/game_stream` alone fails with
  every dependency "not available"), so a module's CI job has to build from the root;
- a root build compiles **every** project under `apps/` (S9 compiled `platform`, `game_stream`
  and `suite_release` together). There is no without-modules umbrella build, so the flavour
  would have to be selected at release time, after compile and test gates that ran with every
  module present. B's without-modules build is the one CI already runs.

It also changes what `mix` means at the repo root, where agents and briefs rely on there being
no `mix.exs`. B has none of these costs.

**Costs of B that we accept:**

- **Two lockfiles.** Mix ignores a path dependency's lockfile, so `apps/burrow_release/mix.lock`
  resolves core's dependency tree independently of `apps/platform/mix.lock`. The two must hold
  the same versions for every package core uses. Stage 3 adds the check that every entry in
  `apps/platform/mix.lock` appears, unchanged, in each host and module lockfile: an ExUnit test
  (`apps/platform/test/platform/module_lockfiles_test.exs`) and a CI step before any build
  (`scripts/check-module-lockfiles.exs`). The spike records how far they diverge when nothing
  enforces it.
- **Several `_build` trees.** Each project compiles core into its own `_build`. That costs
  build time and disk, and nothing else.
- **Core's `config/` is imported, not shared.** Each host and module has a two-line
  `config/config.exs` that runs `import_config "../../platform/config/config.exs"`. Core's
  file then imports its own `dev.exs`, `test.exs` or `prod.exs` relative to itself. A module
  adds its own keys after the import.

### 2. The `Platform.Extension` behaviour

A module ships one module implementing `Platform.Extension` (Play:
`Platform.GameStream.Extension`) and is listed in app env:

```elixir
config :platform, :extensions, [Platform.GameStream.Extension]
```

The key is set only by a release host's config (and by a module's own test config). Core's
config never sets it, so an unset key means no modules. Core reads it through
`Platform.Extensions` **per call** and never captures it in a module attribute, following the
rule `Platform.Chat.Canvas.Kinds` states for its gated list: a module attribute is evaluated at
compile time, so a list captured in one would ignore both the host's config and a test's
`Application.put_env`.

Required callbacks. Each returns data, and an empty list is a valid answer:

| Callback | Returns | Replaces (on `eb30c8593`) |
|---|---|---|
| `canvas_kinds/0` | kind modules; each kind module also answers its own `describe/0` | `chat/canvas/kinds.ex:72` `gated_modules/0`; `kinds.ex:144` `describe("game_stream")` |
| `mcp_tool_bundles/0` | `[%{name: "play", definitions: [...], execute: {mod, fun}}]` | `federation/tool_surface.ex:82` `@bundles` entry `play`; `:259` `tools_for_bundle("play")`; `:7513` `execute("play_session_" <> _)`; `federation/tool_authorization.ex:166-181` `disabled_play_tool?` |
| `runtime_channel_events/0` | event names this module owns, e.g. `["play_session_status", "play_signal", "play_slot_activity"]` | `platform_web/channels/runtime_channel.ex:280-327`, three `handle_in` clauses |
| `handle_runtime_event/3` | `(event, runtime_id, payload) :: :ok \| {:error, term}` | the bodies of those three clauses |
| `runtime_disconnected/1` | `(runtime_id) :: :ok`; must not raise when the module's processes are absent | `runtime_channel.ex:793` `Platform.GameStream.host_disconnected/1` |
| `live_hooks/0` | `[{mod, fun}]`, each `(socket) -> socket` | `PlatformWeb.GameStreamHooks.attach/1` at `chat_live.ex:802`, `canvas_live.ex:124`, `meeting_live.ex:439` and `:551`, `tasks_live.ex:144` |
| `experiment_surfaces/0` | surface modules | `experiments/surfaces.ex:65` and `:68` |
| `experiment_metrics/0` | `%{slug => %{module: ..., ...}}` in the existing registry shape | `experiments/metrics.ex:122-132` |
| `rail_items/0` | destination maps in `canonical_destinations/0`'s shape | nothing today; see § 5 |
| `migrations_path/0` | an absolute path, or `nil` | nothing today; see § 6 |
| `assets/0` (optional, built stage 3) | `%{js_hooks: path_or_nil, css: path_or_nil, tailwind_sources: [path]}`, read at BUILD time only | `assets/js/hooks/index.js:17` and `:79`; `assets/css/app.css:8238`; the Tailwind `@source` for the kind's classes |
| `bundle_grant_notice/0` | the text shown for a persisted grant of this module's bundle when the module is absent; optional, with a default | nothing today; see § 7 |

**The contract as built (stages 2 and 3).** Three details differ from the table above, and the
code is the authority:

- A tool bundle is `%{name, definitions, tool_names, execute}` plus two optional keys:
  `deny_message` (a transport's denial text for one of the bundle's tools) and `owns_tool?`, a
  name-space claim that is asked only after the exact-name lookup misses. Play claims
  `play_session_*`, so `play_session_nope` keeps main's Play-owned `unknown_tool` reply.
  `Platform.Extensions.validate/0` refuses a claim that covers a core tool name.
- Stage 2 added a `children/0` callback, and core started those child specs from
  `application.ex` in the old position before the Endpoint. **Stage 3 retires it.** Supervision
  is the module's own, as § 3 says. The behaviour no longer declares `children/0`, and
  `Platform.Extensions` no longer exposes it. A test asserts both, so the two mechanisms cannot
  coexist.
- `assets/0` is optional, because a module with no front end omits it. Its only reader is
  `mix platform.extensions.assets` at build time (§ 4).

Where there is prior art, the contract generalises it rather than inventing a second shape:
`Platform.Experiments.Surfaces.list/0` already appends app env `:experiments_extra_surfaces`,
and `Surfaces.list/0` will append `Extensions.experiment_surfaces()` the same way.

**Unowned runtime events.** An event no extension owns keeps today's flag-off behaviour
(`runtime_channel.ex:808` `log_play_frame_disabled/2`): it is logged once per socket, the
reply is `:noreply`, and the channel stays joined.

**Optional callbacks, deferred to their first consumer.** `routes/0`, `telemetry_handlers/0`,
`responsibility_providers/0` and `prompt_templates/0` are declared in the behaviour as
`@optional_callbacks`, so a module may implement them. No reader for any of them is built in
this task, because no module has an entry to put in them: Play has no route, no telemetry
handler, no responsibility and no prompt template (measured above). **This is a deliberate
deferral, not an omission.** The first module that needs one builds its reader, with a fixture
as a positive control, the same way stage 2 builds `rail_items` for Social. Until a reader
exists, implementing one of these callbacks has no effect. A test states that, so nobody
mistakes it for a working seam.

### 3. Supervision is the module's own

A module's supervision tree is started by its own `Application.start/2`
(`GameStream.Application` starts `Platform.GameStream.Supervisor`). Core's
`application.ex:65`, which lists `Platform.GameStream.Supervisor` today, loses that line.

**Ordering consequence.** OTP starts an application after the applications it depends on and
stops it before them. `:game_stream` depends on `:platform`, so the module now starts **after**
core's Endpoint and stops **before** it. The comment at `application.ex:62-64` relies on the
opposite order ("before the Endpoint so a runtime channel's terminate/2 can always reach its
Registry"), and it will be false. Two consequences follow:

- At shutdown, a `RuntimeChannel` terminating after the module has stopped calls
  `runtime_disconnected/1` with the module's Registry gone. The callback must return `:ok`
  (`Registry.lookup/2` on a missing registry raises `ArgumentError`, so the callback checks
  `Process.whereis/1` first or rescues).
- At boot, the Endpoint accepts runtime sockets before the module has started, so a play
  frame can arrive while the Registry is absent. `handle_runtime_event/3` must also tolerate
  that, and return an error that the channel logs, not raise.

Stage 2 tests both with the owner's Registry stopped. In stage 3 those cases moved with Play
into `apps/game_stream/test/platform/game_stream/extension_parity_test.exs`, where Play's
`Platform.GameStream.Application` is what starts `Platform.GameStream.Supervisor` (under
`Platform.GameStream.Application.Supervisor`). The ordering itself is asserted in
`application_test.exs`: `:game_stream` starts after `:platform`, and core's supervisor has no
Play child.

### 4. Assets

- **JS.** Core's esbuild profile resolves an `@extensions` import alias to a checked-in
  empty registry, `assets/js/extensions/none.js` (`export default {}`), and `hooks/index.js`
  spreads it where it imports `GameStream` today. The release host's config overrides only
  that alias, pointing it at a file the host generates from `assets/0` of its configured
  extensions, and the `NODE_PATH` entries, pointing them at the host's own `deps`. Nothing is
  generated inside `apps/platform`, so the without-modules build needs no generation step and
  its tree cannot be dirtied by a with-modules build.
- **CSS.** The host builds a wrapper stylesheet that imports core's `app.css`, adds an
  `@source` for each module's `tailwind_sources`, and imports each module's `css`. Play's
  `app.css:8238` block moves into `apps/game_stream`.
- **Bundle cap.** `assets/test/no_excalidraw_in_app_bundle_test.mjs` must pass in both
  flavours. The without-modules bundle must not contain a Play hook literal.

The spike below does **not** prove the asset path; it proves compilation only. Stage 3 proves
it. Measured on test-host, `node:24-slim` and core's Tailwind 4.1.12:

- **The generator is core's and generic.** `mix platform.extensions.assets --out
  assets/generated`, run from a host, reads `Platform.Extensions.assets/0` and writes two
  files. Paths are relative to the generated file, so the output is correct in any checkout.
  For Play it writes:

  ```js
  // Generated by `mix platform.extensions.assets` (ADR 0055). Do not edit.
  import ext0 from "../../../game_stream/assets/js/extension.js"
  export default {
    ...ext0,
  }
  ```

  ```css
  @import "../../../platform/assets/css/app.css";
  @import "../../../game_stream/assets/css/game_stream.css";
  @source "../../../game_stream/lib";
  ```

  The generated files are gitignored in `apps/burrow_release`.
- **esbuild.** Core's `platform` profile adds `--alias:@extensions=./js/extensions/none.js`.
  `--alias:@=.` does not capture `@extensions`. The host's profile overrides only that alias,
  plus its own output directory and `NODE_PATH`. `hooks/index.js` spreads `@extensions` first,
  so a core hook of the same name wins.
- **Tailwind.** The wrapper's `@import` of core's `app.css` keeps core's own relative
  `@source` and `@plugin` lines resolving against core's file. The wrapper's `@source` adds
  the module's lib. Probes, as occurrence counts in core's CSS and then the host's:
  `.game-stream-frame` 0 and 2 (the module's stylesheet); `.ring-inset` 0 and 1;
  `bg-white\/10` 0 and 1; `.text-white\/70` 0 and 1. The last three are utilities used
  only in the kind's HEEx. Sizes: core 524,482 bytes, host 527,533 bytes.
- **Bundle cap (896 KB).** Both flavours pass. `app.js` is 789,866 bytes without modules and
  825,383 bytes with Play. The same test file runs both flavours: `SUITE_EXTENSIONS_JS`
  selects the generated entry. It also asserts that the without-modules bundle does not
  contain `game_stream_attach`, the viewer's attach event, and that the with-modules bundle
  does contain it (the positive control).
- **JS tests.** Play's seven vitest files moved to `apps/game_stream/assets`, which has its own
  `package.json` and lockfile (vitest only; the hooks import nothing outside the module).
  Counts: core vitest 610 and node 71 without Play; module vitest 131.

### 5. Rail items: which are core and which are module

Every entry in `canonical_destinations/0` on `eb30c8593` (12 entries; the comment above the
function still says 11) is core. None moves in this task:

| Key | Path | Cluster | Gate |
|---|---|---|---|
| `chat` | `/chat` | live | none |
| `tasks` | `/tasks` | live | none |
| `inbox` | `/inbox` | live | none |
| `activity` | `/activity` | live | none |
| `skills` | `/skills` | working | none |
| `files` | `/files` | working | none |
| `context` | `/org_memory` | working | none |
| `prompts` | `/admin/prompts` | working | `root_only?: true` |
| `experiments` | `/control/experiments` | working | none |
| `meetings` | `/meetings` | working | none |
| `email` | `/email` | working | env-gated: `enabled?: &Platform.Mail.Config.enabled?/0` (`MAIL_ENABLED`) |
| `admin` | `/admin` | admin | `root_only?: true` |

Play contributes no rail item. `email` is the only env-gated entry and is the natural next
candidate for a module, which is out of scope here. `canonical_destinations/0` appends
`Extensions.rail_items()`, and an extension's item goes through the same `root_only?` and
`enabled?` filters as a core item.

### 6. Migrations

A module keeps its migrations in its own `priv/repo/migrations`, and `migrations_path/0`
returns that path. `Platform.Release.migrate/0`, the `ecto.migrate` step of core's `test` alias
and dev all run

```elixir
Ecto.Migrator.run(repo, [core_path | Extensions.migrations_paths()], :up, all: true)
```

Core's path is always first.

**Moving Play's migrations is invisible to a database that already ran them.** Ecto's
`schema_migrations` table has one column that matters, `version`, and the migrator decides
what to run by version alone. It records neither the file path nor the module name. Play's two
files move with **identical filenames, versions and module names**
(`20260926030000_create_game_stream_sessions.exs`,
`20260928200000_add_player_dimensions_to_game_stream_sessions.exs`), so a database that ran
them from `apps/platform` sees them as already up when they come from `apps/game_stream`. All
three production installs are in that state (Context table).

**Enabling a module later runs its migrations out of order, and that is intended.**
`run(:up, all: true)` applies every pending version across all paths, including versions older
than the newest one already applied. A database that ran core to `20260928230000` without Play
and then gains Play applies `20260926030000` and `20260928200000` then. Nothing in core may
therefore depend on a module's migration having run.

Hazards, and the rule that removes each:

- **(a) Version collision.** If a module migration's version equals a core version (or another
  module's), the migrator treats one as already applied, and on some databases one file
  silently never runs. Versions are unique across **all** paths. Stage 3 extends the CI
  duplicate-timestamp check (`.github/workflows/ci.yml:94`) and the migration moduledoc
  guard to every path, adds a cross-path uniqueness test that names both files, and shows it
  red on a planted duplicate.
- **(b) Foreign-key direction.** A module migration may reference only stable core tables,
  today `tasks` and `experiments` (Play's `game_stream_sessions.task_id` and `experiment_id`).
  Core never references a module table. Measured: only the two Play migrations mention
  `game_stream_sessions`. A core FK into a module table would fail on every install without
  the module.
- **(c) Rollback.** `Platform.Release.rollback/2` used to run
  `Ecto.Migrator.run(repo, :down, to: version)` over the default path only. Since stage 3,
  `rollback/3` runs over the full path list, and it **refuses** any rollback that would undo an
  applied module migration. In that case it runs nothing, logs an error, and returns
  `{:error, {:crosses_module_migrations, versions}}`. It proceeds only with
  `allow_module_rollback: true` or with `ALLOW_MODULE_ROLLBACK=true` in the environment (for
  `bin/platform eval`). Rolling back across a module's versions is the module's decision, not
  a side effect of rolling back core. Stage 5's prod-like case checks that a rollback of one
  core version touches only that version.

  Measured while building this: `Ecto.Migrator.migrations(repo, [module_path])` lists **every**
  applied version in the database as `:up`, including versions with no file in that path
  (named `** FILE NOT FOUND **`). A guard built on it therefore counted all seven core versions
  at or above the target as the module's. The guard reads the module's migration **files**
  and intersects them with `Ecto.Migrator.migrated_versions/1`. The module's own suite ran the
  refusal against its migrated test database, and the schema was unchanged afterwards.

  Ecto itself raises on a duplicate version, but only across paths passed to the same
  `migrate`. A without-modules build never passes the module's path, so that check cannot
  catch a collision that would ship. The static guard (`migration_paths_test.exs`, and the CI
  duplicate-timestamp step, both over `apps/*/priv/repo/migrations`) is what catches it.

**What a without-module install does with what the module left behind.** Install B and Install
C hold the Play table and both versions today, although the flag has been off on both.

- **The `game_stream_sessions` table stays.** It is orphaned: no code reads or writes it, and
  nothing drops it. `mix ecto.migrations` in the without-module build lists both versions as
  `up` with `** FILE NOT FOUND **`, which is the expected state and not an error; `migrate`
  does nothing for them. Dropping the table is a manual, per-install decision that this ADR
  does not take.
- **`agent_runtimes.allowed_bundles` containing `"play"`.** Install A has two such rows; the other
  installs have none. `ToolSurface.list_tools/1` already skips unknown bundle names, so
  `tools/list` omits the tools, and a call to a `play_session_*` name gets the ordinary
  unknown-tool error. The row itself is the problem: `AgentRuntime.changeset/2` validates
  `allowed_bundles` with `validate_subset` against `@valid_bundles`
  (`agents/agent_runtime.ex:27`), and the admin form (`control_center/runtime_panel.ex:131`)
  renders a checkbox only for valid bundles. In a without-module build, saving that runtime
  from the admin panel **silently drops the grant**, and any changeset that carries the
  existing list is **rejected**. The plan did not list this site; see § 7.
- **`experiments` rows with a `game_stream.*` `surface_key`.** None exist on any install today.
  Every reader measured on `eb30c8593` tolerates an unknown surface: `Surfaces.get/1` returns
  `nil`, `Surfaces.resolve/4` returns `:none`, and the `experiments_live.ex`, `experiments.ex`,
  `experiments/tools.ex`, `promotion.ex`, `guardrail.ex` and `heartbeat_scheduler.ex` call
  sites branch on `nil`. `Metrics.metric_module/1` returns `nil` for an unknown slug. Stage 5
  verifies the page renders with such a row.
- **Canvas documents holding a `game_stream` node** render through the renderer's unknown-kind
  fallback, as they already do with the flag off (`kinds.ex` moduledoc).

### 7. Bundles that outlive their module

`@valid_bundles` in `agents/agent_runtime.ex` must equal `ToolSurface.all_bundles/0` as a set
(`agent_runtime_test.exs` guards that). Both become core bundles plus
`Extensions.tool_bundles()` names, evaluated per call. So that a without-module install
cannot lose data it cannot see, `AgentRuntime.changeset/2` validates only the bundles a
change **adds**: a bundle already persisted on the row passes even when no loaded module
provides it. The admin panel renders such a bundle as a checked, disabled row labelled with
the module's `bundle_grant_notice/0` default ("module not installed"), and it submits the
bundle unchanged, so the grant survives a save and works again when the module is enabled.
This belongs in stage 2 with the other seams.

### 8. Configuration that belongs to a module

Play's runtime configuration (`config/runtime.exs:494-549`: the flag at `:494-502` and the
TURN block at `:504-549`) is read by the module, not by core. A module cannot rely on the
host's `runtime.exs` importing its own: Mix refuses `import_config/1` in `runtime.exs` (spike
T4), and a release does not ship an imported file (T6).

**What a module reads at boot (stage 3).** `Platform.GameStream.Application.start/2` calls
`Platform.GameStream.RuntimeConfig.apply(System.get_env())`. That reads `GAME_STREAM_ENABLED`,
`GAME_STREAM_TURN_URLS`, `GAME_STREAM_TURN_USERNAME` and `GAME_STREAM_TURN_CREDENTIAL_FILE`,
with the same parsing and the same never-log-the-credential rule, and puts the result in the
module's **own** app env: `:game_stream, :enabled` and `:game_stream, :turn`. Before the move
these were `:platform, :game_stream_enabled` and `:platform, :game_stream_turn`. The whole
block left core's `runtime.exs`. Every read of a Play setting is now inside `apps/game_stream`,
and the boundary test's env-var needle keeps it there (§ Guardrails). The same code runs in a
Mix run and in a release, so no config file has to carry these settings. The host release
keeps core's runtime config as its own (`runtime_config_path: "../platform/config/runtime.exs"`),
so the with-modules image reads core's environment exactly as the without-modules image does.
That option works (T5); stage 4 proves it on the built host release.

**What a module's Mix runs see (stage 3; the decision asked for in design review).** Under
Mix a module is the current project, so Mix evaluates the module's config files, not core's.
The module's dev and test config is therefore defined to be **core's, plus the module's
registration, and nothing else**:

- `apps/game_stream/config/config.exs` runs `import_config "../../platform/config/config.exs"`.
  That file imports core's `dev.exs` or `test.exs` relative to itself: the repo, the endpoint,
  the logger level, the test pool size, the OIDC stub, and so on. The module then adds
  `config :platform, :extensions, [Platform.GameStream.Extension]`.
- `apps/game_stream/config/runtime.exs` evaluates core's `runtime.exs` in place, with
  `Config.Reader.read!(core_runtime, env: config_env(), target: config_target())`, and applies
  every key it returns. Nested evaluation works; `import_config` is the only form Mix refuses.
  So the module's run has exactly the runtime config core's own `mix test` has (the Vault key,
  the execution and proof-of-life settings, and the rest).
- `apps/game_stream/test/test_helper.exs` is `Code.require_file` of core's `test_helper.exs`.
  That gives the same ExUnit exclusions, sandbox mode, org seeding and module preload, so the
  two harnesses cannot drift.
- The `test` alias creates the database and migrates `Platform.Release.migrations_paths/1`
  (core's path, then Play's) with `-r Platform.Repo`. Play owns no repo.
- **TURN in tests:** unset, so `ice_servers/0` is `[]`. Cases that need it `put_env
  :game_stream, :turn`, and `turn_test.exs` drives `RuntimeConfig.read/1` over the real OS
  environment. **Flag in tests:** unset at boot, so Play is off. Cases toggle
  `:game_stream, :enabled` and restore it. **Repo:** core's `Platform.Repo` on
  `PLATFORM_TEST_DATABASE`, as in core.

This is exactly what CI's with-Play job (stage 4) will prove, because it is the module's own
`mix test`. `apps/burrow_release` uses the same two config files, plus the two asset profiles.

### 9. Install safety at merge

Stage 3 removes `GAME_STREAM_ENABLED` as a code gate: the module is present or absent. The
installs table shows three production installs on one tag, `suite-core:latest`, with the flag
set on one (Install A) and unset on two (Install B, Install C). After the flag is gone:

- if `latest` is the with-Play image, Install B and Install C gain Play on the webhook restart
  that follows the merge: the `game_stream` canvas kind validates, the `play` tools join the
  full catalogue and the runtime channel accepts play frames;
- if `latest` is the without-Play image, Install A loses Play and its two `play` grants go inert.

Either way an install changes behaviour, so "a merge before the repoint changes nothing" is
true **only if the flag survives inside the module until the repoint**. Decision:

1. The flag stays, **inside the Play module only**, as a transitional gate, exactly as stage 2
   leaves it. With it unset, a with-Play image behaves exactly as main does with the flag
   unset, which is every install's behaviour today. That is **not** the same as a
   without-Play image, and an earlier version of this item wrongly said Play's extension
   "returns empty lists from every callback". What main actually does with the flag unset:
   - the `play` bundle stays known and grantable, but lists no tools;
   - a `play_session_*` call gets the `game_stream_disabled` refusal, not the unknown-tool
     error;
   - the three play frames are owned and dropped (logged once per socket);
   - the live hooks, both experiment surfaces and both metrics stay registered;
   - only the `game_stream` canvas kind is withheld.

   Stage 2 kept exactly that, and stage 3 moved it unchanged. The read happens at boot in
   `Platform.GameStream.RuntimeConfig` (§ 8). Core never reads the flag.
2. Stage 4 publishes both flavours. `latest` stays the with-Play image, and a without-Play tag
   is published beside it.
3. core-ops repoints Install B and Install C to the without-Play tag, and Install A to an explicit
   with-Play tag.
4. Only then does a follow-up remove the in-module flag. That change is one file inside
   `apps/game_stream`, because core has none.

This departs from stage 3's text, which removes the flag outright. With the flag removed
before step 3, a merge changes Install B and Install C.

**Stage 3 alone must not merge.** The existing `apps/platform/Dockerfile` builds
`apps/platform` alone, which since stage 3 is the **without-Play** build. If stage 3 merged
before stage 4 publishes `latest` as the with-Play host image, Install A would lose Play on the
webhook restart. Step 2 is what keeps every install's behaviour.

**Stage 4: what the merge does, measured.** Read-only on test-host, 2026-10-02:

| Install | Container | Image | `GAME_STREAM_ENABLED` | Play versions in its DB |
|---|---|---|---|---|
| Install A | `core-platform` (:4000) | `suite-core:latest`, `AutoUpdate=registry` | set, `true` | both |
| Install B | `core-platform-b` (:4200) | `suite-core:latest`, `AutoUpdate=registry` | unset | both |
| Install C | `core-platform-c` (:4300) | `suite-core:latest`, `AutoUpdate=registry` | unset | both |

The three containers ran image revision `237374145` (origin/main). `core-platform-exp`
runs `elixir:1.19-otp-27` and no `suite-core` tag, so the tag mapping does not touch it.
The env was read as names only, plus a count of exact `GAME_STREAM_ENABLED=true|1` matches.

That is the case no single-tag mapping can settle by the image alone: two installs share
one tag with different flag values. The in-module flag from step 1 is what settles it.
Stage 4 implements step 2 in `.github/workflows/ci.yml`:

- `latest`, `<sha>` and `<short_sha>` are the with-Play image, as are `play`, `play-<sha>`
  and `play-<short_sha>`;
- `core`, `core-<sha>` and `core-<short_sha>` are the without-Play image, pushed first so
  that `latest` is the last tag to move.

So **the merge changes no install's product surface, and no quadlet has to change before
it.** Install A keeps Play because the flag is set. Install B and Install C keep it off, because
the with-Play image with the flag unset behaves as main does with it unset. This was
verified for a merge-base DB by `scripts/module-enable-later-rig.sh prod-like` (§ Proof).

The proposal for core-ops (step 3), to make after the merge, in any order:

- `core-platform.container`: `Image=docker.io/example/suite-core:play`.
- `core-platform-b.container` and `core-platform-c.container`:
  `Image=docker.io/example/suite-core:core`.

Each is followed by `systemctl --user daemon-reload` and a restart of that unit. After all
three, follow-up 1 removes the flag.

**What changes product surface, and when:**

- Removing the in-module flag (follow-up 1) before Install B and Install C are repointed:
  both gain Play on their next restart. The `play` tools join the catalogue for any
  runtime granted the bundle, the `game_stream` canvas kind validates, and play frames
  are accepted.
- Moving `latest` to the without-Play image while Install A still pulls `latest`: Install A loses
  Play. Its `play` grants go inert, and `play_session_*` calls get the unknown-tool
  refusal.
- Repointing Install B or Install C to `core` before follow-up 1: no visible change. Their
  Play is already off. They stop carrying Play's code, and the two `game_stream.*`
  experiment surfaces and metrics leave their registries.
- Repointing Install A to `play`: no change.

### 10. How to add a module to an install

One place, implemented by stage 4 and documented beside the install manifest, in
[`deployment/schema/install-modules.md`](../../deployment/schema/install-modules.md):

1. The module is built into a published image flavour (CI builds one release host per
   supported module set).
2. Add the module to the install's manifest `modules` field (ADR 0053's manifest; stage 4
   adds it as `[install] modules = ["play"]`). The renderer maps the module set to the image
   flavour tag (`suite-core:core` or `suite-core:play`). Until follow-up 1, it also sets Play's
   transitional `GAME_STREAM_ENABLED=true` on core-platform, so the line is still the whole
   edit.
3. Render and deploy. `Platform.Release.migrate/0` runs on boot and applies the module's
   migrations, out of order if need be (§ 6). No manual SQL and no second step.

Removing a module is the same edit in reverse. Its tables and grants stay (§ 6, § 7).

## Inbound references and the seam that replaces each

Measured on `eb30c8593`. "Moves" means the file moves to `apps/game_stream` in stage 3 with its
module name unchanged.

| Reference in core | What it does | Seam |
|---|---|---|
| `lib/platform/chat/canvas/kinds.ex:72` | `gated_modules/0` returns the Play kind when the flag is on | `canvas_kinds/0` |
| `lib/platform/chat/canvas/kinds.ex:144` | `describe("game_stream")` | the kind module's own `describe/0` |
| `lib/platform/chat/canvas/kinds.ex:16-19` | moduledoc names the Play kind | rewritten in neutral prose |
| `lib/platform/federation/tool_surface.ex:82` | `@bundles` includes `play` | core bundles plus `Extensions.tool_bundles()` names, per call |
| `lib/platform/federation/tool_surface.ex:259` | `tools_for_bundle("play")` | one generic extension clause |
| `lib/platform/federation/tool_surface.ex:7513` | `execute("play_session_" <> _)` | dispatch to the extension that owns the tool name |
| `lib/platform/federation/tool_authorization.ex:166-181` | `disabled_play_tool?/1` refusal text | inside Play's extension (keeps `game_stream_disabled` while § 9's flag lives) |
| `lib/platform/agents/agent_runtime.ex:27` | `@valid_bundles` includes `play` | core bundles plus extension bundle names; persisted bundles tolerated (§ 7) |
| `lib/platform_web/live/control_center/runtime_panel.ex:131` | checkbox per valid bundle | renders persisted orphan bundles disabled (§ 7) |
| `lib/platform_web/channels/runtime_channel.ex:280-327` | three `handle_in` clauses for play frames | one clause dispatching on `Extensions.runtime_event_owner/1` |
| `lib/platform_web/channels/runtime_channel.ex:793` | `Platform.GameStream.host_disconnected/1` | `Extensions.runtime_disconnected/1` |
| `lib/platform_web/channels/runtime_channel.ex:808-821` | `log_play_frame_disabled/2` | kept, generalised to "unowned runtime event" |
| `lib/platform_web/live/chat_live.ex:57`, `:802` | alias and `GameStreamHooks.attach()` | `PlatformWeb.Extensions.attach_live_hooks/1` |
| `lib/platform_web/live/canvas_live.ex:117`, `:124`, moduledoc `:101-106` | alias, attach, moduledoc | same |
| `lib/platform_web/live/meeting_live.ex:439`, `:551` | two attach calls | same |
| `lib/platform_web/live/tasks_live.ex:144` | attach call | same |
| `lib/platform/experiments/surfaces.ex:57-72` | `GameStreamEncoder`, `GameStreamRoster` in `@surfaces` | `experiment_surfaces/0` |
| `lib/platform/experiments/metrics.ex:122-132` | two Play metric slugs in the registry | `experiment_metrics/0` |
| `lib/platform/application.ex:62-65` | starts `Platform.GameStream.Supervisor` | the module's own `Application.start/2` (§ 3) |
| `lib/platform/release.ex:17`, `:23` | `migrate`/`rollback` over the default path | `[core_path \| Extensions.migrations_paths()]` (§ 6) |
| `config/runtime.exs:494-549` | flag and TURN config | read by the module (§ 8) |
| `assets/js/hooks/index.js:17`, `:79` | imports and registers the `GameStream` hook | `@extensions` alias (§ 4) |
| `assets/css/app.css:8238` | fullscreen `game_stream` styles | moves; host wrapper stylesheet (§ 4) |
| `assets/css/app.css:37` | `@source "../../lib/platform/chat/canvas/kinds"` covers the Play kind's classes | module `tailwind_sources` (§ 4); the core line stays for core kinds |
| `lib/platform/meetings.ex:6875` | comment naming `Platform.GameStream` | neutral prose |
| `lib/platform/federation.ex:197` | comment naming `Platform.GameStream` | neutral prose |
| `lib/platform/chat/canvas/kinds/game_stream.ex` | the Play kind | moves |
| `lib/platform/experiments/surfaces/game_stream_{encoder,roster}.ex` | Play surfaces | move |
| `lib/platform/experiments/metrics/game_stream_input_to_photon{,_p95}.ex` | Play metrics | move |
| `lib/platform_web/live/game_stream_hooks.ex` | Play LiveView hooks | moves |
| `lib/platform/federation/play_tools.ex` | Play tool definitions | moves |
| `lib/mix/tasks/platform/seed_play_host.ex` | seed task | moves |
| `test/platform/experiments/guardrails_test.exs:87-88` | names two Play surface keys | derive from `Surfaces.list()` or move |
| `test/platform/responsibilities/experiments_scientist_test.exs:250-251` | same | same |
| `test/platform/regression/pubsub_topic_inventory_audit_test.exs:163` | `game_stream:<id>` topic | moves to a module-side inventory |
| `test/platform/repo_lookup_boundary_test.exs:274-278` | entries for `game_stream/review_build.ex` and `seed.ex` | move to a module-side test |
| `test/security/transport_capability_parity_test.exs:79-83` | a grant list including `play` | moves where the module is present |
| `test/platform_web/live/chat_live_code_line_ratchet_test.exs:448` | explains the alias line in the ratchet | updated with the stage-2 call, no ratchet raised |
| `test/platform_web/live/tasks_live_board_invariance_test.exs:944-949` | explains the attach line | same |

Play-owned tests (`game_stream_test.exs`, `game_stream/*`, `federation/play_tools_test.exs`,
`chat/canvas/kinds_game_stream_test.exs`, `experiments/surfaces/game_stream_*`,
`experiments/metrics/game_stream_*`, `repo/migrations/add_player_dimensions_to_game_stream_sessions_test.exs`,
`platform_web/channels/runtime_channel_game_stream_test.exs`,
`platform_web/live/game_stream_hooks_test.exs`) move with the module. The plan counted 8
core test files; this table lists 7, because it counts the migration test as Play-owned.

## Consequences

### Positive

- A without-Play install carries no Play code, no Play tools, no Play JS and no flag.
- Enabling a module later is a manifest line and a deploy; its migrations run on boot.
- The next module (Social) reuses the contract and adds only the readers it needs.
- A reference from core to a module is a compile error in the without-modules build, which
  CI already runs with `--warnings-as-errors`.

### Tradeoffs

- Two lockfiles that must agree (§ 1), enforced by a CI check rather than by construction.
- Every module and host compiles core into its own `_build`.
- Rows a module wrote outlive it on installs that drop it (§ 6, § 7).
- The Play flag survives inside the module until installs are repointed (§ 9).

## Guardrails

- Core never names a module. Two layers hold this. First, the without-modules `MIX_ENV=dev mix
  compile --warnings-as-errors` fails on a code reference. Second,
  `apps/platform/test/platform/extension_boundary_test.exs` scans
  `apps/platform/{lib,config,assets/js,assets/css,test}` for three kinds of needle, all derived
  from the sibling projects under `apps/` and never from a prefix:
  - every module name their `defmodule`s declare (lib and test, nesting resolved);
  - every compound CamelCase segment of their lib modules that no core, Elixir, OTP or
    dependency module uses (so a `Module.concat/1` of pieces is still seen; one-word segments
    such as `Seed` collide with prose and are left to the full names);
  - every OS environment variable name their lib reads.

  Each silence has a positive control: a scan of the module's own lib must hit, and planted
  snippets of each shape must be caught.
- `config :platform, :extensions` is read per call, never at compile time. **The one exception is
  a compiled seam** (the router, when `routes/0` gains its reader): it reads the list with
  `Application.compile_env(:platform, :extensions)`, which Mix checks against the runtime value at
  boot. Everything else reads it per call through `Platform.Extensions`.
- No extension may reuse a name core owns, and no two extensions may share one, in any merged
  registry: tool bundle names, tool names, runtime-channel event names, canvas kind names,
  experiment surface keys and metric slugs. `Platform.Extensions.validate!/0` enforces it at boot
  and names both owners; a test holds it with a fixture that clashes with core.
- A tool call reaches an extension by exact name first, looked up in a map built from each bundle's
  owned `tool_names` and its `definitions`; core matches no prefix. Only on a miss is a bundle's
  own optional `owns_tool?` claim asked (Play reserves `play_session_*`, so an unknown name in it
  keeps main's Play-owned `unknown_tool` refusal), and a claim that covers a core tool name is a
  clash `validate!/0` refuses.
- Migration versions are unique across all paths. A module migration may reference only stable
  core tables; core never references a module table.
- Every `apps/*/mix.lock` locks each entry of `apps/platform/mix.lock` exactly as core does
  (§ 1). A module's own extra deps are allowed. The ExUnit test and the CI step both list every
  lockfile on disk, so core names no module.
- A module's callbacks tolerate the module's own processes being absent (§ 3).
- A without-modules install keeps what a module wrote: tables are not dropped and grants are
  not stripped (§ 6, § 7).

## Follow-up

1. Remove the in-module `GAME_STREAM_ENABLED` gate after core-ops repoints every install (§ 9).
2. The first consumer of `routes/0`, `telemetry_handlers/0`, `responsibility_providers/0` or
   `prompt_templates/0` builds its reader.
3. Email (`MAIL_ENABLED`, the only env-gated rail entry) as a module.
4. A per-install decision on dropping orphaned module tables.

## Proof

### Composition spike (option B, with option A for comparison)

Throwaway, never pushed and never merged. Run 2026-09-29 on test-host in podman with
`localhost/core-test:1.19.5-otp-28-slim-cc` (`elixir:1.19.5-otp-28-slim` plus ca-certificates,
git and build-essential, the image `core-test.sh` uses), from a clone of `eb30c8593` in a
scratch directory. The spike committed `apps/game_stream` and `apps/suite_release` on a local
branch, `spike/01a0ee08-c2ec-7001-89d2-c888d6a7b73e`, which existed only inside that clone and
was deleted with it.

Spike files (all outside `apps/platform`):

- `apps/game_stream/mix.exs`: `deps: [{:platform, path: "../platform", env: Mix.env()}]`;
- `apps/game_stream/config/config.exs`: `import_config "../../platform/config/config.exs"`;
- `apps/game_stream/lib/game_stream/spike.ex`: one remote call into core,
  `Enum.map(Platform.Experiments.Surfaces.list(), & &1.key())`;
- `apps/suite_release/mix.exs`: `deps: [{:platform, path: "../platform", env: Mix.env()},
  {:game_stream, path: "../game_stream", env: Mix.env()}]`, and the same two-line config.

Every step ran in the container with `MIX_HOME`/`HEX_HOME` copied from the rig's warm cache.
Exit codes are the command's own.

| Step | Command (cwd) | Exit | Notes |
|---|---|---|---|
| S1 | `mix deps.get && MIX_ENV=dev mix compile --warnings-as-errors` (`apps/platform`, before the spike commit) | 0, 0 | baseline, 83 s |
| S2 | `git diff --stat eb30c8593 -- apps/platform` after committing the spike | 0, empty | the spike touches nothing in `apps/platform` |
| S3 | `MIX_ENV=dev mix compile --force --warnings-as-errors` (`apps/platform`, module present) | 0 | "Compiling 880 files (.ex)"; the without-Play build is unchanged |
| S4 | `mix deps.get && MIX_ENV=dev mix compile --warnings-as-errors` (`apps/game_stream`) | 0, 0 | compiles core into `apps/game_stream/_build`, then "Compiling 1 file", "Generated game_stream app" |
| S5 | S4's compile with `Platform.DoesNotExistAnywhere.call()` planted in `apps/game_stream` | **1** | positive control: a module's reference into core is checked (`...is undefined`) |
| S6 | S3's compile with `GameStream.Spike.surface_keys()` planted in `apps/platform/lib` | **1** | positive control for stage 3's boundary layer 1: core referencing a module fails the without-modules compile (`GameStream.Spike.surface_keys/0 is undefined`) |
| S6b | S3's compile after removing the plant | 0 | |
| S7 | `MIX_ENV=test mix compile --warnings-as-errors` (`apps/game_stream`) without a test-env `deps.get` | 1 | `mox`, `icalendar`, `lazy_html` "not available": core's `only: :test` deps are fetched only for the env `deps.get` ran in |
| T1 | `MIX_ENV=test mix deps.get && MIX_ENV=test mix compile --warnings-as-errors` (`apps/game_stream`) | 0, 0 | core compiles in test env as a dep, including its `test/support`, 96 s |
| S8 | `mix deps.get && MIX_ENV=dev mix compile --warnings-as-errors` (`apps/suite_release`) | 0, 0 | the release host compiles core plus the module, 85 s |
| T2 | `git status --porcelain -- apps/platform` after every build | 0, empty | no build writes into `apps/platform`'s tracked tree |
| T3 | hex entries of `apps/platform/mix.lock` against `apps/suite_release/mix.lock` | n/a | at least 40 of core's packages differ: 9 absent (test-only, e.g. `mox`, `lazy_html`, `icalendar`) and at least 31 at another version (`phoenix` 1.8.5 to 1.8.15, `phoenix_live_view` 1.1.27 to 1.1.33, `postgrex` 0.22.0 to 0.22.4). This is why § 1 requires the lockfile check |
| S9 | option A: root `mix.exs` with `apps_path: "apps"`; `apps/game_stream` with `{:platform, in_umbrella: true}`; `mix deps.get && MIX_ENV=dev mix compile --warnings-as-errors` (repo root) | 0, 0 | created root `deps/`, `_build/` and `mix.lock`; compiled `platform`, `game_stream` and `suite_release` together |
| S9b | `MIX_ENV=dev mix compile --warnings-as-errors` (`apps/platform`, umbrella present) | 0 | |
| S9c | `MIX_ENV=dev mix compile --warnings-as-errors` (`apps/game_stream`, umbrella child) | **1** | every dependency "not available": an umbrella child cannot build alone |

Release configuration, checked with a two-file project in the same image:

| Step | What | Exit | Result |
|---|---|---|---|
| T4 | `import_config` inside `config/runtime.exs`, under `mix run` | 1 | `import_config/1 is not enabled for this configuration file` |
| T5 | `releases: [tiny: [runtime_config_path: "other/runtime.exs"]]`, then `bin/tiny eval` | 0 | the release evaluated `other/runtime.exs` |
| T6 | a release runtime config that calls `import_config` | 1 | boot fails: the imported file is not shipped in the release |

**What the spike proves.** Option B composes: a module and a release host compile against core
(dev and test envs) with `--warnings-as-errors`, `apps/platform` compiles unchanged beside them,
no build writes into `apps/platform`, and a reference from core to a module fails core's own
compile.

**What it does not prove.** It built no release of the host, no assets and no image, and ran no
module tests against a database. Those are stage 3 (assets, module tests) and stage 4 (image
flavours, release migrate). T4 also leaves an open item for stage 3: under Mix, a host's or
module's own `config/runtime.exs` cannot import core's, so how a with-modules dev or test run
evaluates core's `runtime.exs` must be settled there. For releases, T5 shows
`runtime_config_path` works (§ 8).

### Stage 3: Play moved, both flavours measured

Measured on test-host in podman: `localhost/core-test:1.19.5-otp-28-slim-cc` for Mix, and
`node:24-slim` for JS. The baseline is the stage 2 tip, `79191cba2`.

**The move.** 44 files moved with `git mv`, all detected as renames against `79191cba2`:

- 17 lib files;
- both migrations, with identical filenames, versions and module names;
- 11 ExUnit test files;
- 14 asset files (the 7 hook files and the 7 vitest files).

The `app.css` fullscreen block moved into `apps/game_stream/assets/css/game_stream.css`. Core
keeps no `GAME_STREAM_*` read and no Play module name.

**Test totals.**

- Without Play (core alone, the test rig's mix-test wrapper): 20,150 before, 19,997 after, with 0
  failures, 3 skipped and 44 doctests.
- With Play (`apps/game_stream`'s own `mix test`): 181 tests, 0 failures.

They reconcile as follows.

The 11 moved test files held 158 tests at `79191cba2`.

Core lost 172 tests, and every one moved to the module:

- the 158 in the moved files;
- 7 Play cases from `extensions_test.exs`: the parity describe (5), the Registry-stopped case
  and the configured-list clash case;
- the 6 `play` grant-set cases from `transport_capability_parity_test.exs`;
- the stage-2 `children/0` case, which was retired along with the callback. This is the one
  that does not appear in the module.

Core gained 19 new tests:

- 3 asset-registry cases in `extensions_test.exs`;
- 2 without-modules parity cases;
- 4 boundary cases in `extension_boundary_test.exs`;
- 4 migration-path cases in `migration_paths_test.exs`;
- 6 rollback-guard cases in `release_test.exs`.

That gives 20,150 − 172 + 19 = 19,997.

The module's 181 break down as:

- 158 from the moved files;
- 7 moved from `extensions_test.exs`;
- 6 moved from `transport_capability_parity_test.exs`;
- 10 new: 4 in `module_inventory_test.exs` (the guardrails and scientist surface lists and the
  PubSub and `Repo.get` inventories, moved from core, where those files kept their test
  counts), 3 in `application_test.exs` and 3 in `release_rollback_test.exs`.

**JS.**

- Core vitest: 741 tests in 46 files at `79191cba2`, and 610 in 39 files after the move.
- The module's vitest: 131 tests in 7 files, so 610 + 131 = 741.
- Core `node --test`: 70 before and 71 after. The one added is the flavour-aware bundle case.

For the byte counts, see § 4.

**Mutations.** Each ran in a scratch clone of the tip and was restored with `git checkout`
(the clone had no uncommitted work). Every mutation below turned its target red, and every
restore turned it green again.

| Plant | Guard | Result |
|---|---|---|
| `Platform.GameStream.Session.whereis(1)` in `lib/platform/chat.ex` | boundary test | red: `chat.ex:6122`, three needles (two full names and the `GameStream` segment) |
| same | `MIX_ENV=dev mix compile --warnings-as-errors` | exit 1: `Platform.GameStream.Session.whereis/1 is undefined` |
| `alias PlatformWeb.GameStreamHooks, as: H` in `chat_live.ex` | boundary test; dev compile | red at `chat_live.ex:21`; exit 1 (`unused alias H`) |
| `"Elixir.Platform.Federation.PlayTools"` in `config/config.exs` | boundary test | red at `config.exs:465`: full name and `PlayTools` segment |
| a copy of core's `20260928230000` as `apps/game_stream/.../20260928230000_planted_duplicate.exs` | `migration_paths_test.exs`; CI shell step | red, naming both files; the CI step failed on `20260928230000` |
| `>=` changed to `>` in `Release.module_versions_crossed/2` | `release_test.exs` | red (1 failure) |
| rollback refusal removed (`if true do`) | the module's `release_rollback_test.exs` | red (1 failure) |

The first run of the chat.ex plant was **void**: its plant step used `python3`, which the
core-test image does not have. That run reported green, so the plant is marked void rather
than counted as a result. It was rerun with `perl`; the results above are from that rerun.

### Stage 3, resumed: origin/main merged in and re-measured

On 2026-10-02 the branch merged `origin/main` at `237374145`, seven commits past `eb30c8593`.
Two of them changed Play while it was being extracted, and both were ported into
`apps/game_stream` rather than left in core:

- #1158 (task 01a0ee4f, the inline Play canvas). The kind's `inline_opens_canvas?/0` joins
  its `describe/0` in `apps/game_stream`. The click-to-open opt-out in core's
  `PlatformWeb.Chat.CanvasRenderer` is a generic convention that any kind may export, so it
  stays in core and names no module. The two new ExUnit files moved to the module, with the
  flag key ported to `:game_stream, :enabled`. So did the vitest file and the hook changes.
- #1163 (task 01a0f84e, game stream audio). `game_stream_audio.js` and its vitest file moved
  to the module.

Re-measured on test-host at the resumed tip, with the same images as above:

- **Core alone:** 20,083 tests, 44 doctests, 0 failures, 3 skipped. Main at `237374145` has
  20,218. The difference is reconciled as follows:
  - +28 from stage 2;
  - −172 moved and +19 new, both as recorded above;
  - −15 that main added to Play test files and that moved with them: 11 in
    `canvas_renderer_game_stream_test.exs`, 1 in `chat_live_game_stream_inline_test.exs` and
    3 in `kinds_game_stream_test.exs`;
  - +5 in the lockfile test.
- **The module's suite:** 196 tests, 0 failures. That is 181 + 15.
- **JS:**
  - core vitest 625 in 39 files, and core node 71;
  - the module's vitest 170 in 9 files;
  - the bundle cap passes in both flavours: `app.js` is 792,169 bytes without modules and
    831,949 bytes with Play.
- **Lockfile gate**, run in a scratch clone of the tip. Both the ExUnit test and the CI step:
  - pass at the tip;
  - fail on a planted `phoenix` version change in `apps/game_stream/mix.lock`, naming the file,
    the package, and both versions;
  - fail on a planted removal of `postgrex` from `apps/suite_release/mix.lock`;
  - pass again once the plants are restored.


### Stage 4: both images built, booted and switched on test-host

Both flavours were built with podman on test-host from the branch at `ec8c101e6`. They were built
before that commit's message was reworded, as `e48204fc8`; the tree is the same, and the older
sha is the one in `priv/build_commit`. The image inputs
have not changed since; later commits touch only the ADR text, the installer, the CI
workflow and the rig scripts.

- **without modules:** `apps/platform/Dockerfile`, 133 s warm;
- **with Play:** `apps/suite_release/Dockerfile`, 116 s warm.

Contents of each image, read from inside it:

| | without modules | with Play |
|---|---|---|
| apps in `/app/lib` | `platform` | `platform`, `game_stream`, `suite_release` |
| `app.js` | 792,169 bytes, no `game_stream_attach` | 831,949 bytes, contains it |
| `app.css` | 453,652 bytes | 455,748 bytes |
| Play migrations in the release | none | both, under `game_stream-0.1.0/priv` |
| ADR corpus, `priv/build_commit` | 59 files, the commit | the same |

**A defect the first with-Play image had, and the guard that now catches it.** The first
with-Play build lacked 129 of core's CSS rules, and every one of them was a `hero-*` icon.
Core's heroicons Tailwind plugin reads `apps/platform/deps`, which a release-host build does
not have, and it skips a missing root silently. Nothing failed.

- The plugin now takes `SUITE_HEROICONS_DIR`, which the host's Tailwind profile sets to its
  own deps.
- `scripts/check-flavour-css.sh` fails when the with-modules stylesheet lacks any of core's
  rules, and CI's `Test (with Play)` runs it.
- Measured with that script: on the defective pair it reports 129 missing; on the fixed pair
  it reports 0 missing (2,904 rules without modules, 2,930 with Play); on a file against
  itself it reports 0.

**`scripts/module-enable-later-rig.sh`** runs the images with their own CMD
(`Platform.Release.migrate()`, then `start`) against a private database on test-host's
`dev-postgres`. The database is named `rig_01a0ee08_<case>_<pid>` and is dropped on exit.

*enable-later*, at rig commit `5ad653c1d`:

1. The core image migrated a fresh database: 306 versions, neither of Play's.
2. Through core, the rig created a project, a task and an experiment.
3. The play image then booted on the same database. Its migrate ran exactly
   `20260926030000` and `20260928200000`, both older than core's newest (`20261001190000`).
   `schema_migrations` gained exactly those two and lost none.
4. The task and the experiment were intact. `game_stream_sessions` references `experiments`
   (twice: the encoder and roster arms) and `tasks`.
5. A play session was driven through the real transports:
   - an agent runtime granted `play` saw `play_session_start`, `play_session_status` and
     `play_session_stop` in `tools/list` over `POST /mcp`;
   - `play_session_start` returned `building`, and the fake host, joined over a real
     WebSocket on `/runtime/ws`, received the start frame;
   - after the host reported `live`, `play_session_status` returned `live`;
   - `play_session_stop` returned `ended`, and exactly one `game_stream_sessions` row was
     written.

   The only stub is the review build's branch head, which the rig pins with
   `:branch_provisioner, :runner`.

*prod-like*, at rig commit `5b26fe860`. The base image is origin/main's own build at the
merge-base `237374145`: the image the three installs run, tagged locally so auto-update
could not move it.

1. The base image migrated a fresh database: 308 versions, including both of Play's from
   the old path. The rig inserted one `game_stream_sessions` row.
2. The play image, with `GAME_STREAM_ENABLED` unset, ran no migration. Every version over
   its two paths is `up`, with no `** FILE NOT FOUND **`. A runtime granted only `play`
   gets the same answer from it as from the base image: no tools in `tools/list`, and
   `play_session_start` refused with `-32001 game_stream is disabled: GAME_STREAM_ENABLED is
   unset`.
3. The core image ran no migration and raised no error. It reports Play's two versions as
   applied with no file, which Ecto treats as applied and runs nothing for.
4. The play image a second time: again a no-op.

After every phase the row and `schema_migrations` were unchanged.

Every release log in both cases has exactly one `[error]` line. It is the same in all of
them, including the base image's: `prompt_template_missing key=meetings.summarize`, which
predates this task.

Every stop ended in SIGKILL, because the CMD's `/bin/sh -c` does not forward SIGTERM. This
is also true of the production containers today, and the task does not change it.
