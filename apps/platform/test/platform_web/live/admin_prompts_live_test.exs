defmodule PlatformWeb.AdminPromptsLiveTest do
  @moduledoc """
  Covers the admin prompt editor's *teaching surface* — the sample assigns that
  drive the preview and the per-variable descriptions in the sidebar (task
  `019fb949` stage 4).

  Why this is worth a test at all: a prompt author edits a template against
  what the preview shows. `task_slug` was sampled as `abc12345` and described
  as "Short task ID for use in branch names", which taught a truncated branch
  name — and truncation is the exact defect this task removed, because task ids
  are UUIDv7 and their first 8 hex characters are the high bits of a
  millisecond timestamp, constant across a ~65-second bucket. Two tasks filed a
  minute apart collapsed onto one branch and one worktree directory.

  The sample is not compared to a literal here. It is fed back through
  `HeartbeatScheduler.member_slug/1` — the single chokepoint every worktree and
  branch slug in the system routes through — and must come back unchanged. That
  ties the admin copy to the renderer's real behaviour rather than to a second
  string someone has to remember to update.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Experiments
  alias Platform.Orchestration.HeartbeatScheduler
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Repo
  alias Platform.Responsibilities
  alias Platform.Responsibilities.Responsibility
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  @slug "dispatch.deploying"

  # The sidebar's description cell. `Map.get(variable_descriptions(), var,
  # "Variable")` falls back to the bare word "Variable" for an undescribed
  # variable, so the fallback is detectable as a value rather than as an
  # absence.
  @description_cell ~r/mt-0\.5 text-\[11px\] text-base-content\/50">\s*([^<]*?)\s*<\/div>/

  # The page renders the template body TWICE: raw (with `{{placeholders}}`) in
  # the editor textarea, and interpolated in the preview `<pre>`. Asserting
  # against the whole document therefore matches the uninterpolated source
  # first and passes while the preview is broken — the first draft of this test
  # did exactly that and "found" a 13-character branch name, which is the
  # length of the literal `{{task_slug}}`. Read the preview only.
  #
  # Sliced with a regex rather than parsed: the LiveView renders the whole
  # application shell, whose inline `<script>` bodies are not valid markup to a
  # document parser, and the only thing needed here is one `<pre>`. HEEX escapes
  # the preview text, so the entities are reversed before matching — the single
  # quotes in the recovery glob arrive as `&#39;`.
  @preview_block ~r/<pre[^>]*>(.*?)<\/pre>/s

  # The branch reference in the preview. It moved when task 019fa63a took the
  # strategy steps out of the template body: the body's
  # "Open PR from `task/{{task_slug}}`" line is gone, and the branch is now
  # named by the per-repository sequence that
  # `HeartbeatScheduler.deploy_strategy_instructions/5` builds. Matching the
  # step-1 push line rather than the PR line because that is the one that names
  # the branch in the reconciled rendering.
  @branch_reference ~r/pushed to `task\/([^`]+)`/

  defp preview(html) do
    case Regex.run(@preview_block, html, capture: :all_but_first) do
      [body] ->
        body
        |> String.replace("&#39;", "'")
        |> String.replace("&quot;", "\"")
        |> String.replace("&lt;", "<")
        |> String.replace("&gt;", ">")
        |> String.replace("&amp;", "&")

      nil ->
        flunk("the admin prompt page rendered no preview block at all")
    end
  end

  setup %{conn: conn} do
    n = System.unique_integer([:positive])

    user =
      %User{}
      |> User.changeset(%{
        email: "admin-prompts-#{n}@example.com",
        name: "Admin Prompts #{n}",
        oidc_sub: "oidc-admin-prompts-#{n}"
      })
      |> Repo.insert!()

    org = Tenancy.get_org_by_slug!("fabrikam")

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org.id, role: "admin"})
    |> Repo.insert!()

    # The preview renders the DB row, and `seed_defaults/0` is INSERT-only —
    # so on a DB whose `dispatch.deploying` row was written by a migration run
    # months ago, every assertion below would be checking content nobody has
    # regenerated. Force the row to the current default first.
    :ok = PromptTemplates.seed_defaults()
    descriptor = Enum.find(PromptTemplates.default_templates(), &(&1.slug == @slug))

    {:ok, _} =
      @slug
      |> PromptTemplates.get_template_by_slug()
      |> PromptTemplates.update_template(%{
        content: PromptTemplates.default_content_for_slug(@slug),
        variables: descriptor.variables
      })

    {:ok, conn: Plug.Test.init_test_session(conn, %{"current_user_id" => user.id})}
  end

  describe "the task_slug teaching surface" do
    test "the preview renders a branch name the slug chokepoint accepts unchanged", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin/prompts/#{@slug}")

      branch_match = Regex.run(@branch_reference, preview(html), capture: :all_but_first)

      assert branch_match != nil,
             "the deploying preview must show the branch it deploys — got no `task/<...>` " <>
               "reference at all, so the preview teaches nothing about branch naming"

      [slug] = branch_match

      assert HeartbeatScheduler.member_slug(%{id: slug}) == slug,
             "the sample branch `#{slug}` is not what member_slug/1 would produce for that " <>
               "id, so the preview teaches a branch name no dispatch ever creates"

      assert String.length(slug) == 36
    end

    test "the preview's recovery step names a strict prefix of the sample slug", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin/prompts/#{@slug}")
      preview = preview(html)

      assert [slug] = Regex.run(@branch_reference, preview, capture: :all_but_first)

      prefix_match = Regex.run(~r/'task\/([^*']+)\*'/, preview, capture: :all_but_first)

      assert prefix_match != nil,
             "the transitional recovery glob did not render in the preview"

      [prefix] = prefix_match

      assert String.starts_with?(slug, prefix)
      assert byte_size(prefix) < byte_size(slug)
    end

    test "no preview or sidebar copy teaches the truncated form", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin/prompts/#{@slug}")

      refute html =~ "abc12345",
             "the 8-character placeholder slug is still being shown as a branch name"

      refute html =~ "Short task ID",
             "the sidebar still describes task_slug as a short id"

      assert html =~ "Full task UUID used for the worktree path and branch name"
    end

    test "every variable this template declares carries a description", %{conn: conn} do
      # Derived from the template descriptor rather than from a list written
      # here: adding a variable to the template and forgetting the description
      # must fail, and it cannot if the test only checks variables it names.
      descriptor = Enum.find(PromptTemplates.default_templates(), &(&1.slug == @slug))
      {:ok, _view, html} = live(conn, ~p"/admin/prompts/#{@slug}")

      descriptions =
        @description_cell
        |> Regex.scan(html, capture: :all_but_first)
        |> List.flatten()

      assert length(descriptions) == length(descriptor.variables),
             "the sidebar rendered #{length(descriptions)} description cells for " <>
               "#{length(descriptor.variables)} declared variables"

      refute "Variable" in descriptions,
             "at least one declared variable fell back to the placeholder description; " <>
               "declared but undescribed variables are the shape the task_slug copy rot took"
    end
  end

  # ── Variant awareness (task 019fe6ba, ADR-0048) ─────────────────────────
  #
  # Every assertion here goes through `data-role`, not through rendered copy.
  # The page is long and full of prose; a whole-page `=~` on the notice
  # wording can be satisfied by an unrelated element and would stay green
  # through exactly the regression this covers. LazyHTML, not Floki.

  describe "the running-experiment notice" do
    defp q(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)

    defp running_experiment_on(template_slug, name) do
      {:ok, experiment} =
        Experiments.create_experiment(%{
          slug: "exp-#{System.unique_integer([:positive])}",
          name: name,
          primary_metric: "validation_failure_rate",
          stop_rule: %{"min_subjects" => 120}
        })

      {:ok, experiment} = Experiments.activate(experiment, template_slug)
      experiment
    end

    test "renders, names the experiment, and links to it", %{conn: conn} do
      experiment = running_experiment_on(@slug, "planner-terser-briefs")

      {:ok, _view, html} = live(conn, ~p"/admin/prompts/#{@slug}")

      notice = q(html, ~s([data-role="experiment-snapshot-notice"]))
      assert Enum.count(notice) == 1

      # It NAMES the experiment — "there is a running experiment" is a fact,
      # the name is what makes it actionable.
      assert LazyHTML.text(notice) =~ "planner-terser-briefs"

      link = q(html, ~s([data-role="experiment-snapshot-notice-link"]))
      assert LazyHTML.attribute(link, "href") == ["/control/experiments/#{experiment.slug}"]
    end

    test "is absent on a template with no experiment", %{conn: conn} do
      # The other direction, seeded explicitly. A refute alone stays green
      # when the writer never fires at all, so this test is only worth
      # anything next to the one above — and vice versa.
      {:ok, _view, html} = live(conn, ~p"/admin/prompts/#{@slug}")

      assert q(html, ~s([data-role="experiment-snapshot-notice"])) |> Enum.count() == 0
      assert q(html, ~s([data-role="variant-editor"])) |> Enum.count() == 0
    end

    test "is not dismissible and survives a save", %{conn: conn} do
      running_experiment_on(@slug, "survives-save")

      {:ok, view, html} = live(conn, ~p"/admin/prompts/#{@slug}")

      # No dismiss affordance of any kind inside the notice.
      assert q(html, ~s([data-role="experiment-snapshot-notice"] button)) |> Enum.count() == 0

      saved =
        view
        |> form("form", template: %{content: "Edited mid-experiment.", name: "n"})
        |> render_submit()

      assert q(saved, ~s([data-role="experiment-snapshot-notice"])) |> Enum.count() == 1
    end

    test "a concluded experiment produces no notice", %{conn: conn} do
      experiment = running_experiment_on(@slug, "already-done")
      {:ok, _} = Experiments.conclude(experiment)

      {:ok, _view, html} = live(conn, ~p"/admin/prompts/#{@slug}")

      assert q(html, ~s([data-role="experiment-snapshot-notice"])) |> Enum.count() == 0
    end
  end

  describe "the variant diff" do
    test "an unchanged variant says so rather than rendering blank", %{conn: conn} do
      experiment = running_experiment_on(@slug, "empty-diff")
      control = Experiments.get_variant(experiment, "control")

      {:ok, _} = Experiments.add_variant(experiment, %{slug: "b", content: control.content})

      {:ok, view, _html} = live(conn, ~p"/admin/prompts/#{@slug}")
      html = view |> element(~s([data-role="variant-option"][data-variant="b"])) |> render_click()

      assert q(html, ~s([data-role="variant-diff-empty"])) |> Enum.count() == 1
      assert q(html, ~s([data-role="variant-diff"])) |> Enum.count() == 0
    end

    test "the selector switches which blob is diffed", %{conn: conn} do
      experiment = running_experiment_on(@slug, "switching")

      {:ok, _} =
        Experiments.add_variant(experiment, %{slug: "b", content: "WHOLLY DIFFERENT VARIANT"})

      {:ok, view, html} = live(conn, ~p"/admin/prompts/#{@slug}")

      # Control against itself: empty.
      assert q(html, ~s([data-role="variant-diff-empty"])) |> Enum.count() == 1

      switched =
        view |> element(~s([data-role="variant-option"][data-variant="b"])) |> render_click()

      assert q(switched, ~s([data-role="variant-diff"])) |> Enum.count() == 1

      assert q(switched, ~s([data-role="variant-diff-ins"])) |> LazyHTML.text() =~
               "WHOLLY DIFFERENT VARIANT"
    end

    test "the diff tracks the SNAPSHOT after the live row has moved", %{conn: conn} do
      experiment = running_experiment_on(@slug, "snapshot-tracking")
      control = Experiments.get_variant(experiment, "control")

      {:ok, _} = Experiments.add_variant(experiment, %{slug: "b", content: control.content})

      # Move the live template row far away from the snapshot. If the diff
      # were computed against `prompt_templates.content` — the specific way
      # this surface would lie — variant `b` would now appear to differ, and
      # it would look completely ordinary.
      {:ok, _} =
        @slug
        |> PromptTemplates.get_template_by_slug()
        |> PromptTemplates.update_template(%{content: "LIVE ROW HAS MOVED SINCE ACTIVATION"})

      {:ok, view, _html} = live(conn, ~p"/admin/prompts/#{@slug}")
      html = view |> element(~s([data-role="variant-option"][data-variant="b"])) |> render_click()

      assert q(html, ~s([data-role="variant-diff-empty"])) |> Enum.count() == 1,
             "the diff moved with the live template row instead of staying on the snapshot"

      refute q(html, ~s([data-role="variant-diff"])) |> LazyHTML.text() =~ "LIVE ROW HAS MOVED"
    end
  end

  describe "the declared-but-unbacked row (task 01a0a74d stage 4)" do
    setup do
      # Seeded here rather than leaning on either REAL orphan. The task's own
      # orphans move under it: stage 2 seeded `memory.daily_summary.v1`, so it
      # resolves now, and `meetings.summarize.v1` is out of scope and could be
      # seeded by anyone. A test that asserted on either would be asserting on
      # the state of the fix, not on the rendering.
      #
      # The slug sorts between `dispatch.` and `historian.` deliberately — the
      # sort-position assertion below needs a known neighbour on each side and
      # a slug hoisted to the top would pass a test that hoisting also passes.
      key = "fakegap.render"
      slug = "fakegap.render.v1"

      {:ok, row} =
        Responsibilities.create_responsibility(%{
          key: key,
          feature: "fakegap",
          trigger_kind: "cron",
          trigger_config: %{"expression" => "0 23 * * *"},
          scope: "global",
          cost_profile: "low_freq_capable",
          default_prompt_template: slug
        })

      assert PromptTemplates.get_template_by_slug(slug) == nil,
             "the fixture is only meaningful while no template carries #{slug}"

      {:ok, key: key, slug: slug, row: row}
    end

    test "the declared slug appears in the table even though no template row exists", %{
      conn: conn,
      slug: slug
    } do
      {:ok, _view, html} = live(conn, ~p"/admin/prompts")

      assert html =~ slug,
             "the page lists only what exists, so the one thing a cron is firing at and " <>
               "nobody has is still invisible"

      assert html =~ "declared-missing-row"
    end

    test "it sits in SORT ORDER among the real templates, not hoisted above them", %{
      conn: conn,
      slug: slug
    } do
      {:ok, _view, html} = live(conn, ~p"/admin/prompts")

      # Byte offsets rather than a parsed table: what matters is the order the
      # reader meets these strings in, and `:binary.match/2` measures exactly
      # that without depending on the markup around them.
      #
      # `dispatch.deploying` sorts BEFORE and `historian.` sorts AFTER
      # `fakegap.render.v1`, so a hoisted row fails the first assertion and a
      # row appended at the end fails the second. Either alone passes for the
      # wrong reason.
      {before_at, _} = :binary.match(html, "dispatch.deploying")
      {missing_at, _} = :binary.match(html, slug)
      {after_at, _} = :binary.match(html, "historian.")

      assert before_at < missing_at,
             "the declared-but-unbacked row was hoisted above the templates that sort " <>
               "before it — the direction is a row IN PLACE, not a banner with a body"

      assert missing_at < after_at,
             "the declared-but-unbacked row landed after slugs it sorts before"
    end

    test "the utility line states what is true and what it implies", %{conn: conn, key: key} do
      {:ok, _view, html} = live(conn, ~p"/admin/prompts")

      assert html =~ "declared-missing-utility"
      assert html =~ "no template · dispatches render empty"

      assert html =~ key,
             "the utility line must name the responsibility KEY — the mono cell carries " <>
               "the slug so sort order is meaningful, and the key is the thing you go and fix"
    end

    test "there is NO banner and NO count of missing templates above the list", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin/prompts")

      index = html |> String.split("<table") |> hd()

      refute index =~ "declared-missing",
             "something about the missing key is rendered above the table. A banner is " <>
               "attached to the list and can be read past; a row IS the list"

      # No generic `refute index =~ "alert-*"`: the application shell renders
      # flash containers with those classes on every page, so such a check
      # fails for a reason that has nothing to do with this feature. The
      # discriminating assertion is that nothing carrying this feature's own
      # `declared-missing` marker renders above the table.

      # The header badge is the count of templates that EXIST. Folding the
      # orphan into it is the badge-count this design refuses, and it would
      # also make the number disagree with `list_templates/0`.
      assert index =~
               ~s(<span class="badge badge-ghost badge-sm">#{length(PromptTemplates.list_templates())}</span>)
    end

    test "selecting it renders the refusal, and NOT an editor", %{conn: conn, slug: slug} do
      {:ok, view, _html} = live(conn, ~p"/admin/prompts")

      html =
        view
        |> element(~s([data-role="declared-missing-row"][data-slug="#{slug}"]))
        |> render_click()

      assert html =~
               "No template carries this slug. A cron fires this responsibility, so the dispatch"

      assert html =~ "Create a template for this key"

      refute html =~ "<textarea",
             "an empty editor is the shape that invites someone to type a body into it " <>
               "without deciding whether this key should have one"

      refute html =~ ~s(name="template[content]")
    end

    test "with ZERO orphans the table renders exactly as it did before", %{conn: conn} do
      {:ok, _view, with_orphan} = live(conn, ~p"/admin/prompts")

      # Empty the audit's source rather than stubbing the module: the union is
      # supposed to collapse to `list_templates/0` when the declared side is
      # empty, and the cheapest honest way to show that is to make it empty.
      Repo.delete_all(Responsibility)

      {:ok, _view, without} = live(conn, ~p"/admin/prompts")

      refute without =~ "declared-missing"

      assert table(without) == table_without_marked_rows(with_orphan),
             "removing the declared key changed the table beyond dropping its row — the " <>
               "union is a regression on every page that has no orphans, which is most of them"
    end
  end

  defp table(html) do
    [_, rest] = String.split(html, "<table", parts: 2)
    [body, _] = String.split(rest, "</table>", parts: 2)
    body
  end

  defp table_without_marked_rows(html) do
    html
    |> table()
    |> String.split("<tr")
    |> Enum.reject(&String.contains?(&1, "declared-missing"))
    |> Enum.join("<tr")
  end
end
