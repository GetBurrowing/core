defmodule PlatformWeb.DrawerWidthParityTest do
  @moduledoc """
  Parity guard for the three right-side drawers (task 019f5eb3).

  `task_detail_component.ex`, `stacks_component.ex` and `skills_live.html.heex`
  each carry their own hand-copied version of one recipe:
  `fixed ... right-0 z-30 ... border-l border-edge bg-base-100 shadow-xl`.
  Before this task they had drifted 31% apart in width (512px, 512px, 672px)
  with nothing asserting they should match. This file is what fails when the
  next edit widens one and leaves the other two behind.

  Three assertions per drawer, and the third is the one that matters most:

    1. `w-full`, the mobile full-bleed base, asserted as a class TOKEN. A
       substring check would pass on `max-w-full` alone, which is a max-width
       and not a width.
    2. `lg:max-w-[min(60vw,60rem)]`, the shared desktop cap, byte-identical
       across all three. This is the source literal as it appears in the
       rendered HTML. The BUILT stylesheet spells it differently (Tailwind
       escapes the comma in the selector and emits a space in the
       declaration), so do not "correct" this to the escaped form: the two
       are different checks over different artefacts.
    3. No unprefixed arbitrary max-width. `min(60vw,60rem)` resolves to 234px
       on a 390px phone, so dropping the `lg:` prefix shrinks the mobile
       drawer from full-screen to a third of it. That regression is invisible
       in a desktop test and in a desktop screenshot; it fails here instead.

  ## Selection

  Only the stacks panel carries a `data-role`. The other two have no `id` and
  no `data-role`, and this stage adds none: a template edit to make a test
  easier is still a template edit. They are selected by the drawer recipe,
  with an assertion that exactly one element on the page matches it, so the
  identification is pinned rather than assumed. The stacks case cross-checks
  the recipe-selected tag against `open_tag_for(html, "stack-detail-panel")`,
  which is direct evidence the recipe selects the panel the reader means.

  ## The fourth panel is deliberately absent

  `stacks_component.ex:680` (`data-role="stack-feedback-overlay-panel"`) is a
  fourth element on the same width recipe, still capped at `md:max-w-lg` =
  512px. It was left alone on purpose: the plan named three sites, and
  widening a `z-40` overlay was never approved. It is an open decision for
  Robin, not an oversight. It does not appear here, and it would fail
  assertion 2 by design if it were added. It is also out of reach of the
  recipe selector below, which requires the unprefixed `fixed` and `right-0`
  that the overlay (`absolute inset-0 ... md:right-0 ... shadow-2xl`) does
  not carry.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.OpenTag

  alias Platform.Accounts.User
  alias Platform.Repo
  alias Platform.Skills.Skill
  alias Platform.Tasks
  alias Platform.Tasks.Stacks

  # The class tokens shared by all three drawers, and by nothing else on the
  # pages under test. The z-30 backdrops (`fixed inset-0 z-30 bg-black/30`)
  # carry neither `right-0` nor the border/shadow pair, so they are excluded.
  @recipe ~w(fixed right-0 z-30 border-l border-edge bg-base-100 shadow-xl)

  @desktop_cap "lg:max-w-[min(60vw,60rem)]"

  describe "right-side drawer width parity" do
    test "the task detail drawer", %{conn: conn} do
      project = create_project()
      task = create_task(project)

      conn = authenticated_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      # The panel really opened: `data-role="detail-title"` renders inside it.
      assert html =~ ~s|data-role="detail-title"|

      html
      |> sole_drawer_tag!("the task detail drawer at /tasks/:id")
      |> assert_width_parity("task_detail_component.ex")
    end

    test "the stack detail drawer", %{conn: conn} do
      project = create_project()
      stack = stack_fixture(project)

      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks")

      _ =
        render_click(with_target(view, "#tasks-stacks"), "stack_open_detail", %{"id" => stack.id})

      html = render(view)

      tag = sole_drawer_tag!(html, "the stack detail drawer at /tasks")

      # This panel is the one with a stable marker, so it is also the one that
      # can prove the recipe selector picks the element the test names.
      assert tag == open_tag_for(html, "stack-detail-panel"),
             "the recipe-selected drawer is not the stack-detail-panel element"

      assert_width_parity(tag, "stacks_component.ex")
    end

    test "the skill detail drawer", %{conn: conn} do
      skill = skill_fixture()

      conn = authenticated_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/skills/#{skill.slug}")

      # The panel really opened: it wraps the skill name header.
      assert html =~ skill.name

      html
      |> sole_drawer_tag!("the skill detail drawer at /skills/:slug")
      |> assert_width_parity("skills_live.html.heex")
    end
  end

  # ── assertions ────────────────────────────────────────────────────────────

  defp assert_width_parity(tag, source_file) do
    tokens = class_tokens(tag)
    classes = Enum.join(tokens, " ")

    assert "w-full" in tokens,
           "#{source_file}: the drawer lost its `w-full` mobile full-bleed base. " <>
             "Class tokens: #{classes}"

    assert @desktop_cap in tokens,
           "#{source_file}: the drawer is missing the shared desktop cap " <>
             "`#{@desktop_cap}`, so it no longer matches the other two above " <>
             "1024px. Class tokens: #{classes}"

    # Any arbitrary max-width must carry the `lg:` prefix. An unprefixed
    # `max-w-[min(60vw,60rem)]` is 234px on a 390px phone; a `md:`-prefixed one
    # narrows the tablet drawer. Either is a regression a desktop check cannot
    # see, so the guard refuses every arbitrary cap that is not `lg:`-scoped.
    # A future breakpoint that genuinely needs one is a deliberate edit here.
    refute Regex.match?(~r/(?<!lg:)max-w-\[/, classes),
           "#{source_file}: the drawer carries an arbitrary max-width that is " <>
             "not `lg:`-prefixed, which applies the desktop cap on phones. " <>
             "Class tokens: #{classes}"
  end

  # The single element on the page carrying the drawer recipe. Failing loudly
  # on zero or many is the point: zero means the drawer stopped rendering (or
  # the recipe drifted), many means a second element now answers to the same
  # recipe and the test can no longer say which one it measured.
  defp sole_drawer_tag!(html, where) do
    case open_tags_with_classes(html, @recipe) do
      [tag] ->
        tag

      [] ->
        flunk("no element matching the drawer recipe #{inspect(@recipe)} rendered for #{where}")

      many ->
        flunk(
          "expected exactly one element matching the drawer recipe #{inspect(@recipe)} " <>
            "for #{where}, got #{length(many)}: #{inspect(many)}"
        )
    end
  end

  # ── fixtures ──────────────────────────────────────────────────────────────

  defp authenticated_conn(conn) do
    user =
      Repo.insert!(%User{
        email: "drawer_parity_#{System.unique_integer([:positive])}@example.com",
        name: "Drawer Parity User",
        oidc_sub: "oidc-drawer-parity-#{System.unique_integer([:positive])}"
      })
      |> Platform.TenancyFixtures.member_of_all_orgs!()

    init_test_session(conn, current_user_id: user.id)
  end

  defp create_project do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Drawer Parity Project #{System.unique_integer([:positive])}",
        repo_url: "git@github.com:test/repo.git"
      })

    project
  end

  defp create_task(project) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Drawer Parity Task #{System.unique_integer([:positive])}",
        status: "backlog",
        priority: "medium"
      })

    task
  end

  defp stack_fixture(project) do
    slug = "drawer-parity-#{System.unique_integer([:positive])}"

    {:ok, stack} =
      Stacks.create_stack(%{
        project_id: project.id,
        slug: slug,
        name: "Drawer Parity Stack",
        rollup_branch: Stacks.rollup_branch_name(slug)
      })

    stack
  end

  defp skill_fixture do
    {:ok, skill} =
      %Skill{}
      |> Skill.changeset(%{
        name: "Drawer Parity Skill #{System.unique_integer([:positive])}",
        content: "body"
      })
      |> Repo.insert()

    skill
  end
end
