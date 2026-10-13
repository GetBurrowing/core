defmodule Platform.Vault.ToolHandlersTest do
  @moduledoc """
  Task 01a131c5 stage 1 — the `vault_fetch` / `vault_list` MCP handlers.
  A tool result is model-visible, so the value must never appear in one.
  """
  use Platform.DataCase, async: false

  import Platform.VaultFixtures

  alias Platform.Federation.ToolSurface
  alias Platform.Vault
  alias Platform.Vault.Fetch
  alias Platform.Vault.Shared
  alias Platform.Vault.ToolHandlers

  @secret "fake-tool-handler-secret"

  setup do
    admin = admin!()
    agent = agent!()
    slug = unique_slug()
    {:ok, _} = Shared.create(admin, %{slug: slug, value: @secret}, [agent.id])
    %{admin: admin, agent: agent, slug: slug}
  end

  describe "fetch/2" do
    test "returns url, expires_in, fingerprint and command, never the value", ctx do
      result = ToolHandlers.fetch(%{"name" => ctx.slug}, %{agent_id: ctx.agent.id})

      refute inspect(result) =~ @secret
      assert {:ok, %{url: url, expires_in: 120, fingerprint: fp, command: command}} = result
      assert fp == Vault.fingerprint(@secret)

      assert command ==
               "umask 077 && mkdir -p ~/.suite-secrets && curl -fsS -o ~/.suite-secrets/#{ctx.slug} '#{url}'"

      token = url |> String.split("/vault/fetch/") |> List.last()
      assert {:ok, @secret} = Fetch.redeem(token, nil)
    end

    test "routes through ToolSurface.execute/3", ctx do
      result =
        ToolSurface.execute("vault_fetch", %{"name" => ctx.slug}, %{agent_id: ctx.agent.id})

      refute inspect(result) =~ @secret
      assert {:ok, %{url: _}} = result
    end

    test "an ungranted agent and an unknown name answer identically", ctx do
      other = agent!()

      assert {:error, %{error: "not granted", recoverable: false}} =
               ToolHandlers.fetch(%{"name" => ctx.slug}, %{agent_id: other.id})

      assert {:error, %{error: "not granted", recoverable: false}} =
               ToolHandlers.fetch(%{"name" => unique_slug("nope")}, %{agent_id: ctx.agent.id})

      assert {:error, %{error: "not granted"}} =
               ToolHandlers.fetch(%{"name" => ctx.slug}, %{agent_id: nil})
    end

    test "a name that is not a slug is refused before any lookup", ctx do
      assert {:error, %{code: "invalid_name"}} =
               ToolHandlers.fetch(%{"name" => "x'; rm -rf ~"}, %{agent_id: ctx.agent.id})

      assert {:error, %{code: "invalid_name"}} =
               ToolHandlers.fetch(%{}, %{agent_id: ctx.agent.id})
    end
  end

  describe "list/2" do
    test "shows only the names granted to the caller, never a value", ctx do
      other_slug = unique_slug()
      {:ok, _} = Shared.create(ctx.admin, %{slug: other_slug, value: "fake-other-secret"}, [])

      assert {:ok, %{secrets: secrets}} = ToolHandlers.list(%{}, %{agent_id: ctx.agent.id})
      assert [%{name: name, fingerprint: fp, rotated_at: nil}] = secrets
      assert name == ctx.slug
      assert fp == Vault.fingerprint(@secret)
      refute inspect(secrets) =~ @secret

      assert {:ok, %{secrets: [], total: 0, has_more: false}} =
               ToolHandlers.list(%{}, %{agent_id: agent!().id})

      assert {:ok, %{secrets: [], total: 0, has_more: false}} =
               ToolHandlers.list(%{}, %{agent_id: nil})
    end
  end
end
