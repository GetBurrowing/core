defmodule Platform.Federation.ToolSurfacePeoplePagesTest do
  @moduledoc """
  The people-page rules at the memory-tool boundary (task 01a1aa47 stage 5):
  guarded writes, the private-tier leak guard on `memory_view` and
  `memory_search`, and the unchanged Historian gate.
  """

  use Platform.DataCase, async: false

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.ExternalUserFixtures
  alias Platform.Federation.ToolSurface
  alias Platform.Org.Wiki
  alias Platform.Org.{WikiJournalEntry, WikiPage}
  alias Platform.People.Visibility
  alias Platform.Repo

  @private_path "org/page/people/marisol-tennebrook/private.md"

  setup do
    Repo.delete_all(WikiPage)
    Repo.delete_all(WikiJournalEntry)

    historian = create_agent("historian", assign_historian?: true)
    plain = create_agent("plain")
    subject = ExternalUserFixtures.create_user!(%{name: "Marisol Tennebrook"})
    bystander = ExternalUserFixtures.create_user!(%{name: "Oskar Vellinghausen"})

    %{historian: historian, plain: plain, subject: subject, bystander: bystander}
  end

  defp create_agent(slug_prefix, opts \\ []) do
    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "#{slug_prefix}-#{System.unique_integer([:positive, :monotonic])}",
        name: String.capitalize(slug_prefix),
        status: "active"
      })
      |> Repo.insert()

    if Keyword.get(opts, :assign_historian?, false) do
      {:ok, _} = Platform.Roles.assign_role("historian", agent.id)
    end

    agent
  end

  defp context(%Agent{id: id}), do: %{agent_id: id}
  defp context(%Agent{id: id}, space_id), do: %{agent_id: id, space_id: space_id}

  defp space!(kind, users) do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{
        name: "people-#{kind}-#{n}",
        slug: "people-#{kind}-#{n}",
        kind: kind,
        is_direct: kind == "dm"
      })

    for user <- users do
      {:ok, _} =
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: user.id,
          role: "member",
          joined_at: DateTime.utc_now()
        })
    end

    space
  end

  defp private_markdown(subject) do
    """
    ---
    name: Marisol Tennebrook
    user_id: #{subject.id}
    relation: team
    ---

    ## Role
    Platform lead. Reach her on 904-555-0100.

    ## Interactions
    - 2026-10-02 meeting: Deploy review [cite: msg-1]

    ## Perspectives
    - I prefer small PRs — own words [cite: msg-3]
    - Seems to dislike meetings
    """
  end

  defp create_private!(historian, subject) do
    assert {:ok, result} =
             ToolSurface.execute(
               "memory_create",
               %{"path" => @private_path, "file_text" => private_markdown(subject)},
               context(historian)
             )

    result
  end

  test "memory_create on a private profile persists the guarded body and reports guard counts",
       %{historian: h, subject: subject} do
    result = create_private!(h, subject)

    assert result.path == @private_path
    assert result.guard.dropped_uncited_perspectives == 1
    assert result.guard.redactions == 1

    page = Wiki.get_page(@private_path)
    assert page.frontmatter["tier"] == "private"
    assert page.frontmatter["subject_user_id"] == subject.id
    assert page.frontmatter["readers"] == ["subject", "admins"]
    refute page.content =~ "dislike meetings"
    refute page.content =~ "904-555-0100"
    assert page.content =~ "own words [cite: msg-3]"

    # the index was regenerated as a side effect of the people write
    assert %{} = Wiki.get_page(Visibility.index_path())

    # a non-people page write carries no guard key
    assert {:ok, plain} =
             ToolSurface.execute(
               "memory_create",
               %{"path" => "org/page/deploys.md", "file_text" => "# Deploys\n"},
               context(h)
             )

    refute Map.has_key?(plain, :guard)
  end

  test "memory_view of a private profile is refused in a channel the subject is not in",
       %{historian: h, subject: subject, bystander: bystander} do
    create_private!(h, subject)
    channel = space!("channel", [bystander])

    assert {:error, env} =
             ToolSurface.execute(
               "memory_view",
               %{"path" => @private_path},
               context(h, channel.id)
             )

    assert env.code == :private_profile_not_in_space
    refute env.error =~ "exist"

    # the same refusal for a private path with no page behind it
    assert {:error, %{code: :private_profile_not_in_space}} =
             ToolSurface.execute(
               "memory_view",
               %{"path" => Visibility.private_path("nobody-here")},
               context(h, channel.id)
             )

    # a group the subject is not in refuses too
    group = space!("group", [bystander])

    assert {:error, %{code: :private_profile_not_in_space}} =
             ToolSurface.execute("memory_view", %{"path" => @private_path}, context(h, group.id))

    # the card is unaffected
    assert {:ok, _} =
             ToolSurface.execute(
               "memory_create",
               %{
                 "path" => Visibility.card_path("marisol-tennebrook"),
                 "file_text" =>
                   "---\nname: Marisol Tennebrook\nrelation: team\n---\n\n## Role\nLead.\n"
               },
               context(h)
             )

    assert {:ok, %{content: card}} =
             ToolSurface.execute(
               "memory_view",
               %{"path" => Visibility.card_path("marisol-tennebrook")},
               context(h, channel.id)
             )

    assert card =~ "tier: card"
  end

  test "memory_view of a private profile succeeds in a dm with the subject and with no space",
       %{historian: h, subject: subject, bystander: bystander} do
    create_private!(h, subject)
    dm = space!("dm", [subject, bystander])

    assert {:ok, %{content: content}} =
             ToolSurface.execute("memory_view", %{"path" => @private_path}, context(h, dm.id))

    assert content =~ "own words [cite: msg-3]"

    assert {:ok, %{content: ^content}} =
             ToolSurface.execute("memory_view", %{"path" => @private_path}, context(h))

    assert {:ok, %{content: ^content}} =
             ToolSurface.execute(
               "memory_view",
               %{"path" => @private_path},
               context(h, nil)
             )
  end

  test "memory_search omits private-tier hits in a channel without the subject",
       %{historian: h, subject: subject, bystander: bystander} do
    create_private!(h, subject)

    # a non-private page with the same distinctive term stays visible
    assert {:ok, _} =
             ToolSurface.execute(
               "memory_create",
               %{
                 "path" => "org/page/deploy-review.md",
                 "file_text" =>
                   "# Deploy review\n\nThe deploy review covers the deploy pipeline.\n"
               },
               context(h)
             )

    channel = space!("channel", [bystander])
    dm = space!("dm", [subject])

    assert {:ok, %{results: in_channel}} =
             ToolSurface.execute(
               "memory_search",
               %{"query" => "deploy review", "source" => "page"},
               context(h, channel.id)
             )

    assert {:ok, %{results: in_dm}} =
             ToolSurface.execute(
               "memory_search",
               %{"query" => "deploy review", "source" => "page"},
               context(h, dm.id)
             )

    dm_paths = Enum.map(in_dm, & &1.path)
    channel_paths = Enum.map(in_channel, & &1.path)

    assert @private_path in dm_paths,
           "search did not find the private page at all: #{inspect(dm_paths)}"

    refute @private_path in channel_paths
    assert "org/page/deploy-review.md" in channel_paths
  end

  test "a non-Historian write is still refused with historian_required",
       %{plain: plain, subject: subject} do
    assert {:error, env} =
             ToolSurface.execute(
               "memory_create",
               %{"path" => @private_path, "file_text" => private_markdown(subject)},
               context(plain)
             )

    assert env.code == :historian_required
    assert Wiki.get_page(@private_path) == nil
  end
end
