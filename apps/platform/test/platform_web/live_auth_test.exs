defmodule PlatformWeb.LiveAuthTest do
  @moduledoc """
  Direct-call tests for the `on_mount/4` hooks in `PlatformWeb.LiveAuth`.

  These exercise the hook in isolation by hand-building a
  `%Phoenix.LiveView.Socket{}` — full LV mount integration is covered
  by `live_auth_integration_test.exs`.
  """

  use Platform.DataCase, async: true

  alias Phoenix.LiveView.Socket
  alias Platform.Accounts.User
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership
  alias PlatformWeb.LiveAuth

  defp create_user!(overrides \\ %{}) do
    n = System.unique_integer([:positive])

    attrs =
      Map.merge(
        %{
          email: "live-auth-test-#{n}@example.com",
          name: "LiveAuth Test #{n}",
          oidc_sub: "oidc-live-auth-#{n}"
        },
        overrides
      )

    %User{}
    |> User.changeset(attrs)
    |> Repo.insert!()
  end

  defp create_membership!(user, org, role) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org.id, role: role})
    |> Repo.insert!()
  end

  defp socket_with(user) do
    socket = %Socket{endpoint: PlatformWeb.Endpoint, assigns: %{__changed__: %{}, flash: %{}}}
    Phoenix.Component.assign(socket, :current_user_record, user)
  end

  describe "on_mount(:default, ...)" do
    test "assigns :current_user_org_membership + :root_admin? for an admin" do
      user = create_user!()
      acme = Tenancy.get_org_by_slug!("acme")
      create_membership!(user, acme, "admin")
      loaded = Platform.Accounts.get_user(user.id)

      {:cont, socket} = LiveAuth.on_mount(:default, %{}, %{}, socket_with(loaded))

      assert socket.assigns.root_admin? == true
      assert %{role: :admin, org: %{slug: "acme"}} = socket.assigns.current_user_org_membership
    end

    test "assigns :current_user_org_membership + root_admin?=false for a member" do
      user = create_user!()
      acme = Tenancy.get_org_by_slug!("acme")
      create_membership!(user, acme, "member")
      loaded = Platform.Accounts.get_user(user.id)

      {:cont, socket} = LiveAuth.on_mount(:default, %{}, %{}, socket_with(loaded))

      assert socket.assigns.root_admin? == false
      assert %{role: :member, org: %{slug: "acme"}} = socket.assigns.current_user_org_membership
    end

    test "assigns nil membership + root_admin?=false for an anonymous mount" do
      socket = %Socket{endpoint: PlatformWeb.Endpoint, assigns: %{__changed__: %{}, flash: %{}}}
      socket = Phoenix.Component.assign(socket, :current_user_record, nil)

      {:cont, socket} = LiveAuth.on_mount(:default, %{}, %{}, socket)

      assert socket.assigns.root_admin? == false
      assert is_nil(socket.assigns.current_user_org_membership)
    end

    test "tolerates a display-name string in :current_user (legacy shape)" do
      socket = %Socket{endpoint: PlatformWeb.Endpoint, assigns: %{__changed__: %{}, flash: %{}}}
      socket = Phoenix.Component.assign(socket, :current_user, "Marlowe Quill")

      {:cont, socket} = LiveAuth.on_mount(:default, %{}, %{}, socket)

      assert socket.assigns.root_admin? == false
      assert is_nil(socket.assigns.current_user_org_membership)
    end
  end

  describe "on_mount(:ensure_admin, ...)" do
    test "continues when :root_admin? is true" do
      socket = %Socket{endpoint: PlatformWeb.Endpoint, assigns: %{__changed__: %{}, flash: %{}}}
      socket = Phoenix.Component.assign(socket, :root_admin?, true)

      assert {:cont, _socket} = LiveAuth.on_mount(:ensure_admin, %{}, %{}, socket)
    end

    test "halts and pushes a redirect when :root_admin? is false" do
      socket = %Socket{endpoint: PlatformWeb.Endpoint, assigns: %{__changed__: %{}, flash: %{}}}
      socket = Phoenix.Component.assign(socket, :root_admin?, false)

      assert {:halt, socket} = LiveAuth.on_mount(:ensure_admin, %{}, %{}, socket)

      # `push_navigate/2` enqueues a redirect operation on the socket's
      # private state — assert the flash was set as a stable proxy for
      # "the gate fired" rather than reaching into LV internals.
      assert Phoenix.Flash.get(socket.assigns.flash, :error) =~ "don't have access"
    end

    test "halts when :root_admin? assign is missing entirely" do
      socket = %Socket{endpoint: PlatformWeb.Endpoint, assigns: %{__changed__: %{}, flash: %{}}}

      assert {:halt, _socket} = LiveAuth.on_mount(:ensure_admin, %{}, %{}, socket)
    end
  end
end
