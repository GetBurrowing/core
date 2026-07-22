defmodule PlatformWeb.ChatLiveExternalRailTest do
  @moduledoc """
  rbac-external-users M5 stage 2 — the chrome-less external space rail.

  On the `chat.` host M4's `:external_chat` live_session merges
  `chat_mode: "external"` into the connect session; ChatLive then renders the
  external branch: a single flat allowlisted-space list (scoped by M7's
  `ExternalScope`) with the Fabrikam branding + identity chip + logout, and NONE of
  the internal discovery chrome (sub-org section headers, admin entry,
  new-channel, scope-pills, archived / pinned-task sections).

  `async: false` — mirrors `chat_live_external_host_mount_test.exs` /
  `meeting_live_guest_mount_test.exs`; keeps the host-swapped conn cases off the
  shared async pool.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.Org

  defp with_chat_host(conn, host \\ "chat.localhost") do
    %{conn | host: host}
  end

  defp create_user!(name) do
    n = System.unique_integer([:positive])

    %User{}
    |> User.changeset(%{
      email: "rail-#{n}@example.com",
      name: name,
      oidc_sub: "oidc-rail-#{n}"
    })
    |> Repo.insert!()
  end

  defp tenant_org! do
    n = System.unique_integer([:positive])

    %Org{}
    |> Org.changeset(%{
      name: "Tenant #{n}",
      slug: "tenant_rail_#{n}",
      parent_org_id: Tenancy.get_org_by_slug!("fabrikam").id
    })
    |> Repo.insert!()
  end

  defp external_user!(org) do
    user = create_user!("Xena External")
    {:ok, _} = Tenancy.mark_membership_external(%{user_id: user.id, org_id: org.id})
    Tenancy.allow_dm(user, org)
    user
  end

  defp channel!(name, opts \\ []) do
    n = System.unique_integer([:positive])

    attrs =
      %{name: name, slug: "rail-ch-#{n}", kind: "channel"}
      |> Map.merge(Map.new(opts))

    {:ok, ch} = Chat.create_space(attrs)
    ch
  end

  defp join!(channel, user) do
    {:ok, _} =
      Chat.add_participant(channel.id, %{
        participant_type: "user",
        participant_id: user.id,
        joined_at: DateTime.utc_now()
      })

    channel
  end

  defp authed(conn, user), do: init_test_session(conn, current_user_id: user.id)

  describe "external path (chat. host)" do
    setup %{conn: conn} do
      org_a = tenant_org!()
      ext = external_user!(org_a)

      allowed = channel!("Allowed Channel", org_id: org_a.id) |> join!(ext)
      off_limits = channel!("Secret Ops Room")

      %{conn: conn, ext: ext, allowed: allowed, off_limits: off_limits}
    end

    test "rail lists ONLY the allowlisted channel and none of the discovery chrome",
         %{conn: conn, ext: ext, allowed: allowed, off_limits: off_limits} do
      {:ok, _view, html} =
        conn
        |> with_chat_host()
        |> authed(ext)
        |> live("/chat/#{allowed.slug}")

      # The external rail rendered, listing the allowlisted channel only.
      assert html =~ ~s(data-role="external-rail")
      assert html =~ allowed.name
      refute html =~ off_limits.name

      # Branding + identity chip + logout are KEPT (M4's :external layout is
      # chrome-less, so ChatLive renders them).
      assert html =~ "Fabrikam"
      assert html =~ ~s(data-role="external-identity")
      assert html =~ ext.name
      assert html =~ ~p"/auth/logout"

      # NONE of the internal discovery chrome leaks.
      refute html =~ ~s(id="chat-sidebar")
      refute html =~ "channel-section-header"
      refute html =~ "Edit my layout"
      refute html =~ "Edit company default"
      refute html =~ "New channel"
      refute html =~ "chat-header-scope-pill"
    end

    test "empty allowlist renders the calm empty state, no crash and no leak", %{conn: conn} do
      org = tenant_org!()
      zero = external_user!(org)

      {:ok, _view, html} =
        conn
        |> with_chat_host()
        |> authed(zero)
        |> live("/chat")

      assert html =~ ~s(data-role="external-rail")
      assert html =~ ~s(data-role="external-empty")
      assert html =~ "Nothing here yet"
      # Never the internal brand-new-user "browse channels" discovery hint.
      refute html =~ "id=\"chat-sidebar\""
      refute html =~ "channel-section-header"
    end
  end

  describe "internal control (default host)" do
    test "the internal rail is fully unchanged — no external branch leaks", %{conn: conn} do
      internal = create_user!("Ivan Internal")
      channel = channel!("General Chat")
      join!(channel, internal)

      {:ok, _view, html} =
        conn
        |> authed(internal)
        |> live("/chat/#{channel.slug}")

      # Full internal rail: the resizable sidebar aside + new-channel affordance.
      assert html =~ ~s(id="chat-sidebar")
      assert html =~ "New channel"
      # The external branch is fully dormant on the default host.
      refute html =~ ~s(data-role="external-rail")
      refute html =~ ~s(data-role="external-empty")
    end
  end
end
