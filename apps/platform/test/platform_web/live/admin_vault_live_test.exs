defmodule PlatformWeb.AdminVaultLiveTest do
  @moduledoc """
  `/admin/vault` (task 01a131c5 stage 2).

  The load-bearing property is write-only: after a value is submitted it
  reaches neither a rendered page nor any term in the LiveView process
  state. `deep_holds?/2` walks the whole `:sys.get_state/1` term (maps,
  structs, lists, tuples), and a positive control shows the walker DOES
  reach assigns, so its silence means something.

  Authorization is checked where it is enforced: an admin session whose
  role is revoked after mount sends save/rotate/set_grants/revoke events,
  and `Platform.Vault.Shared` refuses every one.
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Platform.VaultFixtures

  alias Platform.Repo
  alias Platform.Tenancy.OrgMembership
  alias Platform.Vault
  alias Platform.Vault.Credential
  alias Platform.Vault.Fetch
  alias Platform.Vault.Shared

  @value "sk-test-PLAINTEXT-123"
  @rotated "sk-test-ROTATED-456"

  setup %{conn: conn} do
    admin = admin!()
    agent_a = agent!()
    agent_b = agent!()

    %{
      conn: Plug.Test.init_test_session(conn, %{"current_user_id" => admin.id}),
      admin: admin,
      agent_a: agent_a,
      agent_b: agent_b
    }
  end

  # Every term the LiveView process holds, walked. Structs are walked as
  # maps so a derived/custom Inspect cannot hide a field.
  defp deep_holds?(term, needle) when is_binary(term), do: String.contains?(term, needle)

  defp deep_holds?(%_{} = struct, needle),
    do: struct |> Map.from_struct() |> deep_holds?(needle)

  defp deep_holds?(term, needle) when is_map(term),
    do: Enum.any?(term, fn {k, v} -> deep_holds?(k, needle) or deep_holds?(v, needle) end)

  defp deep_holds?([head | tail], needle),
    do: deep_holds?(head, needle) or deep_holds?(tail, needle)

  defp deep_holds?(term, needle) when is_tuple(term),
    do: term |> Tuple.to_list() |> deep_holds?(needle)

  defp deep_holds?(_term, _needle), do: false

  defp view_state(view), do: :sys.get_state(view.pid)

  defp refute_leak(view, value \\ @value) do
    refute render(view) =~ value
    refute deep_holds?(view_state(view), value)
  end

  defp pick(view, agent) do
    view |> element("#vault-add-search") |> render_change(%{"q" => agent.name})

    view
    |> element(~s([data-role="vault-agent-option"][data-agent-id="#{agent.id}"]))
    |> render_click()
  end

  defp add_secret(view, slug, value, agents) do
    view |> element(~s([data-role="vault-add-open"])) |> render_click()
    Enum.each(agents, &pick(view, &1))

    view
    |> form("#vault-add-form", secret: %{slug: slug, value: value, note: "for the test"})
    |> render_submit()
  end

  defp demote!(user) do
    from(m in OrgMembership, where: m.user_id == ^user.id)
    |> Repo.update_all(set: [role: "member"])
  end

  describe "authorization" do
    test "a non-admin mount is redirected", %{conn: conn} do
      user = non_admin!()

      assert {:error, {_, %{to: "/access-denied?module=admin"}}} =
               conn
               |> Plug.Test.init_test_session(%{"current_user_id" => user.id})
               |> live(~p"/admin/vault")
    end

    test "the admin index links to the vault", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin")
      assert html =~ ~s(data-role="admin-vault-link")
    end

    test "forged save, rotate, set_grants and revoke from a demoted admin are refused by Shared",
         ctx do
      slug = unique_slug()
      {:ok, cred} = Shared.create(ctx.admin, %{slug: slug, value: @value}, [ctx.agent_a.id])
      fp = Repo.get!(Credential, cred.id).metadata["fingerprint"]

      {:ok, index, _} = live(ctx.conn, ~p"/admin/vault")
      {:ok, show, _} = live(ctx.conn, ~p"/admin/vault/#{slug}")
      demote!(ctx.admin)

      new_slug = unique_slug()
      add_secret(index, new_slug, @rotated, [ctx.agent_b])
      assert render(index) =~ "Only an install admin can change the vault."
      refute Repo.exists?(from(c in Credential, where: c.slug == ^new_slug))

      render_click(show, "start_rotate", %{})
      show |> form("#vault-rotate-form", secret: %{value: @rotated}) |> render_submit()
      assert Repo.get!(Credential, cred.id).metadata["fingerprint"] == fp

      render_click(show, "grant", %{"id" => ctx.agent_b.id})
      render_click(show, "ungrant", %{"id" => ctx.agent_a.id})
      assert Enum.map(grants_for(cred.id), & &1.grantee_id) == [ctx.agent_a.id]

      render_click(show, "revoke", %{})
      assert Repo.get(Credential, cred.id)

      refute_leak(index, @rotated)
      refute_leak(show, @rotated)
    end
  end

  describe "write-only value" do
    test "save with two agents grants both, then the value is in no render and no state", ctx do
      slug = unique_slug()
      {:ok, view, _} = live(ctx.conn, ~p"/admin/vault")

      # Positive control: the walker reaches assigns.
      assert deep_holds?(view_state(view), ctx.agent_a.name)

      add_secret(view, slug, @value, [ctx.agent_a, ctx.agent_b])
      assert_patch(view, ~p"/admin/vault/#{slug}")

      cred = Repo.one!(from(c in Credential, where: c.slug == ^slug))
      assert cred.scope_type == "shared"

      assert Enum.sort(Enum.map(grants_for(cred.id), & &1.grantee_id)) ==
               Enum.sort([ctx.agent_a.id, ctx.agent_b.id])

      html = render(view)
      assert html =~ ~s(data-role="vault-sealed-value")
      assert html =~ Vault.fingerprint(@value)
      assert html =~ "This value will not be shown again."
      refute html =~ ~s(data-role="vault-value-input")
      refute html =~ ~s(data-role="vault-value-toggle")
      refute_leak(view)
    end

    test "a fresh :show mount and a rotate never render either value", ctx do
      slug = unique_slug()
      {:ok, _} = Shared.create(ctx.admin, %{slug: slug, value: @value}, [ctx.agent_a.id])

      {:ok, view, html} = live(ctx.conn, ~p"/admin/vault/#{slug}")
      refute html =~ @value
      refute_leak(view)

      view |> element(~s([data-role="vault-rotate"])) |> render_click()
      assert render(view) =~ ~s(data-role="vault-value-input")
      view |> form("#vault-rotate-form", secret: %{value: @rotated}) |> render_submit()

      html = render(view)
      assert html =~ Vault.fingerprint(@rotated)
      refute html =~ ~s(data-role="vault-value-input")
      refute_leak(view, @value)
      refute_leak(view, @rotated)
    end

    test "a duplicate-name submit says so, keeps the name, and drops the value", ctx do
      slug = unique_slug()
      {:ok, _} = Shared.create(ctx.admin, %{slug: slug, value: "fake-first"}, [])

      {:ok, view, _} = live(ctx.conn, ~p"/admin/vault")
      add_secret(view, slug, @value, [ctx.agent_a])

      html = render(view)
      assert html =~ "A secret with this name already exists."
      assert html =~ ~s(value="#{slug}")
      assert Repo.aggregate(from(c in Credential, where: c.slug == ^slug), :count) == 1
      refute_leak(view)
    end

    test "an agent-search change carrying a value assigns nothing from it", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/admin/vault")
      view |> element(~s([data-role="vault-add-open"])) |> render_click()

      render_change(view, "agent_search", %{"q" => "", "secret" => %{"value" => @value}})
      refute_leak(view)
    end
  end

  describe "grants and the access log" do
    test "removing one chip removes only that grant and logs it", ctx do
      slug = unique_slug()

      {:ok, cred} =
        Shared.create(ctx.admin, %{slug: slug, value: @value}, [ctx.agent_a.id, ctx.agent_b.id])

      {:ok, view, _} = live(ctx.conn, ~p"/admin/vault/#{slug}")

      view
      |> element(~s([data-role="vault-grant-chip"][data-agent-id="#{ctx.agent_a.id}"] button))
      |> render_click()

      assert Enum.map(grants_for(cred.id), & &1.grantee_id) == [ctx.agent_b.id]

      html = render(view)
      refute html =~ ~s(data-agent-id="#{ctx.agent_a.id}")
      assert html =~ "ungranted #{ctx.agent_a.name}"

      assert Enum.any?(logs_for_slug(slug), fn l ->
               l.action == "update" and l.metadata["grant"] == "removed" and
                 l.metadata["agent_id"] == ctx.agent_a.id
             end)
    end

    # Task 01a18f0c stage 1: a named system reader is granted and revoked
    # here like an agent, and both show in the access log.
    test "a system reader is granted and removed from System readers", ctx do
      slug = unique_slug()
      {:ok, cred} = Shared.create(ctx.admin, %{slug: slug, value: @value}, [])

      {:ok, view, _} = live(ctx.conn, ~p"/admin/vault/#{slug}")

      view
      |> element(~s([data-role="vault-system-grant-open"][data-name="test-reader"]))
      |> render_click()

      assert [%{grantee_type: "system"}] = grants_for(cred.id)
      assert {:ok, @value} = Vault.get(slug, accessor: {:system, "test-reader"})

      html = render(view)
      assert html =~ ~s(data-role="vault-system-grant-chip")
      assert html =~ "granted system reader test-reader"
      refute html =~ @value

      view
      |> element(
        ~s([data-role="vault-system-grant-chip"][data-name="test-reader"] button)
      )
      |> render_click()

      assert grants_for(cred.id) == []
      assert render(view) =~ "ungranted system reader test-reader"

      assert {:error, :access_denied} =
               Vault.get(slug, accessor: {:system, "test-reader"})

      demote!(ctx.admin)
      render_click(view, "grant_system", %{"name" => "test-reader"})
      assert grants_for(cred.id) == []
    end

    test "+ Grant agent adds a grant from the picker", ctx do
      slug = unique_slug()
      {:ok, cred} = Shared.create(ctx.admin, %{slug: slug, value: @value}, [])

      {:ok, view, _} = live(ctx.conn, ~p"/admin/vault/#{slug}")
      assert render(view) =~ ~s(data-role="vault-chip-not-granted")

      view |> element(~s([data-role="vault-grant-open"])) |> render_click()
      view |> element("#vault-grant-search") |> render_change(%{"q" => ctx.agent_b.name})

      view
      |> element(~s([data-role="vault-agent-option"][data-agent-id="#{ctx.agent_b.id}"]))
      |> render_click()

      assert Enum.map(grants_for(cred.id), & &1.grantee_id) == [ctx.agent_b.id]
    end

    test "a denied fetch renders the refused chip and a refused log row", ctx do
      slug = unique_slug()
      {:ok, _} = Shared.create(ctx.admin, %{slug: slug, value: @value}, [ctx.agent_a.id])
      assert {:error, :access_denied} = Fetch.issue(ctx.agent_b.id, slug)

      {:ok, _view, html} = live(ctx.conn, ~p"/admin/vault")
      assert html =~ ~s(data-role="vault-chip-refused")
      assert html =~ "1 refused fetch (7d)"

      {:ok, _view, html} = live(ctx.conn, ~p"/admin/vault/#{slug}")
      assert html =~ ~s(data-role="vault-access-log")
      assert html =~ "refused: not granted"
    end

    test "revoke asks first, names who loses access, then destroys the secret", ctx do
      slug = unique_slug()

      {:ok, cred} =
        Shared.create(ctx.admin, %{slug: slug, value: @value}, [ctx.agent_a.id, ctx.agent_b.id])

      {:ok, view, _} = live(ctx.conn, ~p"/admin/vault/#{slug}")
      view |> element(~s([data-role="vault-revoke"])) |> render_click()

      html = render(view)
      assert html =~ "#{ctx.agent_a.name} and #{ctx.agent_b.name} will lose access to #{slug}."
      assert Repo.get(Credential, cred.id)

      view |> element(~s([data-role="vault-revoke-confirm-button"])) |> render_click()
      assert_patch(view, ~p"/admin/vault")
      refute Repo.get(Credential, cred.id)
    end
  end
end
