defmodule Platform.Seeds.CanvasExplorerFixtureTest do
  @moduledoc """
  Runs `priv/scripts/seed_canvas_explorer_fixture.exs` against the sandbox
  (task 01a08c4f stage 2).

  The sandbox holds what a freshly migrated DB holds: the root org seeded by
  `20260519143620_seed_root_orgs.exs` and no project, no user and no chat
  space. The setup asserts that explicitly, so a future migration that seeds
  any of those makes this test fail loudly instead of quietly exercising the
  populated path.

  Case B exists because Case A, on a fixture that cannot create its own
  project, dies at the project lookup before it ever reaches participation.
  Pre-inserting the project and the dev user isolates the second defect: the
  dev user was never joined to the fixture's spaces, so the explorer (which
  reads `Chat.list_user_conversations/2`) showed it none of them.

  Each eval writes about 400 canvases; the corpus is not shrunk because the
  fixture's own read-path checks depend on its shape.
  """
  use Platform.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureIO

  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.{Canvas, Participant, Space}
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Project
  alias Platform.Tenancy.Org

  @moduletag timeout: 600_000

  @fixture_path Path.expand("priv/scripts/seed_canvas_explorer_fixture.exs", File.cwd!())
  @tag_name "canvas-explorer-fixture"
  @dev_identity %{sub: "dev-local-user", email: "dev@localhost", name: "Dev User"}

  defp run_fixture do
    {micros, output} = :timer.tc(fn -> capture_io(fn -> Code.eval_file(@fixture_path) end) end)
    IO.puts(:stderr, "[01a08c4f timing] fixture eval took #{div(micros, 1000)}ms")
    output
  end

  defp fixture_space_ids do
    Repo.all(
      from(s in Space,
        where: fragment("?->>'fixture' = ?", s.metadata, ^@tag_name),
        select: s.id
      )
    )
  end

  defp dev_user do
    Repo.get_by(User, oidc_sub: "dev-local-user")
  end

  defp dev_user_participant_rows(user_id, space_ids) do
    Repo.all(
      from(p in Participant,
        where:
          p.participant_type == "user" and p.participant_id == ^user_id and
            p.space_id in ^space_ids
      )
    )
  end

  defp live_fixture_canvas_count do
    Repo.aggregate(
      from(c in Canvas,
        where: fragment("?->>'fixture' = ?", c.metadata, ^@tag_name) and is_nil(c.deleted_at)
      ),
      :count
    )
  end

  defp conversation_ids(user_id) do
    user_id |> Chat.list_user_conversations() |> Enum.map(& &1.id) |> MapSet.new()
  end

  setup do
    assert Repo.aggregate(Project, :count) == 0,
           "precondition: the sandbox must hold no project (the fresh-DB condition)"

    assert Repo.aggregate(User, :count) == 0,
           "precondition: the sandbox must hold no user (no one has hit /dev/login)"

    assert Repo.aggregate(Space, :count) == 0,
           "precondition: the sandbox must hold no chat space"

    roots = Repo.all(from(o in Org, where: is_nil(o.parent_org_id)))
    assert [root] = roots, "precondition: exactly one root org, got #{length(roots)}"

    %{root: root}
  end

  test "A: on a fresh DB the fixture creates its project and dev user and joins it to all 16 spaces",
       %{root: root} do
    run_fixture()

    assert [project] = Repo.all(Project)
    assert project.org_id == root.id
    assert project.slug == "#{@tag_name}-project"

    assert [user] = Repo.all(User)
    assert user.oidc_sub == "dev-local-user"

    space_ids = fixture_space_ids()
    assert length(space_ids) == 16

    assert conversation_ids(user.id) == MapSet.new(space_ids),
           "list_user_conversations/2 returned #{MapSet.size(conversation_ids(user.id))} " <>
             "of 16 fixture spaces"

    assert length(Chat.list_canvas_groups(space_ids, limit: 20)) == 16
  end

  test "B: with a project and dev user already present, the fixture reuses the project and joins the user" do
    {:ok, project} =
      Tasks.create_project(%{name: "Pre-existing project", slug: "pre-existing-project"})

    {:ok, user} = Accounts.find_or_create_from_oidc(@dev_identity)

    run_fixture()

    assert [%Project{id: reused_id}] = Repo.all(Project)
    assert reused_id == project.id

    space_ids = fixture_space_ids()
    assert length(space_ids) == 16

    joined = dev_user_participant_rows(user.id, space_ids)

    assert length(joined) == 16,
           "the dev user participates in #{length(joined)} of 16 fixture spaces"

    assert conversation_ids(user.id) == MapSet.new(space_ids)
  end

  test "C: a second run adds no project, user, space or participant row and keeps the live corpus size" do
    run_fixture()

    first = %{
      projects: Repo.aggregate(Project, :count),
      users: Repo.aggregate(User, :count),
      spaces: Repo.aggregate(Space, :count),
      live_canvases: live_fixture_canvas_count()
    }

    run_fixture()

    second = %{
      projects: Repo.aggregate(Project, :count),
      users: Repo.aggregate(User, :count),
      spaces: Repo.aggregate(Space, :count),
      live_canvases: live_fixture_canvas_count()
    }

    assert second == first
    assert %{projects: 1, users: 1, spaces: 16} = first

    user = dev_user()
    space_ids = fixture_space_ids()
    rows = dev_user_participant_rows(user.id, space_ids)

    assert length(rows) == 16
    assert rows |> Enum.map(& &1.space_id) |> Enum.uniq() |> length() == 16
  end
end
