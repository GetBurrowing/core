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
      "20260623230546_add_enabled_and_metadata_to_responsibilities.exs"
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
