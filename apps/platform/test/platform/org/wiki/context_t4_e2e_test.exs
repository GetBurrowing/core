defmodule Platform.Org.Wiki.ContextT4E2ETest do
  @moduledoc """
  T4 task-level adversarial review (ADR-0041).

  Five cases mirror the plan's e2e_behavior validations on the
  synthetic Task-level review stage (plan `019e42bf-edc9-79c1-b8e8-8a374cc143fb`,
  stage `019e42bf-edcb-7818-86de-693c049f3479`). The planner-authored
  `actions` / `expected` / `setup` text is reproduced in each test
  body so a review agent can cite the test outcome as evidence.

  Cases:

    A. Happy path mixed-namespace preamble — org + project pages in,
       non-preamble pages out, BEGIN/END annotation, lex within band.
    B. Budget overrun lex-drop — a fits, b drops, c+d still fit;
       deterministic across runs.
    C. Single-page paragraph-boundary truncation — bigref page cut at
       \\n\\n above budget cliff, literal `[truncated]` sentinel
       (per Sloane's override — NOT the HTML-comment form), used_tokens
       respects budget.
    D. Workspace isolation — same file_key in two workspaces, no leak.
    E. Output-shape stability — top-level keys of `ContextAssembler.build/1`
       unchanged (only :org), every :org value matches the annotation
       regex.

  Case 5 (scope-creep guard) is a `describe` block that fails the build
  if T4 drifted into T5/T6/T7 territory.
  """
  use Platform.DataCase, async: false

  alias Platform.Org.Wiki
  alias Platform.Org.Wiki.Context, as: WikiContext
  alias Platform.Org.WikiJournalEntry
  alias Platform.Org.WikiPage
  alias Platform.Repo

  setup do
    Repo.delete_all(WikiPage)
    Repo.delete_all(WikiJournalEntry)
    :ok
  end

  defp seed!(file_key, body, opts \\ []) do
    {:ok, page} = Wiki.upsert_page(file_key, %{content: body}, opts)
    page
  end

  defp preamble_body(body), do: "---\npreamble: true\n---\n" <> body
  defp non_preamble_body(body), do: "---\npreamble: false\n---\n" <> body

  defp begin_marker(file_key, version),
    do: ~s(<!-- BEGIN org-preamble page="#{file_key}" version="#{version}" -->)

  defp end_marker(file_key),
    do: ~s(<!-- END org-preamble page="#{file_key}" -->)

  # ── Case A: happy path mixed-namespace preamble ──────────────────────

  test "Case A — happy path: org + project preamble pages, lex within band" do
    # setup: org/identity.md (preamble:true, ~500 chars),
    #        project/proj-xyz/runbook.md (preamble:true, ~600 chars),
    #        org/notes.md (preamble:false, larger).
    seed!("org/identity.md", preamble_body(String.duplicate("I", 480)))
    seed!("project/proj-xyz/runbook.md", preamble_body(String.duplicate("R", 580)))
    seed!("org/notes.md", non_preamble_body(String.duplicate("N", 5000)))

    task = %Platform.Tasks.Task{project_id: "proj-xyz"}
    pages = WikiContext.build_preamble(task: task)

    # Map has exactly two keys.
    assert Enum.sort(Map.keys(pages)) ==
             ["org/identity.md", "project/proj-xyz/runbook.md"]

    # Each value wrapped in BEGIN/END markers with version="1".
    for fk <- ["org/identity.md", "project/proj-xyz/runbook.md"] do
      v = pages[fk]
      assert String.starts_with?(v, begin_marker(fk, 1) <> "\n")
      assert String.ends_with?(v, "\n" <> end_marker(fk))
    end

    # org/notes.md (preamble:false) is absent.
    refute Map.has_key?(pages, "org/notes.md")
  end

  # ── Case B: budget overrun, lex-order drop, deterministic ────────────

  test "Case B — budget overrun: a in, b dropped, c+d fit; deterministic" do
    # Approximate token-target setup. With the char/4 estimator:
    #   a: ~12000 chars ≈ 3000 tokens
    #   b: ~ 8000 chars ≈ 2000 tokens
    #   c: ~ 2000 chars ≈  500 tokens
    #   d: ~  800 chars ≈  200 tokens
    seed!("org/a.md", preamble_body(String.duplicate("a", 12_000)))
    seed!("org/b.md", preamble_body(String.duplicate("b", 8_000)))
    seed!("org/c.md", preamble_body(String.duplicate("c", 2_000)))
    seed!("org/d.md", preamble_body(String.duplicate("d", 800)))

    {:ok, run1} = WikiContext.build_preamble_with_metadata([])
    {:ok, run2} = WikiContext.build_preamble_with_metadata([])

    # a fits whole; b overflows the remaining budget after a; c and d
    # still fit because their token weight is small relative to remaining.
    assert Map.has_key?(run1.pages, "org/a.md")
    refute Map.has_key?(run1.pages, "org/b.md")
    assert Map.has_key?(run1.pages, "org/c.md")
    assert Map.has_key?(run1.pages, "org/d.md")

    # b appears in dropped with reason: :budget_overrun.
    assert Enum.any?(run1.dropped, &(&1.path == "org/b.md" and &1.reason == :budget_overrun))
    assert run1.truncated == []

    # Determinism: identical map keys and identical dropped order across
    # two independent runs.
    assert Enum.sort(Map.keys(run1.pages)) == Enum.sort(Map.keys(run2.pages))
    assert run1.dropped == run2.dropped

    # used_tokens stays under the default budget (4096).
    assert run1.used_tokens <= 4096
  end

  # ── Case C: single page exceeds budget, truncated with sentinel ──────

  test "Case C — single huge page truncates at paragraph boundary with [truncated] sentinel" do
    # ~24000 chars of realistic markdown with `\n\n` every ~500 chars.
    paragraphs =
      1..48
      |> Enum.map(fn n ->
        "## Section #{n}\n\n" <>
          String.duplicate("Lorem ipsum dolor sit amet consectetur. ", 12) <> "\n"
      end)
      |> Enum.join("\n")

    seed!("org/bigref.md", preamble_body(paragraphs))

    {:ok, meta} = WikiContext.build_preamble_with_metadata(budget: 4096)

    # Map has exactly one key.
    assert Map.keys(meta.pages) == ["org/bigref.md"]

    value = meta.pages["org/bigref.md"]

    # Value contains BEGIN marker.
    assert String.starts_with?(value, ~s(<!-- BEGIN org-preamble page="org/bigref.md"))

    # The literal `[truncated]` sentinel appears, preceded by \n\n
    # (paragraph-boundary join) and followed by \n then the END marker.
    # NOTE: T4 uses the literal `[truncated]` sentinel per Sloane's
    # binding override of the plan body's HTML-comment form. The
    # task-AC sentinel wins. Stage-1 recon note documents.
    suffix = "\n\n[truncated]\n" <> end_marker("org/bigref.md")
    assert String.ends_with?(value, suffix)

    # Truncation point lies on a \n\n paragraph boundary — verify by
    # inspecting the two chars immediately preceding the sentinel.
    marker_index = :binary.match(value, "\n\n[truncated]") |> elem(0)
    assert binary_part(value, marker_index, 2) == "\n\n"

    # truncated list has one entry with lost_tokens > 1000.
    assert [%{path: "org/bigref.md", lost_tokens: lost}] = meta.truncated
    assert lost > 1000

    # Used tokens respects budget.
    assert meta.used_tokens <= 4096
  end

  # ── Case D: workspace isolation ──────────────────────────────────────

  test "Case D — workspace_id scope: no cross-tenant leak" do
    workspace_b = Ecto.UUID.generate()

    seed!("org/global.md", preamble_body("content-A"))
    seed!("org/global.md", preamble_body("content-B"), workspace_id: workspace_b)

    nil_scope = WikiContext.build_preamble(workspace_id: nil)
    b_scope = WikiContext.build_preamble(workspace_id: workspace_b)

    # Each call returns exactly one page (org/global.md). BODY differs.
    assert Map.keys(nil_scope) == ["org/global.md"]
    assert Map.keys(b_scope) == ["org/global.md"]

    a_body = nil_scope["org/global.md"]
    b_body = b_scope["org/global.md"]

    assert String.contains?(a_body, "content-A")
    refute String.contains?(a_body, "content-B")

    assert String.contains?(b_body, "content-B")
    refute String.contains?(b_body, "content-A")
  end

  # ── Case E: output-shape stability ───────────────────────────────────

  test "Case E — only :org value shape changes; top-level keys unchanged" do
    # Seed an org preamble page so :org is non-empty downstream.
    seed!("org/identity.md", preamble_body("hi"))

    pages = WikiContext.build_preamble([])

    # :org is a %{String.t() => String.t()} map (we already verified
    # this at the WikiContext level — this case asserts the
    # downstream-visible shape is what call sites read).
    assert is_map(pages)
    assert Enum.all?(pages, fn {k, v} -> is_binary(k) and is_binary(v) end)

    # Every value matches the annotated-wrapper regex.
    for {_k, v} <- pages do
      assert Regex.match?(~r/^<!-- BEGIN org-preamble page="[^"]+" version="[0-9]+" -->\n/, v)
    end

    # No top-level keys leak from `WikiContext` into the caller — the
    # observable surface from build_preamble/1 is just the bare map.
    # (`build_preamble_with_metadata/1` is the only opt-in surface
    # for `used_tokens`, `dropped`, `truncated`.)
    assert Map.keys(pages) |> Enum.all?(&String.contains?(&1, "/"))
  end

  # ── Case 5: scope-creep guard ────────────────────────────────────────

  describe "Case 5 — scope-creep guard" do
    @t4_changed_lib_paths [
      "lib/platform/org/wiki/context.ex",
      "lib/platform/orchestration/context_assembler.ex",
      "lib/platform/chat/context_plane.ex",
      "lib/platform/orchestration/prompt_templates.ex"
    ]

    @t4_forbidden_paths [
      # T5 territory — Org.Context retirement; T5 will introduce a
      # successor module if needed.
      "lib/platform/org/context_v2.ex",
      # T6 territory — historian + cursors.
      "lib/platform/org/historian.ex",
      # T7 territory — OrgMemoryLive.
      "lib/platform_web/live/org_memory_live.ex"
    ]

    # T3 HEAD migrations (commit abffe51). T4 may legitimately add
    # `force_update` / `refresh_*` migrations to update prompt-template
    # row contents (the well-established pattern at
    # 20260505010000, 20260505020000, 20260506173000, 20260506210000,
    # 20260514210000). The guard below allow-lists that specific
    # migration; anything else fails.
    #
    # NOTE (T5 stage 3): the baseline was bumped from 92 to 95 when the
    # T5 worktree merged T4 HEAD on top of `main`, picking up three
    # tenancy migrations that landed on main after T4 branched
    # (20260519134626_add_preferences_to_users,
    #  20260519160000_refine_fabrikam_admin_membership_by_email_domain,
    #  20260519220000_add_roles_locked_at_to_org_memberships). The T5
    # stage-3 rename of 20260519220000 → 20260519220500 to resolve a
    # timestamp collision is also counted here. None of these are T4
    # additions, so the spirit of the guard (T4 stayed in scope on its
    # own branch) is preserved.
    #
    # NOTE (T5 stage 4): the T5 stage-4 search migration
    # (20260520020000_add_search_vector_to_org_wiki) is added under the
    # T5 allow-list below so the count assertion still pins the T4
    # boundary correctly.
    #
    # NOTE (T5 stage 5): two more T5 migrations are allow-listed below
    # — the prompt-template force-update for the V2 memory copy
    # (20260520010000) and the agent-runtime allowed_bundles swap from
    # `org_context` → `memory` (20260520030000).
    #
    # NOTE (stack rollup): the rollup branch merged T6 plus origin/main,
    # which together add four more legitimate migrations — T6's
    # historian dispatch-template force-update (20260520050000) and
    # three that landed on main after T5 branched (20260527160200,
    # 20260604000000, 20260604000100). Allow-listed below so the count
    # assertion keeps pinning the T4 boundary on the merged tree.
    @t3_head_migrations_count 95

    @t4_allowed_new_migrations [
      "20260520000000_refresh_dispatch_templates_for_wiki_preamble.exs",
      # T5 stage 4 additions (not T4 territory but tracked here so the
      # count guard stays accurate as the stack accumulates).
      "20260520020000_add_search_vector_to_org_wiki.exs",
      # T5 stage 5 additions (V1 retirement + capability bundle swap).
      "20260520010000_force_update_prompt_templates_memory_v2.exs",
      "20260520030000_agent_runtime_memory_bundle.exs",
      # Stack rollup additions — T6 historian templates + post-T5 main.
      "20260520050000_force_update_historian_dispatch_templates.exs",
      "20260527160200_backfill_meeting_chat_space_slugs.exs",
      "20260604000000_add_org_id_to_chat_spaces.exs",
      "20260604000100_create_channel_sections.exs",
      # Rollup, Sloane-authorized 2026-06-11: flat page keys → routing
      # page grammar (`<ns>/page/<rest>`) + alias backfill.
      "20260611120000_page_grammar_file_keys_and_alias_backfill.exs",
      # bumped by ADR 0042
      "20260618181114_adr_0042_org_project_topology.exs",
      # Task 019edbc1 stage 3: meeting-notifier idempotency CAS column.
      "20260619020818_add_notified_at_to_meetings.exs",
      # Tenant General routing fix (task 019edd8e): partial unique
      # index on chat_spaces(org_id, slug) so /chat/general resolves
      # per-tenant, not the oldest cross-tenant match.
      "20260618220754_add_chat_spaces_org_slug_unique_index.exs",
      # ADR 0042 — centralized document/file store (Stage 1).
      "20260619025255_create_platform_files.exs",
      # ADR 0042 — Stage 3: ingest status + chunk back-refs.
      # (Renamed from 20260618224933 → 20260619030000 in Stage 4 to land
      # after Stage 1's create_platform_files migration; fresh-DB rebuilds
      # were failing because the original timestamp ran before the table
      # existed.)
      "20260619030000_add_ingest_status_and_chunks_to_platform_files.exs",
      # ADR 0042 — Stage 4: cached extracted text for file_get_text MCP tool.
      "20260619040000_create_platform_file_texts.exs",
      # ADR 0042 — Stage 6: deliberate no-op tombstone. The original v3
      # plan called for a chat_attachments → platform_files backfill,
      # but Rowan rejected the project_id derivation as unsound for
      # org-level chat spaces. Promotion to Files is a future
      # user-driven surface; this migration exists so the plan engine
      # can advance past Stage 6 cleanly.
      "20260619050000_skip_backfill_chat_attachments_to_files.exs",
      # ADR 0041 M1 stage 1 (task 019ef65b-2099): responsibilities
      # registry table — declarative registry of feature
      # responsibilities the platform fulfills automatically. Foundation
      # for the M6 router + M8 cutover; no MCP surface, no engine wiring
      # in this stage.
      "20260623173008_create_responsibilities.exs",
      # ADR 0041 M1 stage 2 (task 019ef65b-2099): backfills the
      # `enabled` (operator kill-switch) and `metadata` (free-form
      # jsonb) columns onto `responsibilities`, plus the
      # `default_prompt_template` index the stage-1 spec called for.
      # No MCP surface, no engine wiring.
      "20260623230546_add_enabled_and_metadata_to_responsibilities.exs",
      # Responsibilities & External Agents stack, M2 stage 1
      # (task 019ef65b-4383): extend agents table with kind + external
      # endpoint columns (kind, endpoint_kind, base_url, model, vault_key).
      "20260624001634_add_external_kind_to_agents.exs",
      # ADR 0041 M4 stage 1 (task 019ef65b-a361): roles registry +
      # role_responsibilities join table. Platform-fixed role roster
      # (designer, historian, meeting_scribe, triage_officer) with the
      # `key` text as natural PK. responsibility_key has no hard FK to
      # M1's responsibilities table yet — deliberate per stage spec.
      "20260624011500_create_roles_and_bundles.exs",
      # ADR 0041 M4 stage 2 (task 019ef65b-a361): role_assignments +
      # responsibility_overrides tables. Unique index on
      # role_assignments(role_key) enforces one-agent-per-role
      # (Decision 1); unique index on
      # responsibility_overrides(responsibility_key) enforces
      # at-most-one override per responsibility (Decision 3). Both
      # cascade on agent + role deletion.
      "20260624012842_create_role_assignments_and_overrides.exs",
      # Task Canvas Attachments, stage 1 (task 019ef734): soft-reference
      # join table linking tasks to canvases for the upcoming
      # `task_attach_canvas` MCP tool. Schema + migration only; context
      # module + MCP tools + dispatch bundler land in stages 2-5.
      "20260624013019_create_task_canvas_attachments.exs",
      # ADR 0041 M4 stage 4 (task 019ef65b-a361): seed the four
      # platform-fixed roles (designer / historian / meeting_scribe /
      # triage_officer) and their responsibility bundles. Defers to
      # `Platform.Roles.Seeds.seed_defaults/0` (idempotent, on_conflict:
      # :nothing) so re-runs are safe. Responsibility keys align with
      # the v2 design canvas `019e0fb8-d87d-72b2-aab4-205b84fe23aa`
      # rev 3 — M8 will register the same keys in the Responsibilities
      # registry.
      "20260624013500_seed_default_roles.exs",
      # ADR 0041 M5 stage 1 (task 019ef65b-d04b): probe + liveness
      # observability columns on agents (last_probe_at,
      # last_probe_status, last_probe_latency_ms,
      # last_successful_fire_at). Column-only — writers land in M5
      # stage 2 (Platform.ExternalAgents.probe/1) and M6 (dispatcher).
      "20260624020000_add_probe_columns_to_agents.exs",
      # ADR 0042 — Files MCP Stage 3 (task 019efba0): relax
      # `platform_files.content_hash` to allow NULL on rows in
      # `ingest_status = "pending"`. Required by the `file_add` MCP
      # tool's presigned-upload branch which reserves a row BEFORE
      # bytes hit storage. The matching check constraint preserves the
      # post-upload invariant (non-pending rows MUST carry a hash).
      "20260625120000_allow_null_content_hash_for_pending_files.exs",
      # Chat-spaces NULL-scope slug duplication fix (2026-06-30):
      # adds two partial unique indexes — `chat_spaces_meeting_slug` on
      # `(slug) WHERE kind = 'meeting'` and
      # `chat_spaces_null_scope_channel_slug` on `(slug) WHERE kind='channel'
      # AND org_id IS NULL AND workspace_id IS NULL` — to close the
      # loophole that let `ChatLive.bootstrap_space/1` mint duplicate
      # channel rows on every visit to an unknown slug. Migration also
      # backfills the one lingering prod NULL/NULL channel row (SXI).
      "20260630000000_add_chat_spaces_meeting_and_null_scope_slug_indexes.exs",
      # Task 019f2451 stage 1: extend the closed-roster
      # `roles_key_check` CHECK constraint to admit the new
      # `meeting_producer` role. Schema-level `@valid_keys` bump lives
      # in `Platform.Roles.Role`; seed row + responsibility bundle land
      # in stages 2-3.
      "20260702000000_add_meeting_producer_to_roles_check.exs",
      # Historian retirement (task 019f2444) stage 1: one-shot data
      # backfill that reads legacy `agents.system_events @> '["historian"]'`
      # and materializes matching `role_assignments` rows for
      # `role_key = "historian"`, so the code cutover in later stages
      # (Routing.historian?/1, HistorianDispatcher.agent_for_event/1)
      # can trust Roles as source-of-truth. Idempotent via
      # ON CONFLICT (role_key) DO NOTHING; disagreement branch logs a
      # warning and leaves the existing Roles assignment untouched.
      "20260702192606_backfill_historian_role_assignments.exs",
      # Meeting Producer role — task 019f2451-6728 stage 2. Idempotent
      # re-seed so the row appears on existing envs where the stage-4
      # seed migration already ran.
      "20260702200500_seed_meeting_producer_role.exs",
      # Historian retirement (task 019f2444) stage 5: drop the legacy
      # `agents.system_events` column now that Roles is source-of-truth
      # (stages 1-4 backfilled + rewired + removed the UI). `down/0`
      # restores an empty column but does not re-synthesize Historian
      # flags — one-way door by design. Timestamp bumped from ...200500
      # to ...200600 during rebase to avoid Ecto version collision with
      # Meeting Producer's seed migration.
      "20260702200600_drop_system_events_from_agents.exs",
      # Task Sponsor (task 019f2482, ADR 0042): nullable
      # `tasks.sponsor_user_id` FK → users(id) with `on_delete: :nilify_all`
      # + partial index on non-NULL rows. Enables the human-shepherd field
      # distinct from the current-phase technical assignee.
      "20260702204229_add_sponsor_user_id_to_tasks.exs",
      # Auto-approve plan (task 019f25f2) stage 1: schema foundation for
      # the opt-in auto-approval flow. Adds `tasks.auto_approve_plan`
      # (bool, default false) and nullable `plans.auto_approved_at`
      # timestamp. State-machine wiring, MCP surface, UI, and serializer
      # expansion land in stages 2-5.
      "20260702210000_add_auto_approve_to_tasks_and_plans.exs",
      # Prompt templates for closed-roster responsibilities (task
      # 019f2455, PR #480). Four seed migrations that shipped without
      # a matching allow-list bump — captured here so the T4 boundary
      # guard keeps pinning the migration count on the merged tree.
      "20260703120000_seed_designer_prompt_templates.exs",
      "20260703120100_seed_prompt_template_propose_long_term.exs",
      "20260703120200_seed_prompt_templates_meeting_scribe.exs",
      "20260703120300_seed_prompt_templates_triage_officer.exs",
      # Responsibility-router heartbeat (task 019f2566) stage 1: adds
      # nullable `meeting_transcripts.router_dispatched_at` +
      # partial index (WHERE status = 'processing') so the
      # SummarizerSweeper GenServer (stage 2) can cheaply scan for
      # dispatches that stalled without their agent claiming the work.
      # Column-only + `Meetings.stamp_router_dispatched/1` helper; the
      # Summarizer wire-in and sweeper land in later stages.
      "20260704140000_add_router_dispatched_at_to_meeting_transcripts.exs",
      # Phantom-fix v4 (task 019f3312) stage 4: one-shot cleanup of the
      # 2026-07-04 01:15-01:30Z LiveKit phantom transcript flood. Stages
      # 1 and 2 closed the source (room-guard + HMAC-JWT webhook
      # signature); this migration removes the stranded orphan rows.
      # Predicate is narrow: empty-segments + in-flight status + inside
      # the exploit window.
      "20260706120000_cleanup_livekit_phantom_flood_2026_07_04.exs",
      # vectorize-tasks (task 019f3dbb) stage 1: `tasks.search_vector`
      # (Postgres generated tsvector) + GIN index + `task_references`
      # derived table with the migration's own idempotent backfill for
      # description → uuid references. Semantic embeddings ride the
      # memory-service substrate in stage 2; nothing pgvector lands here.
      "20260708120000_add_search_vector_and_task_references_to_tasks.exs",
      # Meeting Producer's `meetings.intent_classify.v1` prompt template
      # (task 019f2451-b627) stage 1: seeds the classifier prompt row
      # that `Handlers.IntentClassify.register/0` already references via
      # `default_prompt_template:`. Small local classifier with closed
      # intent enum, closed target_role enum, dedupe_key normalization
      # rules, and 5 worked examples including a paraphrase-stability
      # pair. Idempotent upsert on slug; drift-guarded against the
      # handler's `template_slug/0` accessor (stage 2).
      "20260707120000_seed_prompt_template_intent_classify.exs",
      # Task 019f3e8e-4406 stage 1 — Security Guard role admits new
      # `security_guard` key to the closed enum, then re-seeds the row
      # so existing environments pick it up (see ADR-0043).
      "20260708000000_add_security_guard_to_roles_check.exs",
      "20260708000100_seed_security_guard_role.exs",
      # ADR-0044 stage 1 (task 019f3da3) — architect responsibility
      # registration seam. Three migrations land together: seed three
      # placeholder `architecture.*` prompt templates so the
      # closed-roster template-coverage test resolves the new bundle
      # keys, extend the roles CHECK constraint to admit the `architect`
      # key, and re-seed the roles table so existing envs pick up the
      # `architect` row.
      "20260708120100_seed_prompt_templates_architect.exs",
      "20260708120150_add_architect_to_roles_check.exs",
      "20260708120200_seed_architect_role.exs",
      # ADR-0044 stage 3 (task 019f3da3) — force-update the
      # architecture.review_plan.v1 template body from the placeholder
      # stage-1 seed to the real plan-time review prompt. Mirrors the
      # `force_update_*` migration pattern at 20260520010000.
      "20260708123000_force_update_architect_review_plan_template.exs",
      # ADR-0044 stage 4 (task 019f3da3) — force-update the
      # architecture.audit_diff.v1 template body from the placeholder
      # stage-1 seed to the real post-executor drift-audit prompt.
      # Mirrors the sibling stage-3 migration at 20260708123000.
      "20260708124000_force_update_architect_audit_diff_template.exs",
      # ADR-0044 stage 5 (task 019f3da3) — force-update the
      # architecture.cron_sweep.v1 template body from the placeholder
      # stage-1 seed to the real weekly cron-sweep prompt. Mirrors the
      # sibling stage-3 / stage-4 migrations at 20260708123000 / 124000.
      "20260708125000_force_update_architect_cron_sweep_template.exs",
      # Task 019f3e8e-4406 v2 stage 1 — Security Guard prompt templates
      # (`security.cve_scan.v1`, `security.code_audit.v1`,
      # `security.deploy_audit.v1`, `security.secret_leak.v1`). The
      # responsibility rows are flipped to point at these slugs in v2
      # stage 2; the seed migration lands here so the templates are
      # editable via `/admin/prompts` as soon as v2 stage 1 deploys.
      "20260708130000_seed_prompt_templates_security_guard.exs",
      # Task 019f474d stage 2 — IntentClassifier prior-N context buffer.
      # Force-updates the `meetings.intent_classify.v1` template body to
      # add an explicit "Prior conversation context — DO NOT classify
      # these lines" section separator so the LLM cannot conflate the
      # buffered prior chunks (framed as read-only context, industry
      # standard Zoom AI Companion / Fireflies / Otter pattern) with the
      # current utterance under classification. Also fixes a latent
      # variable-name drift bug — pre-existing template body referenced
      # `{{meeting_transcript_chunk}}` while the classifier passed
      # `assigns.transcript_chunk`; stage 2 passes both keys. Dedupe key
      # UNCHANGED — still `sha256(intent + target_role + chunk_text)` on
      # the current chunk only, so idempotency is preserved.
      "20260709120000_update_intent_classify_prompt_with_context.exs",
      # Task 019f487d stage 1 (ADR-0045 task stacks v2) — seed the
      # `stacks.dep_inference.v1` prompt template so
      # Platform.Tasks.Stacks.DepInference (member 2) has a DB-backed,
      # operator-editable prompt to render before its LLM round-trip.
      # Idempotent seed_defaults/0 call; no schema changes.
      "20260710120000_seed_stacks_dep_inference_template.exs",
      # Task 019e95ea stage 3 (channel delete pipeline) — adds nullable
      # chat_spaces.deletion_scheduled_at + partial index for the purge
      # sweep. No data migration.
      "20260711000000_add_deletion_scheduled_at_to_chat_spaces.exs",
      # Task 019f4f1d (Saru design gates) — force-update dispatch.planning
      # and dispatch.in_review to the code defaults, upstreaming the
      # Designer-gate sections first applied live via prompt_template_update.
      # Content-only sync; no schema changes.
      "20260711010000_sync_design_involvement_dispatch_templates.exs",
      # Task 019f4f55 stage 2 (Historian chunked threshold-pass) —
      # force-update the `historian.threshold` template to inline the
      # per-window `activity_digest` produced by
      # `HistorianDispatcher.dispatch_windowed/4`. Content-only sync;
      # variables list picks up `activity_digest` so the render doesn't
      # leave the placeholder unbound.
      "20260711100000_force_update_historian_threshold_windowed.exs",
      # Task 019f487e-03d9 stage 1 (Stack v2 stack-level sponsor) — adds
      # `sponsor_user_id` FK → users(id) with `on_delete: :nilify_all` on
      # `task_stacks`, mirroring the tasks.sponsor_user_id column. Backend
      # schema only; sponsor UI + filter thread land in later stages.
      "20260711180755_add_sponsor_user_id_to_task_stacks.exs",
      # Task 019f487e-25e6 stage 1 (Stack v2 auto-plan cascade) — adds
      # `auto_plan` and `auto_accept_plan` boolean flags to `task_stacks`
      # for the stage-3/4 wave-gated planning cascade. Backend-only; no
      # data migration.
      "20260711200000_add_auto_plan_flags_to_task_stacks.exs",
      # Task 019f487e-25e6 stage 5 (Stack v2 parent_plans injection) —
      # force-updates the `dispatch.planning` template to render the
      # `{{upstream_plans_section}}` variable so in-stack dep parents'
      # approved plans reach the planner subagent. Content-only sync; no
      # schema changes.
      "20260711202135_add_parent_plans_section_to_dispatch_planning.exs",
      # Task 019f5d47 stage 1 (stage-level responsibility routing) —
      # adds nullable `responsibility :text` column to `stages`. Later
      # stages resolve the value at dispatch time via
      # `Platform.Roles.agent_id_for_role/1` and route the stage's
      # prompt to the corresponding runtime. Progressive enhancement:
      # nullable column, no default, no CHECK constraint.
      "20260713000000_add_responsibility_to_stages.exs",
      # Task 019f5d47 stage 5 (stage-level responsibility routing) —
      # force-update `dispatch.planning` to include the new bullet
      # teaching planners to set `responsibility: "designer"` on the
      # advisory Design-direction stage. Content-only sync; no schema
      # changes.
      "20260713000010_sync_dispatch_planning_responsibility_hint.exs",
      # Task 019f5e66 stage 2 (project_files deploy strategy) — adds a
      # nullable `deploy_target_config :map` column to `tasks` for the
      # richer per-strategy deploy config, alongside the legacy
      # `deploy_target` string. Backfills existing non-null legacy rows
      # as `{strategy: "docker_deploy", target: <legacy>}`; idempotent
      # (only touches rows where the new column is still NULL).
      "20260713010000_add_deploy_target_config_to_tasks.exs",
      # Task 019f5e2b-8d29 stage 2 (meeting-to-tasks pipeline guardrails) —
      # persistent `needs_promotion :boolean` on `tasks` set by the
      # triage filer while under the per-project backlog cap. Partial
      # index on `where needs_promotion = true` so the kanban badge-
      # counter reads a small hot slice, not the full table.
      "20260713120000_add_needs_promotion_to_tasks.exs",
      # Task 019f5e7d stage 1 — relax the NOT NULL + composite PK on
      # `org_historian_cursors.workspace_id` so the sentinel-to-nil
      # coercion (extended from PR #537 to the cursor read/write
      # functions) can persist org-scope rows in the canonical
      # `workspace_id IS NULL` shape.
      "20260714000000_relax_org_historian_cursors_null_workspace.exs",
      # Task 019f5e7d stage 2 — force-update the three historian
      # dispatch templates (`historian.scheduled`,
      # `historian.meeting_ended`, `historian.threshold`) to remove the
      # "write an empty acknowledgement entry" instruction that was
      # self-triggering the dispatch loop. Content-only sync; no schema
      # changes. Mirrors the `force_update_*` pattern at 20260520050000.
      "20260714000050_suppress_historian_no_op_journal_writes.exs",
      # Task 019f5e7d stage 3 — one-shot cleanup of the ~80 self-generated
      # no-op ("backlog drained" / "no new entries" / "Wiki current")
      # historian journal entries in `org/journal/2026-07-13.md`. Stage 2
      # closed the source template loop; this migration purges the
      # stranded rows and drops one `platform.historian.cleanup` audit
      # row per pass. Preserves entries containing `Applied:` (the load-
      # bearing "Historn: backlog-drain pass. Applied: kickoff-followup-
      # meeting.md ..." entry documenting three real fixes). Mirrors the
      # phantom-flood cleanup pattern at 20260706120000.
      "20260714000100_cleanup_historian_no_op_journal_entries_20260713.exs",
      # Task 019f640d stage 5 (TaskRouter redesign) — force-update the
      # four dispatch templates (`dispatch.planning`,
      # `dispatch.in_progress`, `dispatch.in_review`,
      # `dispatch.deploying`) with the ack-first preamble so runtimes
      # know their FIRST tool call must be `task_ack(task_id,
      # stage_id)`. Also refreshes the `variables` list on each row to
      # include `task_id` + `stage_id` so mustache actually interpolates
      # them. Content-only sync; no schema changes. Mirrors the force-
      # update pattern at 20260711202135.
      "20260715000000_add_task_ack_preamble_to_dispatch_templates.exs",
      # Task 019f62a1 stage 2 — Pin-to-Chat: `task_chat_pins` table
      # backing `Platform.Tasks.ChatPins`. Per-participant subscription
      # rows to a task's execution chat space. Materialised lazily on
      # first pin via `ExecutionSpace.find_or_create/1` so backlog tasks
      # never picked up leave zero `chat_spaces` rows.
      "20260715012217_create_task_chat_pins.exs",
      # Task 019f62a1 v4 stage 2 — Pin-to-Chat data repair. Backfills
      # `org_id` on every `kind = "execution"` chat_spaces row where
      # `org_id IS NULL` but the linked task resolves to a project
      # with an `org_id`. Companion to the code fix that teaches
      # `ExecutionSpace.find_or_create/1` to stamp `org_id` on new
      # exec spaces so post-ADR-0042 org-scoped slug lookups
      # (`Chat.get_space_by_slug/2`) can resolve them. Data-only;
      # `down/0` is a no-op.
      "20260715165309_backfill_exec_space_org_id.exs",
      # Task 019f4eaa stage 2 — container archive/delete lifecycle columns.
      # `orgs` + `projects` gain `archived_at` + `deletion_scheduled_at`;
      # `projects` + `chat_spaces` gain `archived_cascade_org_id` (the
      # provenance marker letting a restore un-hide ONLY the children a given
      # org's cascade hid, never an independently-archived one). Partial
      # indexes on each non-NULL predicate keep the lifecycle sweeps and the
      # active-only listing filters cheap. Fully reversible.
      "20260714010000_add_lifecycle_columns_to_orgs_projects_chat_spaces.exs",
      # Task 019f6791 stage 1 — Router arch fix: stage-scoped leases.
      # Adds `stage_id` column to `execution_leases` and repartitions
      # the unique index so each `(task_id, stage_id)` pair carries
      # its own lease. Fixes the root-cause bug where a completing
      # stage released the lease for the whole task, letting siblings
      # silently stall or double-dispatch.
      "20260715210000_add_stage_id_to_execution_leases.exs",
      # Task 019f6791 stage 4 — Router arch fix (alarm_silence rollout).
      # Force-updates the four dispatch prompt templates (`dispatch.planning`,
      # `dispatch.in_progress`, `dispatch.in_review`, `dispatch.deploying`)
      # so the ack-first preamble also documents the `alarm_silence` MCP
      # tool as the operator escape hatch when `task_ack` is missing from
      # a caller's stale MCP tool cache. Retires the
      # `report_blocker(needs_human: false)` ack-proxy anti-pattern by
      # explicitly forbidding it in the copy. Content-only sync; no schema
      # changes. Mirrors the force-update pattern at 20260715000000.
      "20260715220000_refresh_dispatch_templates_alarm_silence_fallback.exs",
      # Task 019f671f stage 1 — User archival. Adds nullable
      # `users.archived_at`, `users.archived_by_user_id` (FK → users(id)
      # on_delete: :nilify_all so historical actor stays resolvable) and
      # `users.archived_reason` (text). Powers the soft-archive flow
      # wired into `Platform.Accounts.archive_user/2` +
      # `unarchive_user/1`; downstream reads (`list_users`,
      # `get_users_map`) filter via `include_archived: false` default.
      # Mirrors the `spaces.archived_at` precedent.
      "20260716000000_add_archived_to_users.exs",
      # Task 019f6381 stage 1 (memory-feedback training corpus) — layer-1
      # storage: append-only `org_memory_feedback` table capturing every
      # edit/delete/retention signal against org memory. Backs
      # `Platform.MemoryFeedback` (the capture surface + query API that
      # later stages 2-5 wire into `Platform.Org.Context` write paths,
      # expose via MCP, and feed into the historian dreaming instruction).
      "20260716174039_create_org_memory_feedback.exs",
      # Task 019f6c73 stage 4 — Router: task_ack requires subagent_id.
      # Force-updates the four dispatch prompt templates so every runtime
      # dispatch in prod carries the new @task_ack_preamble body with
      # subagent_id + spawn-first ordering (shipped stage 3). Without this
      # refresh the templates keep telling agents to call task_ack without
      # subagent_id, causing every ack in prod to fail hard until the next
      # redeploy. Content-only sync; no schema changes. Mirrors the
      # force-update pattern at 20260715220000.
      "20260716211312_refresh_dispatch_templates_subagent_id_ack.exs",
      # Task 019f6381 stage 5 (memory-feedback training corpus) — bridge
      # the deleted-paths corpus into the historian dreaming instruction.
      # Force-updates the `historian.scheduled` prompt template row to
      # include the "Intentionally deleted paths" section so the
      # Historian sees which paths were intentionally removed on every
      # dispatch. Content-only sync; no schema changes. Mirrors the
      # `force_update_*` pattern at 20260714000050.
      "20260716220000_force_update_historian_scheduled_deleted_paths.exs",
      # Task 019f5e2a stage 3 (M1 of the meeting-to-tasks-pipeline stack) —
      # retrofit the six Claude Code dispatch prompt templates so every
      # runtime dispatch in prod consumes the consolidated
      # `{{federation_preamble}}` placeholder (introduced in stage 1) rather
      # than inlining separate Organization Context / Writing to Org Memory /
      # skill-discovery / evidence-workflow blocks per template. Content-only
      # sync; no schema changes. Mirrors the force-update pattern at
      # 20260716211312.
      "20260717000000_retrofit_dispatch_templates_with_federation_preamble.exs",
      # Task 019f5e2b (meeting-to-tasks pipeline stack member M4) Stage 1:
      # seeds the new `dispatch.triage_dispatch` prompt template so the
      # triage-officer runtime can render the scribe-completion→tasks
      # dispatch prompt. Idempotent insert-only-if-missing via
      # `PromptTemplates.seed_defaults/0` — mirrors the
      # 20260326190000_seed_deploying_prompt_template pattern. Stage 2
      # adds a force-update migration once the real body lands.
      "20260717000001_seed_triage_dispatch_template.exs",
      # Task 019f5e2b Stage 2: force-updates the persisted
      # `dispatch.triage_dispatch` row so upgraded DBs render the real
      # triage-officer body (canvas_get → checklist_item parse → Triage
      # handoff → summary card append) instead of the Stage 1 stub.
      # `seed_defaults/0` is insert-only; this is the escape hatch.
      # Mirrors 20260716211312_refresh_dispatch_templates_subagent_id_ack.
      "20260717000100_force_update_triage_dispatch_template.exs",
      # Task 019f5e2b Stage 3: seeds the `meeting-triage-officer` skill
      # row via `Platform.Skills.seed_defaults/0` — first entry in the
      # new hardcoded `Platform.Skills.do_default_skills/0` list. The
      # triage-officer runtime calls `skill_get` for this slug before
      # parsing checklist items. Idempotent insert-only-if-missing;
      # mirrors the 20260326190000_seed_deploying_prompt_template shape.
      "20260717000200_seed_meeting_triage_officer_skill.exs",
      # Task 019f708f stage 3 (bug #3): shape-enforce
      # `metadata["merged_into_rollup_at"]` at the changeset boundary,
      # backfill malformed pre-fix stamps. Content-only DELETE via
      # jsonb operator; no schema change.
      "20260717173915_drop_malformed_merged_into_rollup_at_stamps.exs",
      # Task 019f70e9 stage 2 (Historian dreaming) — persist parsed
      # `<synthesis-proposal>` blocks so `/memory/proposals` LiveView
      # (stage 4) lists without re-parsing every journal. Creates
      # `memory_proposals` table with `(workspace_id, block_hash)`
      # unique index for idempotent re-ingest, `(status, expires_at)`
      # index for the hourly TTL sweep. Backend-only; sweep hook fires
      # from `Platform.Org.Context.upsert_context_file/3` post-tx.
      "20260718200000_create_memory_proposals.exs",
      # Task 019f70e9 stage 5 (Historian dreaming) — seed the dreaming
      # dispatch prompt under both `historian.dreaming` (canonical) and
      # `memory.dreaming.v1` (legacy responsibility-router lookup key).
      # Insert-or-force-update so both slugs land on fresh envs where
      # `Handlers.Dreaming.register/0`'s `default_prompt_template` was
      # previously an orphan lookup, and existing envs pick up the
      # single-source-of-truth body advanced in lockstep with the
      # code ship. Content-only sync; no schema changes.
      "20260718230000_seed_dreaming_prompt_dual_slug.exs",
      # Task 019f70e9 stage-8 fix — add `target_page_key` column to
      # `memory_proposals` so the promotion pipeline
      # (`Proposals.queue_promotion/1`) has a stable, auditable
      # destination filled at ingest time. Nullable for backfill
      # compatibility; derivation function is the single source of
      # truth for both ingest + promote-time fallback.
      "20260719000000_add_target_page_key_to_memory_proposals.exs",
      # Task 019f760f stage 4 — backfill per-child deletion clocks for
      # cascade children scheduled BEFORE stage 1 (marker set, own
      # `deletion_scheduled_at` NULL). Stage 2 dropped the org-clock join
      # in the purger, so those rows would never purge; this stamps their
      # own clock from their still-scheduled org. Data-only, idempotent;
      # `down/0` is a no-op.
      "20260719000001_backfill_cascade_child_deletion_clocks.exs",
      # Task 019f7b7e stage 1 — per-stack migration-slot allocator.
      # Adds nullable `task_stacks.next_migration_slot`, the cursor
      # `Stacks.allocate_migration_slot/1` advances under a per-stack
      # advisory lock so concurrent stack members never mint the same
      # `mix ecto.gen.migration` timestamp (observed 2026-07-17: two
      # members both produced 20260717000000 and Ecto silently skipped
      # one). Column-only; readers/writers land in later stages.
      "20260719120000_add_next_migration_slot_to_task_stacks.exs",
      # Task 019f7b7e stage 3 — surfaces the reserved slot to the executor.
      # Force-updates the `dispatch.in_progress` prompt template row so it
      # carries `{{migration_slot_section}}`; without it the stage-2
      # reservation is written but never read by the agent doing the work.
      # Template-content only, no schema change; `down/0` is a no-op.
      "20260719120100_add_migration_slot_section_to_dispatch_in_progress.exs",
      # Task 019f7cb0 stage 2: soft-delete marker on platform_files
      # (`deleted_at` + partial index over deleted rows) backing
      # `Platform.Files.delete_file/2` / `restore_file/2` with the
      # 30-day restore window.
      "20260720010000_add_deleted_at_to_platform_files.exs",
      # Task 019f8837 (rbac-external-users stack member M1): the three
      # foundational schema migrations — external marker on
      # org_memberships, per-org DM allowlist, and pending external
      # grants. M1 is the only stack member that adds migrations.
      "20260722000001_add_external_to_org_memberships.exs",
      "20260722000002_create_external_dm_allowlist_entries.exs",
      "20260722000003_create_pending_external_grants.exs",
      # Task 019f904c (inbox-system stack member M1): the notification
      # source contract — `inbox_items` table (durable per-user attention
      # rows) backing `Platform.Inbox.emit/1`. M1 is the only stack member
      # that adds a migration.
      "20260723185711_create_inbox_items.exs",
      # Task 019f70b8 (intent-queue live-tuning UI) stage 5: seeds AND
      # force-updates the new `dispatch.intent_attention` prompt template.
      # Both halves in one migration — the slug is new (so prod, which no
      # longer re-runs `seed_defaults/0`, needs the insert) and the body
      # will be iterated (so environments that already have the row need
      # the overwrite). The queue itself stays ETS-only per
      # `feedback_ets_for_ephemeral_state`; the only other migration this
      # task adds is stage 6's corrections table.
      "20260725120000_seed_and_force_update_intent_attention_template.exs",
      # Task 019f9b13 stage 4 (vault authorization audit): supersedes
      # 20260314070000's ON DELETE CASCADE on
      # `vault_access_log.credential_id` with ON DELETE SET NULL plus
      # denormalised `credential_slug` / `credential_scope_type`, so
      # revoking a credential no longer destroys the audit trail that
      # records the revocation. The only schema stage in the task.
      "20260725220000_retain_vault_access_log_on_credential_delete.exs",
      # Task 019f70b8 stage 6: the ONE durable table this task adds —
      # `meeting_intent_corrections`, the few-shot corpus behind the
      # classifier tuning loop. The exception to the ETS-only rule above
      # is deliberate: an exemplar that died with its meeting would teach
      # nothing, so outliving the meeting IS the point.
      "20260726000000_create_meeting_intent_corrections.exs",
      # Task 019f70b8 stage 6: third revision of the
      # `meetings.intent_classify.v1` body, adding the
      # `{{correction_exemplars}}` few-shot block above the
      # prior-conversation window (AC16). Update-only — the 20260707 seed
      # already created the row on every migrated environment.
      "20260726000100_update_intent_classify_prompt_with_corrections.exs",
      # ADR-0046 member 4 — planning_step + per-step outcomes.
      "20260726045711_add_planning_step_to_tasks.exs",
      # ADR-0046 member 7 (task 019f9b29-5ecd stage 3): the `designer`
      # role bundle gains `design.task_direction` and the
      # `design.task_direction.v1` prompt template row is inserted. Both
      # halves re-run an existing idempotent seed — the responsibilities
      # row itself lands at boot via the Registry upsert, so no schema
      # change here.
      "20260726051346_seed_design_task_direction.exs",
      # ADR-0046 member 7 (task 019f9b29-5ecd stage 6): retarget the
      # `dispatch.planning` "Design involvement" section at the pre-plan
      # design step — the planner stops resolving brand and stops
      # authoring a `responsibility: "designer"` design stage.
      # `seed_defaults/0` is INSERT-only and the 20260713000010 sync
      # already claimed this row on every migrated environment, so the
      # rewritten body needs its own overwrite. Update-only; no schema
      # change.
      "20260726051347_force_update_dispatch_planning_design_preplan.exs",
      # ADR-0046 member 5 — plans.architecture_verdict.
      "20260726051454_add_architecture_verdict_to_plans.exs",
      # ADR-0046 member 5 stage 4: third revision of the
      # `architecture.review_plan.v1` body. Stage 3 made the prompt's own
      # claims false — it said the architect was "additive, not a blocker"
      # and that the plan advanced "regardless of what you find", while
      # `Tasks.approve_plan/3` now refuses a non-human approval behind an
      # open gate. `seed_defaults/0` is INSERT-only and the 20260708123000
      # / 20260726210000 force-updates already claimed this row, so the
      # gate contract needs its own overwrite to reach a deployed prompt.
      # Timestamp reserved by the stack coordinator, so it sorts BEFORE
      # member 3's 20260726210000 on a fresh DB and after it on a migrated
      # one; both write `default_content_for_slug/1`, so the orderings
      # converge. Update-only; no schema change.
      "20260726051455_force_update_architect_review_plan_gate_contract.exs",
      # Task 019f9b29 (ADR-0046 member 9): drops the nullable
      # `stages.responsibility` column after members 7 and 9 removed every
      # producer and consumer. Census-then-drop — `up/0` logs the row count,
      # the non-terminal-plan subset, the distinct values and the row
      # identities before the `ALTER TABLE`; `down/0` re-adds the column but
      # not the data.
      "20260726052350_drop_responsibility_from_stages.exs",
      # Task 019f9b28-6ca7 stage 5: the `architecture.review_plan.v1`
      # body told the architect to "prefer citing the ADR by number",
      # which `docs/decisions/` cannot honour — four numbers each name
      # two different ADRs. `seed_defaults/0` is INSERT-only and the
      # 20260708123000 force-update already claimed this row on every
      # migrated environment, so the new guidance needs its own
      # overwrite to reach a deployed prompt. Update-only; no schema
      # change.
      "20260726210000_force_update_architect_review_plan_citation_guidance.exs",
      # Task 019fa230 stage 2: the historian bundle's third duty was
      # seeded as `memory.dream_consolidation` while the registered
      # handler fires `memory.dreaming`, so the Control Center panel
      # offered a row whose override no dispatch path ever read.
      # `seed_defaults/0` inserts with `on_conflict: :nothing`, so the
      # seed rename alone would ADD the live key and leave the stale
      # pair row behind — both spellings would then render. This
      # migration repoints `responsibility_overrides` onto the live key
      # (resolving the unique-index collision in favour of an existing
      # live-key pin), deletes the stale pair row, and re-seeds. No
      # schema change.
      "20260727000000_rename_dream_consolidation_bundle_key.exs",
      # Task 019fa469 stage 5: the `dispatch.planning` row opened with the
      # ack-first preamble, instructing planners to call `task_ack` with an
      # empty stage_id — which `ToolSurface.resolve_ack_stage_id/2` rejects,
      # because a planning dispatch has no plan and so no running stage.
      # `seed_defaults/0` is INSERT-only and this row exists on every
      # environment that has ever booted, so editing `do_default_templates/0`
      # alone would leave prod serving the old body. Update-only; no schema
      # change.
      "20260727183000_force_update_planning_template_drop_ack.exs",
      # Task 019fa504 stage 3: the `design.task_direction.v1` row's
      # `## Delivery` section named exactly one exit — attach a canvas —
      # because until stages 1 and 2 of this task that was the only exit
      # there was. The `task_design_decline` tool is now in the designer's
      # `task` bundle, and a tool she is never told about is not reachable
      # in practice. `seed_defaults/0` is INSERT-only and 20260726051346
      # claimed this slug on every migrated environment, so the prompt edit
      # reaches a deployed designer only through this overwrite.
      # Update-only; no schema change.
      "20260727210000_force_update_design_task_direction_decline.exs",
      # Task 019fa56b-ca2d stage 1: `federation_dead_letters`, the durable
      # replacement for `Platform.Federation.DeadLetterBuffer` — a 50-entry
      # in-process list that lost every row on BEAM restart and had already
      # partially overwritten the 2026-07-27 evidence (39 responsibility
      # drops sharing the cap with chat drops) before that day's audit read
      # it. Also the first row shape that carries the failed ENVELOPE, so a
      # dead letter becomes replayable rather than merely counted.
      "20260728000000_create_federation_dead_letters.exs",
      # Task 019fa56b-ca2d stage 4: `federation_dead_letter_stats`, the
      # monotonic loss counters. Separate from the ledger because the ledger is
      # a work queue that dedupes pending fires and prunes terminal rows — both
      # correct for a queue, both fatal to a cumulative measure. Counting off
      # the ledger would reproduce the ticket's own snapshot defect one layer
      # down. Bounded cardinality (keys x runtimes x counters), never pruned.
      "20260728000100_create_federation_dead_letter_stats.exs"
    ]

    defp t4_root, do: Mix.Project.project_file() |> Path.dirname()

    test "Platform.Org.Wiki.Context exists at the canonical T4 path" do
      assert File.exists?(Path.join(t4_root(), "lib/platform/org/wiki/context.ex"))

      assert File.exists?(Path.join(t4_root(), "test/platform/org/wiki/context_test.exs"))
    end

    test "Platform.Org.Context content matches T1 HEAD by sha256 (T4 must not retire it)" do
      contents = File.read!(Path.join(t4_root(), "lib/platform/org/context.ex"))
      hash = :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)
      expected = Application.fetch_env!(:platform, :t2_context_sha256_t1_head)

      assert hash == expected,
             """
             Platform.Org.Context drift vs T1 HEAD detected.
             Expected sha256: #{expected}
             Got sha256:      #{hash}
             T4 must NOT modify Org.Context — T5 retires it.
             """
    end

    test "Platform.Federation.ToolSurface has no memory_20250818 tool def" do
      contents = File.read!(Path.join(t4_root(), "lib/platform/federation/tool_surface.ex"))

      refute String.contains?(contents, "memory_20250818"),
             "T4 must NOT add a memory_20250818 tool — that's T5 territory."

      # T5 stage 3 added the six Anthropic-trained memory_* tools and
      # T5 stage 4 added memory_search. The earlier refute on
      # "memory_search" stays retired here — the T4 boundary it
      # encoded has rolled forward into T5.
    end

    test "T4 added only the allow-listed refresh migration; no other migrations" do
      migrations_dir = Path.join(t4_root(), "priv/repo/migrations")
      current = File.ls!(migrations_dir)

      # The total count is T3 HEAD + the allow-listed new ones.
      assert length(current) == @t3_head_migrations_count + length(@t4_allowed_new_migrations),
             """
             Unexpected migration count.
             T3 HEAD: #{@t3_head_migrations_count}
             Allow-listed T4 additions: #{inspect(@t4_allowed_new_migrations)}
             Current: #{length(current)} files.
             """

      # Every allow-listed migration must actually exist.
      for name <- @t4_allowed_new_migrations do
        assert name in current,
               "Allow-listed migration #{name} missing from priv/repo/migrations."
      end
    end

    test "T4 did not touch apps/platform/lib/platform_web/" do
      refute Enum.any?(@t4_changed_lib_paths, &String.starts_with?(&1, "lib/platform_web/")),
             "T4 changed-paths allow-list must not include any platform_web paths."
    end

    test "T4 did not introduce T5/T6/T7 modules" do
      for path <- @t4_forbidden_paths do
        full = Path.join(t4_root(), path)

        refute File.exists?(full),
               "T4 should NOT add #{path} — that's downstream task territory."
      end
    end
  end
end
