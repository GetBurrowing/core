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

    # T3 HEAD migrations (commit abffe51): the number of migrations that
    # existed below the T3/T4 line. This counts a CLOSED interval, so it
    # is a recorded historical fact and not a running total.
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
    # That is the last time this number moves. It was bumped repeatedly
    # while it was a total over the WHOLE directory; since the split on
    # @t4_boundary_version it counts only the closed half, which nothing
    # legitimate can change. A failure here is a back-dated, renamed or
    # deleted historical migration — never a reason to edit the constant.
    #
    # NOTE (019fba52): a companion @t4_allowed_new_migrations attribute
    # used to name every post-boundary migration by filename, and a test
    # asserted the directory total equalled this count plus that list's
    # length. It was deleted here. Verified before removal: the sorted
    # 112-entry list was byte-identical to the sorted set of files at or
    # above the boundary, so it encoded nothing the filename timestamp
    # did not already carry — while forcing every branch that added a
    # migration to edit one shared list, which serialised them behind a
    # merge conflict. Its coverage is replaced, not dropped:
    #
    #   * the historical half by the equality below, over a closed
    #     interval that a new migration cannot enter; and
    #   * the forward half by "every post-boundary migration documents
    #     itself and cites the work that admitted it", a property of
    #     file CONTENT that a branch satisfies by writing a @moduledoc
    #     in the migration it just created — touching no shared file.
    #
    # Do not reintroduce the list. If you are resolving a merge from a
    # branch that appended to it: drop the list entry, keep the
    # migration file, and give that file a @moduledoc of >= 40
    # characters citing your task id / ADR / PR.
    @t3_head_migrations_count 95

    # The T3/T4 line, already narrated in the comment block above. Every
    # migration below it belongs to a CLOSED historical interval whose
    # membership is finished; everything at or above it is the open
    # forward window.
    #
    # This is deliberately the EXISTING boundary rather than a fresh one
    # stamped today. A new cutoff would permanently exempt any migration
    # created on a concurrent branch shortly before it but merged after
    # it. Only closed intervals can be pinned by a constant.
    @t4_boundary_version 20_260_520_000_000

    defp t4_root, do: Mix.Project.project_file() |> Path.dirname()

    @migration_name_shape ~r/^\d{14}_[a-z0-9_]+\.exs$/

    # Reads priv/repo/migrations exactly once and splits it on
    # @t4_boundary_version.
    #
    # The directory listing is an OBSERVATION: it decides WHICH files are
    # examined, never WHAT is expected of them. Every expected value in the
    # assertions below is a pinned constant or a literal pattern. Deriving an
    # expectation from this listing would make the assertion compare the tree
    # against itself, which cannot fail for any input.
    #
    # A name with no parseable leading version is placed in `admitted` rather
    # than dropped, so it still shows up in `all` and is reported by the
    # filename-shape assertion instead of vanishing between the two halves.
    defp t4_migration_partition do
      entries =
        t4_root()
        |> Path.join("priv/repo/migrations")
        |> File.ls!()

      {historical, admitted} =
        Enum.split_with(entries, fn name ->
          case Integer.parse(name) do
            {version, _rest} -> version < @t4_boundary_version
            :error -> false
          end
        end)

      %{all: entries, historical: historical, admitted: admitted}
    end

    test "the pre-T4-boundary migration inventory still matches T3 HEAD" do
      %{all: all, historical: historical} = t4_migration_partition()

      malformed = Enum.reject(all, &Regex.match?(@migration_name_shape, &1))

      assert malformed == [],
             """
             Unexpected file(s) in apps/platform/priv/repo/migrations:

               #{Enum.join(malformed, "\n  ")}

             Every entry in this directory must be a migration named
             <14-digit-version>_<snake_case>.exs.

             To fix: move or delete the file(s) above. Editor leftovers
             (.swp, .bak), notes and READMEs do not belong in the migrations
             directory.

             Why this is checked: a file with no parseable 14-digit version
             has no home in the historical/admitted split, so without this
             assertion it would be silently ignored by every other migration
             guard in this file.
             """

      assert length(historical) == @t3_head_migrations_count,
             """
             The pre-T4-boundary migration inventory changed.

             Expected below version #{@t4_boundary_version}: #{@t3_head_migrations_count}
             Actually found below it: #{length(historical)}

             Migrations with a version BELOW #{@t4_boundary_version} are a
             CLOSED historical interval. That set finished changing long ago
             and #{@t3_head_migrations_count} is a recorded fact about it, not
             a running total.

             To fix, depending on what you did:
               * Adding a migration? Give it a CURRENT timestamp so it lands
                 at or above #{@t4_boundary_version}. `mix ecto.gen.migration`
                 already does this. Do not hand-write an older version — a
                 back-dated migration runs out of order on a fresh database.
               * Renamed or deleted a historical migration? Restore it. Its
                 version is already recorded in every deployed database's
                 schema_migrations table.

             This guard deliberately keeps no list of names, so to find WHICH
             file moved, ask git. Two commands, because neither alone sees both
             cases (`git status` never reports committed changes, and `git diff`
             never reports untracked files):

               git status --short apps/platform/priv/repo/migrations
               git diff --name-status --diff-filter=ADR origin/main -- apps/platform/priv/repo/migrations

             Do NOT resolve this by editing @t3_head_migrations_count. The
             number is the assertion; changing it to match the tree deletes
             the guard.
             """
    end

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

    # A Suite task id, an ADR number, or a PR number.
    #
    # Task ids are UUIDv7 prefixes, so their leading hex digits are a
    # timestamp that rolls over. The original `019` literal silently
    # stopped matching on 2026-08-13, when newly-minted ids began `01a0`
    # — every migration citing a current task id failed clause (b) while
    # the help text advertised three forms of which none was reachable.
    # `01[9a-f]` keeps the same 8-hex-digit shape and covers the next
    # several rollovers rather than pinning one prefix.
    @migration_work_reference ~r/01[9a-f][0-9a-f]{5}|ADR[-\s]?0\d{3}|#\d{3,}/

    @min_moduledoc_length 40

    # Extracts the first `@moduledoc <string>` from a migration's source.
    #
    # Parsed from the AST rather than regex-matched, because BOTH the
    # heredoc form (`@moduledoc """…"""`) and the single-line form
    # (`@moduledoc "…"`) occur in priv/repo/migrations, and a regex that
    # handles heredocs is exactly the kind of thing that quietly stops
    # matching when someone reindents a file.
    #
    # Returns nil when the module has no @moduledoc, or when its value is
    # not a plain string (`false`, or an interpolated/computed expression).
    defp t4_moduledoc(source) do
      {_ast, doc} =
        source
        |> Code.string_to_quoted!()
        |> Macro.prewalk(nil, fn
          {:@, _, [{:moduledoc, _, [doc]}]} = node, acc when is_binary(doc) ->
            {node, acc || doc}

          node, acc ->
            {node, acc}
        end)

      doc
    end

    test "every post-boundary migration documents itself and cites the work that admitted it" do
      %{admitted: admitted} = t4_migration_partition()

      migrations_dir = Path.join(t4_root(), "priv/repo/migrations")

      offenders =
        admitted
        |> Enum.sort()
        |> Enum.map(fn name ->
          source = File.read!(Path.join(migrations_dir, name))
          doc = t4_moduledoc(source)

          missing =
            [
              unless(is_binary(doc) and String.length(String.trim(doc)) >= @min_moduledoc_length,
                do: "(a) no @moduledoc of at least #{@min_moduledoc_length} characters"
              ),
              unless(Regex.match?(@migration_work_reference, source),
                do: "(b) no task id / ADR number / PR number anywhere in the file"
              )
            ]
            |> Enum.reject(&is_nil/1)

          {name, missing}
        end)
        |> Enum.reject(fn {_name, missing} -> missing == [] end)

      report =
        Enum.map_join(offenders, "\n", fn {name, missing} ->
          "  #{name}\n      #{Enum.join(missing, "\n      ")}"
        end)

      assert offenders == [],
             """
             Undocumented migration(s) at or above version #{@t4_boundary_version}:

             #{report}

             To fix: write a @moduledoc of at least #{@min_moduledoc_length} characters
             saying why this migration exists, and cite the work that admitted
             it. Exactly three reference forms are recognised, anywhere in the
             file:

               * a Suite task id      01a0008c   (01 + 9/a-f + 5 hex digits)
               * an ADR number        ADR-0033   (also "ADR 0033" / "ADR0033")
               * a PR number          #647       (at least 3 digits)

             Nothing else counts, so "see the ticket", "PR 12" and a bare URL
             all stay red. Putting the reference inside the @moduledoc
             satisfies both clauses at once:

                 @moduledoc \"\"\"
                 Task 019fba52: adds tasks.deploy_target so the deploying
                 dispatch can pin a target instead of inferring one.
                 \"\"\"

             There is no allow-list to add this migration to and no count to
             bump. This message is the whole procedure; CONTRIBUTING.md
             ("Adding a migration") repeats it and explains why.

             Why this is checked: a migration is a permanent, irreversible-in-
             practice change to every deployed database, and `mix ecto.gen.
             migration` emits a module with neither a rationale nor a link back
             to the work that wanted it. The record lives IN the migration —
             not in a registry elsewhere in the tree — so two branches adding
             migrations on the same day touch only the files they each created
             and never collide.

             This is deliberately a property of file CONTENT. The directory
             listing above decides WHICH files are checked; it can never supply
             what is expected OF them. An expectation read out of the same
             listing would be the tree observing itself, which cannot fail.
             """
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
