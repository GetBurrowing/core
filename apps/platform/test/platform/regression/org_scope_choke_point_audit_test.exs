defmodule Platform.Regression.OrgScopeChokePointAuditTest do
  @moduledoc """
  Source-scan guard keeping viewer org-scoping at ONE choke point:
  `Platform.Tenancy.visibility/1` + `Platform.Tenancy.scope/3`.

  ## Why a guard at all

  The extraction this test defends was landed by deleting two independent
  hand-rolled copies of the same private org filter (`Org.Context` and
  `Org.Wiki.Search`). Extraction without an enforced budget decays: the
  third copy costs one `defp` to write and nobody notices it until the
  copies disagree about who may see what. A disagreement between copies of
  a *visibility* filter is not a style problem — it is a tenancy leak.
  So the budget is enforced here rather than left to review.

  ## What is asserted

  Every `defp` under `apps/platform/lib/platform/**/*.ex` that either

    * is NAMED like an org filter (`filter`/`scope`/`narrow`/`restrict`
      adjacent to `org`/`orgs`), or
    * contains a RAW viewer-scope org predicate — set membership,
      `org_id in ^ids` or `org_id in subquery(...)`

  must compose the choke point — its body must contain a literal
  `Tenancy.scope(` call — OR its file must appear in `@allowlist` below
  with a comment saying why.

  Note the exemption is `Tenancy.scope(` specifically, not "mentions
  `Tenancy.`". `Meetings.Archive.narrow_to_viewer_orgs/2` calls
  `Tenancy.root_admin?/1` while hand-rolling its own org predicate; a
  bare-module-name exemption would have let exactly the site this test
  most needs to see slide past.

  ## Calibration

  Both patterns were tuned against the code deleted when the choke point
  landed. The name pattern matches all three pre-deletion helpers by
  name: `filter_org/2` in `org/context.ex`, the identical `filter_org/2`
  in `org/wiki/search.ex`, and `filter_task_org/2`. The predicate pattern
  independently matches their list clauses (`r.org_id in ^many`), so a
  future copy that avoids the naming convention is still caught.

  ## Shape

  Pure `File.read!` + `Regex` — no DB, no PubSub, `async: true`. Peer of
  `supervised_task_repo_audit_test.exs` in this directory, whose structure
  this file deliberately mirrors (module-attribute allowlist, every entry
  commented, plus a second test asserting no allowlist entry is stale).
  """

  use ExUnit.Case, async: true

  @lib_root Path.expand("../../../lib/platform", __DIR__)

  # A scanner that visits zero files passes vacuously. A path typo, a
  # `Path.expand` that resolves outside the tree, or a `Path.wildcard`
  # that returns `[]` all produce a green suite that guards nothing —
  # and a source-scan audit is precisely the kind of test that fails
  # that way, silently, years after anyone last read it. The tree held
  # 412 modules when this landed; the floor is set at roughly half so
  # ordinary deletion never trips it but a broken root always does.
  @min_scanned_files 200

  # A `defp` whose NAME reads as an org filter. Deliberately loose on
  # affixes (`maybe_`, `_ids`, `_viewer`, plural `orgs`) because the
  # naming drift between copies is the thing being caught, not a
  # convention being enforced.
  @org_filter_name_regex ~r/defp\s+\w*(?:filter|scope|narrow|restrict)\w*orgs?\w*\s*[(\\]/

  # A RAW org predicate of the VIEWER-SCOPE shape — membership in a SET
  # of orgs (`org_id in ^ids`, `org_id in subquery(...)`), which is what
  # "the orgs this viewer belongs to" compiles down to. Catches the
  # deleted `r.org_id in ^many` and both surviving hand-rolled meeting
  # filters, independent of what their authors named them.
  #
  # Deliberately NOT `org_id == ^org_id`. Single-org equality is the
  # shape of provenance and caller-supplied narrowing — "rows belonging
  # to THIS org" — and it is everywhere (archival cascades, per-org
  # preamble reads, space lookups). Including it produced a large set of
  # matches that are not viewer scoping at all, which would have forced
  # a long allowlist; a long allowlist is how a guard stops guarding.
  @raw_org_predicate_regex ~r/\borg_id\s+in\s+(?:\^|subquery\()/

  # The composition that proves a site went through the choke point.
  # Bare `Tenancy.` is NOT enough — see the moduledoc.
  @choke_point_regex ~r/Tenancy\.scope\(/

  # Files permitted to hand-roll an org filter. EVERY entry states why.
  # Adding one is an access decision — write the sentence, or use
  # `Tenancy.visibility/1` + `Tenancy.scope/2` instead.
  @allowlist [
    # The choke point itself. `Tenancy` is where the single definition of
    # "which orgs may this viewer see" lives, so its internals
    # (`maybe_filter_orgs_viewer/3`, `scope_to_org_ids/3`) are the raw
    # org predicates every other module is being told to delegate to.
    "lib/platform/tenancy.ex",

    # NOT LISTED, on purpose: `lib/platform/tenancy/lifecycle.ex`. It was
    # expected to need an exemption (archival/cascade provenance, not
    # visibility) but the patterns above do not reach it — every one of
    # its org predicates is single-org `org_id == ^org_id` equality, the
    # provenance shape this audit deliberately ignores. The stale-entry
    # test below is what surfaced that; an exemption for a module the
    # scan cannot see is dead code asserting a review that never
    # happened. If the equality shape is ever added to the patterns,
    # lifecycle.ex is the first entry to add back, with that reason.

    # `maybe_filter_projects_org/2` — a CALLER-supplied narrowing opt
    # ("show me only this org's projects"), not a viewer scope. It
    # composes AFTER `Tenancy.scope/3` in
    # `Tasks.list_projects_for_user/2`, so it can only intersect what the
    # viewer may already see; it can never widen. Consolidating it into
    # the choke point would conflate a UI filter with an authorization
    # boundary.
    "lib/platform/tasks.ex",

    # `Meetings.viewer_meeting_query/3` bypasses on `root_admin?/1` (root
    # org AND admin role), whereas `Tenancy.visibility/1` bypasses on
    # `root_member?/1` (root org, ANY role). Converting was attempted and
    # reverted: every OIDC signup lands as a plain `member` of the root
    # org, so the wider predicate would grant all of them read access to
    # every tenant's meetings. That is an OPEN ACCESS DECISION awaiting
    # the sponsor, not a refactor. Remove this entry only once that
    # decision has landed — not to make the audit quiet.
    "lib/platform/meetings.ex",

    # `Meetings.Archive.narrow_to_viewer_orgs/2` and its private
    # `viewer_org_ids/1`. Same `root_admin?/1`-vs-`root_member?/1`
    # widening hazard as `lib/platform/meetings.ex` above, for the same
    # reason, blocked on the same sponsor decision. The two move
    # together.
    "lib/platform/meetings/archive.ex",

    # `Access.AgentWake.any_grants?/1` (task 01a1386e-45a5 stage 2) is not
    # a viewer scope and filters no rows anyone reads. Its
    # `g.org_id in subquery(owner_orgs)` asks whether ANY role grant
    # exists in an org an agent owner belongs to, as the one-query
    # short-circuit before building Scopes; it deliberately OVER-matches
    # (every role key in those orgs), so it can only cause the full
    # `Access.check/3` decision to run, never decide visibility itself.
    "lib/platform/access/agent_wake.ex",

    # `Mobile.AppPeople.org_mates/1` — the Burrow people directory
    # (`GET /api/app/people?scope=directory`) lists the members of the
    # orgs the caller BELONGS to. That is deliberately narrower than
    # `Tenancy.visibility/1`, which bypasses on `root_member?/1`: every
    # OIDC signup is a root-org member, so composing the choke point
    # would hand each of them a directory of every user in every tenant.
    # It is a membership join for a contact picker, not a visibility
    # scope, and it can only ever narrow.
    "lib/platform/mobile/app_people.ex",

    # `Access.Lineage.projects_of/2` (task 01a18d38 stage 2) is not a
    # viewer scope: it expands an ORG-LEVEL GRANT TARGET (`{:org, id}`)
    # down to the projects inside that org, so `descendant_ids/2` can
    # compute what one org deny covers at check time. The org ids come
    # from grant rows, never from the viewer's memberships, and an org
    # grant is deny-only (`Platform.Access.Grant`), so this expansion can
    # only NARROW what a viewer reads. Composing `Tenancy.scope/2` here
    # would answer a different question ("which orgs may the viewer see").
    "lib/platform/access/lineage.ex"
  ]

  describe "private org filters outside the choke point" do
    test "no module defines its own viewer org filter" do
      {offenders, _scanned} = scan()

      assert offenders == [], format_offenders(offenders)
    end

    test "the scan visits a plausible number of files" do
      {_offenders, scanned} = scan()

      assert length(scanned) > @min_scanned_files, """
      The org-scope audit scanned only #{length(scanned)} file(s), which is
      below the floor of #{@min_scanned_files}. This almost certainly means the
      scan root is broken, NOT that the tree shrank:

        @lib_root = #{@lib_root}

      A source-scan audit that visits nothing passes vacuously and
      guards nothing. Fix the root (or, if the tree genuinely shrank by
      half, lower the floor deliberately and say why in the commit).
      """
    end

    test "every @allowlist entry still hand-rolls an org filter" do
      # Guard against @allowlist rotting — an entry that matches nothing
      # is dead code giving false confidence, and worse here than
      # elsewhere: it reads as "this module was reviewed and exempted"
      # when the module may have been converted years ago.
      stale =
        Enum.filter(@allowlist, fn relative_path ->
          case File.read(Path.join(app_root(), relative_path)) do
            {:ok, source} -> hand_rolled_blocks(source) == []
            {:error, _} -> true
          end
        end)

      assert stale == [], """
      @allowlist in this file lists modules that no longer define a
      private org filter (or no longer exist). Remove them so the
      exemption list keeps meaning something:

      #{Enum.map_join(stale, "\n", &"  - #{&1}")}
      """
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────

  # `apps/platform` — @lib_root is `<app_root>/lib/platform`.
  defp app_root, do: @lib_root |> Path.dirname() |> Path.dirname()

  # Returns `{offenders, scanned_files}` where offenders are
  # `{relative_path, [{line, defp_head}]}`.
  defp scan do
    scanned = Path.wildcard(Path.join(@lib_root, "**/*.ex"))

    offenders =
      scanned
      |> Enum.reduce([], fn absolute_path, acc ->
        relative_path = Path.relative_to(absolute_path, app_root())

        if relative_path in @allowlist do
          acc
        else
          case hand_rolled_blocks(File.read!(absolute_path)) do
            [] -> acc
            hits -> [{relative_path, hits} | acc]
          end
        end
      end)
      |> Enum.sort()

    {offenders, scanned}
  end

  # Splits a module source into `defp` blocks and returns
  # `[{line_number, head_line}]` for each block that looks like an org
  # filter but does not compose `Tenancy.scope/3`.
  defp hand_rolled_blocks(source) do
    source
    |> defp_blocks()
    # Clauses are grouped by function name before judging. A guard
    # clause like `defp scope_org(q, nil), do: q` is a pass-through with
    # no `Tenancy.scope(` in it; judged alone it reads as a hand-rolled
    # filter, and the first run of this audit duly flagged both
    # correctly-converted modules. The unit of "does this helper go
    # through the choke point" is the whole helper.
    |> Enum.group_by(fn {_line, head, _body} -> defp_name(head) end)
    |> Enum.flat_map(fn {_name, clauses} ->
      heads = Enum.map_join(clauses, "\n", fn {_l, head, _b} -> head end)
      bodies = Enum.map_join(clauses, "\n", fn {_l, _h, body} -> body end)

      if org_filter_shaped?(heads, bodies) and not Regex.match?(@choke_point_regex, bodies) do
        [clauses |> hd() |> then(fn {line, head, _} -> {line, String.trim(head)} end)]
      else
        []
      end
    end)
    |> Enum.sort()
  end

  defp defp_name(head) do
    case Regex.run(~r/^\s*defp\s+(\w+)/, head, capture: :all_but_first) do
      [name] -> name
      _ -> head
    end
  end

  defp org_filter_shaped?(head, body) do
    Regex.match?(@org_filter_name_regex, head) or
      Regex.match?(@raw_org_predicate_regex, body)
  end

  # Each block runs from its `defp` head to the next top-level
  # definition (or end of file), so a multi-clause helper's body is
  # examined clause by clause — a single clause that hand-rolls the
  # predicate is enough to flag, which is what we want.
  defp defp_blocks(source) do
    lines = String.split(source, "\n")

    starts =
      lines
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _idx} -> Regex.match?(~r/^\s{0,4}defp?\s+\w/, line) end)
      |> Enum.map(fn {_line, idx} -> idx end)

    starts
    |> Enum.with_index()
    |> Enum.filter(fn {start, _i} ->
      Regex.match?(~r/^\s{0,4}defp\s+\w/, Enum.at(lines, start - 1))
    end)
    |> Enum.map(fn {start, i} ->
      next = Enum.at(starts, i + 1, length(lines) + 1)
      head = Enum.at(lines, start - 1)
      body = lines |> Enum.slice((start - 1)..(next - 2)) |> Enum.join("\n")
      {start, head, body}
    end)
  end

  defp format_offenders(offenders) do
    body =
      Enum.map_join(offenders, "\n\n", fn {path, hits} ->
        sites = Enum.map_join(hits, "\n", fn {line, head} -> "      line #{line}: #{head}" end)
        "  #{path}\n#{sites}"
      end)

    """
    The following module(s) define a PRIVATE org filter of their own
    instead of composing the single viewer-scope choke point. Two
    independent copies of this filter previously disagreed about who
    could see what; a third copy re-opens that class of tenancy leak.

    Fix ONE of:

      (a) Resolve the viewer ONCE with `Platform.Tenancy.visibility/1`
          and compose the result with `Platform.Tenancy.scope/2`
          (`scope/3` with `binding: :last` when the org column lives on
          a joined row). See `Platform.Org.Context`'s `scope_org/2` and
          `Platform.Org.Wiki.Search`'s `scope_task_org/2` for the two
          shapes.

      (b) If you genuinely need a private org filter — because it is
          caller-supplied narrowing rather than a viewer scope, or
          because it deliberately uses a NARROWER bypass predicate than
          `root_member?/1` — add the file to `@allowlist` in this test
          DELIBERATELY, with a comment stating the reason. An
          uncommented entry is not an exemption, it is a silenced test.

    Offending sites:

    #{body}
    """
  end
end
