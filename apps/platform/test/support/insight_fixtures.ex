defmodule Platform.InsightFixtures do
  @moduledoc """
  Fixtures for insight dissemination tests (task 01a13867 stage 3): people
  with a given root-org membership, a dreaming agent, open insights inserted
  directly (so a test controls `disseminable`, `confidence` and the
  addressee without going through the journal parser), and the settings
  switch.
  """

  import Platform.TenancyFixtures

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Memory.Insight
  alias Platform.Memory.Insights
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
      body: "Deploys moved to moon, ref #{n()}.",
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
end
