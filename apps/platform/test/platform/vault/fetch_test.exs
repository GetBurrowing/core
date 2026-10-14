defmodule Platform.Vault.FetchTest do
  @moduledoc """
  Task 01a131c5 stage 1 — single-use fetch tickets (`Platform.Vault.Fetch`).

  The redeem path re-checks the grant, so these tests pin the cases where
  issue-time and redeem-time disagree: ungrant after issue, rotation after
  issue, reuse and expiry.
  """
  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.VaultFixtures

  alias Platform.Repo
  alias Platform.Vault
  alias Platform.Vault.Fetch
  alias Platform.Vault.FetchTicket
  alias Platform.Vault.Shared

  @value "fake-fetchable-value"

  setup do
    admin = admin!()
    agent = agent!()
    slug = unique_slug()
    {:ok, cred} = Shared.create(admin, %{slug: slug, value: @value}, [agent.id])
    %{admin: admin, agent: agent, slug: slug, cred: cred}
  end

  defp token_of(url), do: url |> String.split("/vault/fetch/") |> List.last()

  test "a granted agent's issue + redeem returns the value and logs use with the fingerprint",
       ctx do
    assert {:ok, %{url: url, expires_in: 120, fingerprint: fp} = ticket} =
             Fetch.issue(ctx.agent.id, ctx.slug)

    refute inspect(ticket) =~ @value
    assert fp == Vault.fingerprint(@value)
    assert String.starts_with?(url, PlatformWeb.Endpoint.url() <> "/vault/fetch/")

    assert {:ok, @value} = Fetch.redeem(token_of(url), "203.0.113.7")

    logs = logs_for_slug(ctx.slug)
    issued = Enum.find(logs, &(&1.action == "read"))
    used = Enum.find(logs, &(&1.action == "use"))

    assert issued.metadata["via"] == "ticket_issued"
    assert issued.accessor_id == ctx.agent.id
    assert used.metadata["via"] == "fetch_ticket"
    assert used.metadata["ticket_id"] == issued.metadata["ticket_id"]
    assert used.metadata["fingerprint"] == fp
    assert used.metadata["remote_ip"] == "203.0.113.7"
    refute inspect(logs) =~ @value
  end

  test "the raw token is never stored", ctx do
    {:ok, %{url: url}} = Fetch.issue(ctx.agent.id, ctx.slug)
    token = token_of(url)

    [ticket] = Repo.all(from(t in FetchTicket, where: t.credential_id == ^ctx.cred.id))
    assert ticket.token_hash == :crypto.hash(:sha256, token)
    refute ticket.token_hash == token
  end

  test "an ungranted agent's issue is refused and writes a denied row", ctx do
    other = agent!()

    assert {:error, :access_denied} = Fetch.issue(other.id, ctx.slug)

    assert Enum.any?(
             logs_for_slug(ctx.slug),
             &(&1.action == "denied" and &1.accessor_id == other.id)
           )

    refute Repo.exists?(from(t in FetchTicket, where: t.agent_id == ^other.id))
  end

  test "an unknown name is not_found and mints nothing", ctx do
    assert {:error, :not_found} = Fetch.issue(ctx.agent.id, unique_slug("missing"))
  end

  test "a second redeem returns :gone", ctx do
    {:ok, %{url: url}} = Fetch.issue(ctx.agent.id, ctx.slug)

    assert {:ok, @value} = Fetch.redeem(token_of(url), nil)
    assert {:error, :gone} = Fetch.redeem(token_of(url), nil)
  end

  test "an expired ticket returns :gone", ctx do
    {:ok, %{url: url}} = Fetch.issue(ctx.agent.id, ctx.slug)

    from(t in FetchTicket, where: t.credential_id == ^ctx.cred.id)
    |> Repo.update_all(set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)])

    assert {:error, :gone} = Fetch.redeem(token_of(url), nil)
    refute Enum.any?(logs_for_slug(ctx.slug), &(&1.action == "use"))
  end

  test "an unknown token returns :gone" do
    assert {:error, :gone} = Fetch.redeem("not-a-real-token", nil)
  end

  test "ungranting after issue makes the redeem refused, with a denied row", ctx do
    {:ok, %{url: url}} = Fetch.issue(ctx.agent.id, ctx.slug)

    :ok = Shared.set_grants(ctx.admin, ctx.cred.id, [])

    assert {:error, :access_denied} = Fetch.redeem(token_of(url), nil)

    assert Enum.any?(
             logs_for_slug(ctx.slug),
             &(&1.action == "denied" and &1.accessor_id == ctx.agent.id)
           )
  end

  test "rotating after issue makes the redeem return the NEW value", ctx do
    {:ok, %{url: url}} = Fetch.issue(ctx.agent.id, ctx.slug)

    {:ok, _} = Shared.rotate(ctx.admin, ctx.slug, "fake-rotated-fetchable")

    assert {:ok, "fake-rotated-fetchable"} = Fetch.redeem(token_of(url), nil)
  end

  test "a platform-scoped secret with the same name as a shared one is never served", ctx do
    slug = unique_slug("platform-only")
    {:ok, _} = Vault.put(slug, :api_key, "fake-platform-value")

    assert {:error, :not_found} = Fetch.issue(ctx.agent.id, slug)
    refute Repo.exists?(from(t in FetchTicket, where: t.agent_id == ^ctx.agent.id))

    # Same name at both scopes: only the shared row can ever be named. The
    # partial unique index and Shared.create keep this from arising through
    # the admin path, so it is written directly.
    {:ok, _} = Vault.put(ctx.slug, :api_key, "fake-platform-twin")
    {:ok, %{url: url}} = Fetch.issue(ctx.agent.id, ctx.slug)
    assert {:ok, @value} = Fetch.redeem(token_of(url), nil)
  end
end
