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
  alias Platform.Orchestration.HeartbeatScheduler
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Repo
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
end
