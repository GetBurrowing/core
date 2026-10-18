defmodule PlatformWeb.ExternalLeakRegressionTest do
  @moduledoc """
  Consolidated regression net for the cross-tenant disclosure (task 019f9257).

  Ties the three fixes together against the EXACT reported repro (Alex Testerson,
  an SXI external user granted ONLY the Orion channel via the real grant path)
  so a future refactor of any single seam — identity scope derivation (stage 1),
  the plug host fence (stage 2), or the admission/recovery redirects (stage 3) —
  cannot silently re-open the leak. Fast server-side tests, no browser.

  Fixtures use the AUTHORITATIVE grant path (`ExternalGrants.apply_grant/2`) so
  the external user holds a `chat_participants` row for Orion and NOTHING
  else; an Acme-internal `General` channel exists that must never appear; an
  ordinary internal user is the control.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.ExternalAdmission
  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.ExternalGrants
  alias Platform.Tenancy.Org

  defp create_user!(name) do
    n = System.unique_integer([:positive])

    %User{}
    |> User.changeset(%{
      email: "leak-#{n}@example.com",
      name: name,
      oidc_sub: "oidc-leak-#{n}"
    })
    |> Repo.insert!()
  end

  defp sxi_org! do
    n = System.unique_integer([:positive])

    %Org{}
    |> Org.changeset(%{
      name: "SXI #{n}",
      slug: "sxi_leak_#{n}",
      parent_org_id: Tenancy.get_org_by_slug!("acme").id
    })
    |> Repo.insert!()
  end

  defp channel!(name, opts \\ []) do
    n = System.unique_integer([:positive, :monotonic])
    attrs = Map.merge(%{name: name, slug: "leak-ch-#{n}", kind: "channel"}, Map.new(opts))
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

  # The real grant path: create + apply a pending grant so the external user is
  # materialized (external membership + a chat_participants row for ONLY the
  # granted spaces), exactly as the admin recovery flow does in production.
  defp grant_only!(user, org, space) do
    {:ok, grant} =
      ExternalGrants.create_grant(%{
        email: user.email,
        oidc_sub: user.oidc_sub,
        target_org_id: org.id,
        space_grants: [%{"space_id" => space.id, "role" => "member"}],
        dm_allowlist_org_ids: [org.id]
      })

    {:ok, _applied} = ExternalGrants.apply_grant(grant, user)
    user
  end

  defp put_chat_host(host) do
    prev = Application.get_env(:platform, :chat_host)
    Application.put_env(:platform, :chat_host, host)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:platform, :chat_host, prev),
        else: Application.delete_env(:platform, :chat_host)
    end)
  end

  setup %{conn: conn} do
    sxi = sxi_org!()
    testerson = create_user!("Alex Testerson")
    orion = channel!("Orion", org_id: sxi.id)
    # Acme-internal channel — Testerson has NO participant row for it.
    general = channel!("General")

    grant_only!(testerson, sxi, orion)

    %{conn: conn, sxi: sxi, testerson: testerson, orion: orion, general: general}
  end

  describe "(a) stage 1 — identity scope: external user on the SUITE host, no chat_mode" do
    test "sees ONLY Orion, never General/all-channels", ctx do
      %{conn: conn, testerson: testerson, orion: orion, general: general} = ctx

      # Default (suite) host, no chat_mode session key, CHAT_HOST unset so the
      # stage-2 fence does not intercept — this exercises the stage-1 scope
      # guarantee in isolation (the seam the leak lived on).
      {:ok, _view, html} =
        conn
        |> authed(testerson)
        |> live("/chat/#{orion.slug}")

      assert html =~ orion.name
      refute html =~ general.name
      # Identity-derived external branch, discovery chrome off.
      assert html =~ ~s(data-role="external-rail")
      refute html =~ "New channel"
    end
  end

  describe "(b) internal control — completely unaffected" do
    test "the internal user's rail still shows General + internal chrome", ctx do
      %{conn: conn, general: general} = ctx
      internal = create_user!("Ingrid Internal")
      join!(general, internal)

      {:ok, _view, html} =
        conn
        |> authed(internal)
        |> live("/chat/#{general.slug}")

      assert html =~ general.name
      assert html =~ ~s(id="chat-sidebar")
      assert html =~ "New channel"
      refute html =~ ~s(data-role="external-rail")
    end
  end

  describe "(c) stage 2 — host fence: external HTTP request on the suite host" do
    test "is redirected (302) to the absolute chat host", ctx do
      %{conn: conn, testerson: testerson} = ctx
      put_chat_host("chat.localhost")

      conn =
        conn
        |> Map.put(:host, "suite.localhost")
        |> authed(testerson)
        |> get(~p"/chat")

      assert redirected_to(conn, 302) == "https://chat.localhost/chat"
    end

    test "no loop: the same external user already on the chat host is not redirected away", ctx do
      %{conn: conn, testerson: testerson, orion: orion} = ctx
      put_chat_host("chat.localhost")

      # On the chat host the external surface mounts and remains scoped.
      {:ok, _view, html} =
        conn
        |> Map.put(:host, "chat.localhost")
        |> authed(testerson)
        |> live("/chat/#{orion.slug}")

      assert html =~ orion.name
      refute html =~ "General"
    end
  end

  describe "(d) stage 3 — recovery: holding tab transitions to the scoped chat host" do
    test "the :recovered broadcast redirects /welcome to the absolute chat host", ctx do
      %{conn: conn} = ctx
      put_chat_host("chat.localhost")

      holding = create_user!("Holding Testerson")

      conn =
        Plug.Test.init_test_session(conn, %{
          "current_user_id" => holding.id,
          "external_admission" => %{state: :holding, reason: :awaiting_grant, user_id: holding.id}
        })

      {:ok, view, _html} = live(conn, "/welcome")

      result = %ExternalAdmission.Result{
        user: holding,
        state: :full,
        reason: nil,
        external?: true
      }

      send(view.pid, {:external_admission, :recovered, holding.id, result})

      assert_redirect(view, "https://chat.localhost/chat")
    end
  end
end
