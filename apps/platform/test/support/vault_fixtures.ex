defmodule Platform.VaultFixtures do
  @moduledoc """
  Fixtures for the shared vault scope (task 01a131c5): root-admin and
  non-admin users, agents, and grant / log helpers. Every secret value used
  with these is an obviously fake test string.
  """

  import Ecto.Query

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Repo
  alias Platform.TenancyFixtures
  alias Platform.Tenancy.OrgMembership
  alias Platform.Vault.AccessGrant
  alias Platform.Vault.AccessLog

  def unique, do: System.unique_integer([:positive, :monotonic])

  def unique_slug(prefix \\ "shared"), do: "#{prefix}-#{unique()}"

  def user!(role) do
    n = unique()

    user =
      %User{}
      |> User.changeset(%{
        email: "vault-#{n}@example.com",
        name: "Vault #{n}",
        oidc_sub: "oidc-vault-#{n}"
      })
      |> Repo.insert!()

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: TenancyFixtures.acme_org_id(),
      role: role
    })
    |> Repo.insert!()

    user
  end

  def admin!, do: user!("admin")
  def non_admin!, do: user!("member")

  def agent! do
    n = unique()

    %Agent{}
    |> Agent.changeset(%{slug: "vault-agent-#{n}", name: "Vault Agent #{n}", status: "active"})
    |> Repo.insert!()
  end

  def grant!(credential_id, agent_id, permissions \\ ["use"]) do
    Repo.insert!(%AccessGrant{
      credential_id: credential_id,
      grantee_type: "agent",
      grantee_id: agent_id,
      permissions: permissions
    })
  end

  def grants_for(credential_id) do
    from(g in AccessGrant, where: g.credential_id == ^credential_id, order_by: g.grantee_id)
    |> Repo.all()
  end

  def logs_for_slug(slug) do
    from(l in AccessLog,
      where: l.credential_slug == ^slug,
      order_by: [asc: l.inserted_at, asc: l.id]
    )
    |> Repo.all()
  end
end
