defmodule PlatformWeb.TerminalLiveTest do
  @moduledoc """
  The remote terminal page and its entry (task 01a17b17 stage 3). Elements are
  found with `has_element?/2` and `LazyHTML.query/2`, never `LazyHTML.filter/2`.
  The hook and xterm are exercised by the assets tests; here a hook's events are
  driven with `render_hook/3`.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.TenancyFixtures

  alias Platform.Agents.Agent
  alias Platform.Audit
  alias Platform.ExternalUserFixtures, as: World
  alias Platform.Federation
  alias Platform.Federation.RemoteAccess
  alias Platform.Repo
  alias Platform.Tenancy.Org

  @banned ~r/\b(sandbox(?:ed|es)?|workspaces?|safe(?:ly|ty)?|isolat(?:ed|ion|e)|scoped|log[- ]?in|sign[- ]?in)\b/i

  defp member! do
    user = World.create_user!()
    World.plain_member!(user, Repo.get!(Org, acme_org_id()))
    user
  end

  defp as_user(conn, user), do: Plug.Test.init_test_session(conn, current_user_id: user.id)

  defp federated_agent!(owner) do
    n = System.unique_integer([:positive])
    {:ok, runtime} = Federation.register_runtime(owner.id, %{runtime_id: "term-ui-#{n}"})

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "term-ui-#{n}",
        name: "Term Agent #{n}",
        runtime_type: "external",
        runtime_id: runtime.id
      })
      |> Repo.insert()

    {agent, runtime}
  end

  setup do
    owner = member!()
    other = member!()
    {agent, runtime} = federated_agent!(owner)
    %{owner: owner, other: other, agent: agent, runtime: runtime}
  end

  describe "the Open terminal entry" do
    test "the owner sees it on the agent page", %{
      conn: conn,
      owner: owner,
      agent: agent,
      runtime: runtime
    } do
      {:ok, view, _} = live(as_user(conn, owner), ~p"/control/#{agent.slug}")
      assert has_element?(view, "#open-terminal", "Open terminal")
      assert has_element?(view, ~s(#open-terminal[href="/terminal/#{runtime.runtime_id}"]))
    end

    test "a non-owner never gets it: absent, not disabled", %{
      conn: conn,
      other: other,
      agent: agent
    } do
      {:ok, view, html} = live(as_user(conn, other), ~p"/control/#{agent.slug}")
      refute has_element?(view, "#open-terminal")
      refute has_element?(view, "#terminal-entry")
      refute html =~ "Open terminal"
    end

    test "the entry is gated on RemoteAccess, not on the owner column alone", %{
      owner: owner,
      runtime: runtime
    } do
      assert PlatformWeb.TerminalPanel.offer?(runtime, owner.id)
      refute PlatformWeb.TerminalPanel.offer?(runtime, Ecto.UUID.generate())
      refute PlatformWeb.TerminalPanel.offer?(nil, owner.id)

      assert RemoteAccess.kind_for(runtime, owner.id) in RemoteAccess.allowed_kinds()
      # A kind outside the allowlist cannot be offered, owner column or not.
      refute RemoteAccess.permitted?(:other_federation, true)
    end

    test "past sessions show to the owner in the activity list", %{
      conn: conn,
      owner: owner,
      agent: agent,
      runtime: runtime
    } do
      {:ok, _} =
        Audit.record(%{
          event_type: "terminal.session.closed",
          actor_type: "user",
          actor_id: owner.id,
          resource_type: "terminal_session",
          resource_id: runtime.runtime_id,
          action: "closed",
          metadata: %{
            "mode" => "ro",
            "opened_at" => "2026-10-27T14:02:00Z",
            "closed_at" => "2026-10-27T14:20:00Z"
          }
        })

      {:ok, view, _} = live(as_user(conn, owner), ~p"/control/#{agent.slug}")
      assert has_element?(view, "#terminal-activity li", "You opened the terminal, view only,")
      assert has_element?(view, "#terminal-activity time", "14:02")
      assert has_element?(view, "#terminal-activity time", "14:20")
    end
  end

  describe "the terminal page" do
    test "starts on View only, with the honest copy and no key row", %{
      conn: conn,
      owner: owner,
      runtime: runtime
    } do
      {:ok, view, html} = live(as_user(conn, owner), ~p"/terminal/#{runtime.runtime_id}")

      assert has_element?(view, "#terminal-title", "· terminal")
      assert has_element?(view, ~s(#terminal-mode-ro[aria-pressed="true"]), "View only")
      assert has_element?(view, ~s(#terminal-mode-rw[aria-pressed="false"]), "Can type")
      assert has_element?(view, "#terminal-copy", "A shell as you.")
      assert has_element?(view, "#terminal-connecting", "Connecting to your machine…")

      assert has_element?(
               view,
               "#terminal-first-use",
               "Closing this detaches; your session keeps running."
             )

      refute has_element?(view, "#terminal-keys")
      refute has_element?(view, "#terminal-rw-dot")
      assert has_element?(view, ~s(#terminal-detach[aria-label="Detach"]))

      assert has_element?(
               view,
               ~s(#terminal-root[phx-hook="TerminalHost"][data-runtime-id="#{runtime.runtime_id}"])
             )

      assert has_element?(view, ~s(#terminal-host[phx-update="ignore"]))
      refute html =~ ~r/#terminal-keys/
    end

    test "a click on Can type asks the hook; the page changes only when core confirms", %{
      conn: conn,
      owner: owner,
      runtime: runtime
    } do
      {:ok, view, _} = live(as_user(conn, owner), ~p"/terminal/#{runtime.runtime_id}")

      view |> element("#terminal-mode-rw") |> render_click()
      assert_push_event(view, "terminal:set_mode", %{mode: "rw"})
      assert has_element?(view, ~s(#terminal-mode-ro[aria-pressed="true"]))
      refute has_element?(view, "#terminal-keys")

      render_hook(view, "terminal_mode", %{"mode" => "rw"})
      assert has_element?(view, ~s(#terminal-mode-rw[aria-pressed="true"]))
      assert has_element?(view, "#terminal-rw-dot")
      assert has_element?(view, "#terminal-copy", "Typing goes to your terminal")
      assert has_element?(view, "#terminal-keys button", "Esc")
      assert has_element?(view, "#terminal-keys button", "Ctrl")
      assert has_element?(view, ~s(#terminal-keys[class~="lg:hidden"]))

      render_hook(view, "terminal_mode", %{"mode" => "ro"})
      refute has_element?(view, "#terminal-keys")
      refute has_element?(view, "#terminal-rw-dot")
    end

    test "the starting folder arrives from the browser and shows in the copy", %{
      conn: conn,
      owner: owner,
      runtime: runtime
    } do
      {:ok, view, _} = live(as_user(conn, owner), ~p"/terminal/#{runtime.runtime_id}")
      render_hook(view, "terminal_state", %{"state" => "connected"})
      render_hook(view, "terminal_cwd", %{"cwd" => "~/projects/example"})
      assert has_element?(view, "#terminal-conn", "Connected")

      assert has_element?(
               view,
               "#terminal-copy",
               "A shell as you, starting in ~/projects/example."
             )
    end

    test "flag-off copy renders verbatim, with Copy and no error colour", %{
      conn: conn,
      owner: owner,
      runtime: runtime
    } do
      {:ok, view, _} = live(as_user(conn, owner), ~p"/terminal/#{runtime.runtime_id}")
      render_hook(view, "terminal_state", %{"state" => "refused", "reason" => "flag_off"})

      assert has_element?(
               view,
               "#terminal-flag-off",
               "Remote terminal is off for this agent. Start it with `burrow claude --remote-terminal`"
             )

      assert has_element?(view, "#terminal-copy-command", "Copy")

      assert has_element?(
               view,
               ~s(#terminal-copy-command[data-clipboard-text="burrow claude --remote-terminal"])
             )

      html = view |> element("#terminal-flag-off") |> render()
      refute html =~ ~r/text-(error|warning|danger)|bg-(error|warning|danger)/
      refute has_element?(view, "#terminal-connecting")
    end

    test "offline and dropped states use the canvas copy", %{
      conn: conn,
      owner: owner,
      runtime: runtime
    } do
      {:ok, view, _} = live(as_user(conn, owner), ~p"/terminal/#{runtime.runtime_id}")
      render_hook(view, "terminal_state", %{"state" => "offline", "reason" => "offline"})

      assert has_element?(
               view,
               "#terminal-offline",
               "Your machine isn't connected right now. It will reconnect when burrow-cli is back."
             )

      assert has_element?(view, "#terminal-conn", "Reconnecting")

      render_hook(view, "terminal_state", %{"state" => "reconnecting"})
      assert has_element?(view, "#terminal-banner", "Reconnecting")
      assert has_element?(view, ~s(#terminal-host[data-dimmed="true"]))
    end

    test "a non-owner gets a refusal and no mode switch, and no agent name", %{
      conn: conn,
      other: other,
      runtime: runtime
    } do
      {:ok, view, _} = live(as_user(conn, other), ~p"/terminal/#{runtime.runtime_id}")
      refute has_element?(view, "#terminal-mode")
      refute has_element?(view, "#terminal-copy")
      render_hook(view, "terminal_state", %{"state" => "refused", "reason" => "forbidden"})
      assert has_element?(view, "#terminal-refused")
      refute has_element?(view, "#terminal-flag-off")
      refute render(view) =~ "Term Agent"

      # even a forged set_mode does nothing for a non-owner
      render_click(view, "set_mode", %{"mode" => "rw"})
      refute_push_event(view, "terminal:set_mode", %{mode: "rw"})
    end

    test "an unknown runtime id is the same refusal, not a crash", %{conn: conn, other: other} do
      {:ok, view, _} = live(as_user(conn, other), ~p"/terminal/no-such-runtime")
      refute has_element?(view, "#terminal-mode")
    end

    test "it hands the hook a 60 second token for the viewer only", %{
      conn: conn,
      owner: owner,
      runtime: runtime
    } do
      {:ok, view, _} = live(as_user(conn, owner), ~p"/terminal/#{runtime.runtime_id}")
      render_hook(view, "terminal_token", %{})
      assert_reply(view, %{token: token})

      assert {:ok, owner_id} =
               Phoenix.Token.verify(PlatformWeb.Endpoint, "terminal socket v1", token,
                 max_age: 60
               )

      assert owner_id == owner.id
    end

    test "unsupported browsers get a plain message, never a plaintext path", %{
      conn: conn,
      owner: owner,
      runtime: runtime
    } do
      {:ok, view, _} = live(as_user(conn, owner), ~p"/terminal/#{runtime.runtime_id}")
      render_hook(view, "terminal_state", %{"state" => "unsupported"})
      assert has_element?(view, "#terminal-unsupported", "needs X25519")
    end

    test "detach goes back to the agent without touching its session", %{
      conn: conn,
      owner: owner,
      agent: agent,
      runtime: runtime
    } do
      {:ok, view, _} = live(as_user(conn, owner), ~p"/terminal/#{runtime.runtime_id}")
      render_click(view, "detach", %{})
      assert_redirect(view, "/control/#{agent.slug}")
    end

    test "no state of the page uses a word the copy rules forbid", %{
      conn: conn,
      owner: owner,
      runtime: runtime
    } do
      {:ok, view, html} = live(as_user(conn, owner), ~p"/terminal/#{runtime.runtime_id}")

      states = [
        %{"state" => "connected"},
        %{"state" => "reconnecting"},
        %{"state" => "offline", "reason" => "offline"},
        %{"state" => "refused", "reason" => "flag_off"},
        %{"state" => "refused", "reason" => "forbidden"},
        %{"state" => "unsupported"}
      ]

      rendered =
        for s <- states, mode <- ["ro", "rw"], reduce: [html] do
          acc ->
            render_hook(view, "terminal_mode", %{"mode" => mode})
            [render_hook(view, "terminal_state", s) | acc]
        end

      # The page itself, not the app chrome around it.
      for h <- rendered do
        text =
          h |> LazyHTML.from_fragment() |> LazyHTML.query("#terminal-screen") |> LazyHTML.text()

        refute text =~ @banned, "banned word in: #{inspect(Regex.run(@banned, text))}"
      end

      screen = view |> element("#terminal-screen") |> render()
      refute screen =~ @banned
    end
  end
end
