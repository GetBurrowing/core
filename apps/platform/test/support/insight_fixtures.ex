defmodule Platform.InsightFixtures do
  @moduledoc """
  Fixtures for insight dissemination tests (task 01a13867 stage 3): people
  with a given root-org membership, a dreaming agent, open insights inserted
  directly (so a test controls `disseminable`, `confidence` and the
  addressee without going through the journal parser), and the settings
  switch.
  """

  import Ecto.Query, only: [from: 2]
  import Platform.TenancyFixtures

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.Participant
  alias Platform.Memory.Briefing
  alias Platform.Memory.Insight
  alias Platform.Memory.Insights
  alias Platform.Memory.Insights.BriefingCard
  alias Platform.Memory.Insights.Disseminator
  alias Platform.Memory.Insights.Settings
  alias Platform.Repo
  alias Platform.Tenancy.OrgMembership

  @date "2026-10-18"

  defp n, do: System.unique_integer([:positive])

  @doc "A user with a root-org membership of `role`; `external: true` makes a guest."
  def person!(role \\ "member", opts \\ []) do
    i = n()

    user =
      Repo.insert!(%User{
        email: "insight-#{i}@example.com",
        name: "Insight Person #{i}",
        oidc_sub: "insight-#{i}"
      })

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: acme_org_id(),
      role: role,
      external: Keyword.get(opts, :external, false)
    })
    |> Repo.insert!()

    user
  end

  @doc "An agent pinned to the `memory.dreaming` responsibility."
  def dreaming_agent! do
    i = n()
    agent = Repo.insert!(%Agent{slug: "dreamer-#{i}", name: "Dreamer #{i}", status: "active"})
    {:ok, _} = Platform.Roles.set_override("memory.dreaming", agent.id)
    agent
  end

  @doc "Turn dissemination on (or apply `attrs`) as a fresh root admin."
  def enable_dissemination!(attrs \\ %{dissemination_enabled: true}) do
    {:ok, settings} = Settings.update(root_admin!(), attrs)
    settings
  end

  @doc """
  Insert an open insight. Defaults: a high-confidence, disseminable
  `briefing` from today's dreaming run, tiered `reversible`. Pass
  `:addressee` (a user) and any `Insight` field to override.
  """
  def insight!(attrs \\ %{}) do
    attrs = Map.new(attrs)
    addressee = Map.get(attrs, :addressee)

    base = %{
      journal_path: "org/journal/#{@date}.md",
      block_hash: "hash-#{n()}",
      run_id: Insights.run_id(nil, @date),
      action_type: "briefing",
      confidence: "high",
      body: "Deploys moved to host-b, ref #{n()}.",
      action: %{},
      org_id: acme_org_id(),
      addressee_user_id: addressee && addressee.id,
      addressee_reason: addressee && "named addressee",
      tier: "reversible",
      disseminable: true,
      origin: "dreaming"
    }

    %Insight{}
    |> Insight.changeset(Map.merge(base, Map.delete(attrs, :addressee)))
    |> Repo.insert!()
  end

  @doc """
  A HISTORICAL briefing canvas: what `Platform.Memory.Insights.Disseminator`
  delivered before task 01a15ee1 stage 1 moved briefings to the Inbox. The
  canvas hooks still act on such canvases, so their tests build one here.

  Renders `insights` plus every item already in `user`'s `memory_briefings`
  row for the day (`:now`, default now, in America/Chicago) into a canvas
  posted by the `memory.dreaming` agent in the person's DM. Creates the
  canvas (and the row, if none) the first time; on a later call re-renders
  the same canvas with every item the row holds (`replace_document`), the
  shape a same-day re-delivery had. Marks `insights` delivered. Returns the
  briefing row.
  """
  def legacy_briefing_canvas!(user, insights \\ [], opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    date = Disseminator.local_date(now)
    agent = Platform.Roles.assignee_for(Platform.Responsibilities.Handlers.Dreaming.key())
    {:ok, dm} = Chat.find_or_create_dm(user.id, "agent", agent.id)

    existing = Repo.get_by(Briefing, user_id: user.id, digest_date: date)

    items =
      Map.merge(
        (existing && existing.items) || %{},
        Map.new(insights, &{BriefingCard.node_key(&1), &1.id})
      )

    ids = Map.values(items)
    key_by_id = Map.new(items, fn {key, id} -> {id, key} end)

    entries =
      from(i in Insight, where: i.id in ^ids, order_by: [asc: i.inserted_at, asc: i.id])
      |> Repo.all()
      |> Enum.map(&{Map.fetch!(key_by_id, &1.id), &1})

    document =
      BriefingCard.document(date, entries, admin?: Platform.Tenancy.root_admin?(%{id: user.id}))

    briefing =
      case existing do
        %Briefing{canvas_id: canvas_id} when is_binary(canvas_id) ->
          canvas = Chat.get_canvas(canvas_id)
          {:ok, _} = Chat.patch_canvas(:system, canvas, [{:replace_document, document}])
          existing |> Briefing.changeset(%{items: items}) |> Repo.update!()

        _ ->
          agent_p =
            Repo.one!(
              from(p in Participant,
                where:
                  p.space_id == ^dm.id and p.participant_type == "agent" and
                    p.participant_id == ^agent.id,
                limit: 1
              )
            )

          {:ok, canvas, _message} =
            Chat.create_canvas_with_message(dm.id, agent_p.id, %{
              "title" => "Briefing " <> Date.to_iso8601(date),
              "document" => document,
              "message_content" => "Your briefing for " <> Date.to_iso8601(date)
            })

          attrs = %{
            user_id: user.id,
            space_id: dm.id,
            canvas_id: canvas.id,
            digest_date: date,
            items: items
          }

          (existing || %Briefing{}) |> Briefing.changeset(attrs) |> Repo.insert_or_update!()
      end

    Enum.each(insights, &Insights.mark_delivered(&1, now: now))
    briefing
  end
end
