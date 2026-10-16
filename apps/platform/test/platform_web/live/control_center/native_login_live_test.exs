defmodule PlatformWeb.ControlCenter.NativeLoginLiveTest do
  @moduledoc """
  Logging a native agent in on Agent Resources, its read-only "Recent
  output", and who may change its identity (task 01a10322 stage 6).

  The agent host is a helper process joined with `Reconciler.host_joined/2`:
  it forwards every command core pushes to the test, and answers
  `agent.pane` with whatever the test told it to, exactly as the real host's
  channel would broadcast it. No agent-host daemon runs.

  Mutants these name:

    * drop the `can_manage?/2` check in `NativeAgentEvents` for
      `native_api_key_save` → "a non-manager cannot start a login" goes red;
    * render the key back into the field (`value=`) → "the key never appears
      in rendered HTML" goes red;
    * add a `handle_event` that accepts a login code → "no surface accepts a
      login code" goes red (the event no longer reaches the page's refusing
      catch-all); delete that catch-all → the same case goes red (the view
      crashes, and its crash report prints the params);
    * drop `Redact.pane/1` from `AgentHost.recent_output/2` → the core-side
      login-screen case goes red (the host's answer here is NOT pre-redacted);
    * drop `with_native_manager/3` from `save_config` → the identity case
      goes red.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.AgentHost.Reconciler
  alias Platform.Agents.{Agent, NativeAgents, NativeLogin}
  alias Platform.Repo
  alias Platform.Tenancy.OrgMembership
  alias Platform.Vault

  @key "sk-ant-api03-" <> String.duplicate("q", 60) <> "LVKEY01a10322s6tailx"

  # ── Fixtures ──────────────────────────────────────────────────────

  defp user!(label) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "native-login-lv-#{label}-#{n}@example.com",
      name: "Native login LV #{label} #{n}",
      oidc_sub: "oidc-native-login-lv-#{label}-#{n}"
    })
  end

  defp member!(role) do
    user = user!(role)

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Platform.TenancyFixtures.acme_org_id(),
      role: role
    })
    |> Repo.insert!()

    user
  end

  defp as(conn, user), do: init_test_session(conn, current_user_id: user.id)

  defp native!(owner, name, desired \\ "running") do
    {:ok, agent, runtime} = NativeAgents.create(owner.id, %{name: name, harness: "claude_code"})
    {:ok, _runtime} = NativeAgents.set_desired_state(runtime, desired)
    agent
  end

  # A stand-in agent host. `pane` is what it answers `agent.pane` with.
  defp host!(pane \\ %{"lines" => [], "hidden" => nil}) do
    test = self()

    pid =
      spawn_link(fn ->
        host_loop(test, pane)
      end)

    :ok = Reconciler.host_joined(pid, %{"profile" => "contained"})
    pid
  end

  defp host_loop(test, pane) do
    receive do
      {:agent_host_push, "agent.pane", %{"ref" => ref} = payload} ->
        send(test, {:pane_requested, payload})

        Phoenix.PubSub.broadcast(
          Platform.PubSub,
          Platform.AgentHost.pane_topic(ref),
          {:agent_host_pane, ref, pane}
        )

        host_loop(test, pane)

      {:agent_host_push, event, payload} ->
        send(test, {:host_push, event, payload})
        host_loop(test, pane)

      :stop ->
        :ok
    end
  end

  defp observe!(host, %Agent{id: id}, state, extra \\ %{}) do
    :ok = Reconciler.agent_state(host, Map.merge(%{"agent_id" => id, "state" => state}, extra))
  end

  setup do
    previous = Application.get_env(:platform, :agent_host_token)
    Application.put_env(:platform, :agent_host_token, "agent-host-token-01a10322-s6-live")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:platform, :agent_host_token, previous),
        else: Application.delete_env(:platform, :agent_host_token)
    end)

    %{owner: member!("member")}
  end

  # ── The login steps ───────────────────────────────────────────────

  describe "needs login" do
    test "the login steps replace the files area; subscription is not available", %{
      conn: conn,
      owner: owner
    } do
      host = host!()
      agent = native!(owner, "Ada")
      observe!(host, agent, "needs_login", %{"login" => %{"step" => "login_method"}})

      {:ok, view, html} = live(as(conn, owner), ~p"/control/#{agent.slug}")

      assert has_element?(view, "#native-login h2", "Log Ada in to Claude")
      refute has_element?(view, "#native-files")
      assert has_element?(view, "#native-login-subscription", "Not available yet")
      assert has_element?(view, "#native-login", "Use an Anthropic API key")
      assert has_element?(view, "#native-api-key-form label", "API key")

      assert has_element?(
               view,
               "#native-api-key-form",
               "Stored encrypted in this install's vault."
             )

      # The subscription path's privacy line is not shown: that path is not offered.
      refute html =~ "Suite never sees your Claude token."

      # The ONLY inputs in the login steps are the agent id and the key.
      names =
        html
        |> LazyHTML.from_document()
        |> LazyHTML.query("#native-login input, #native-login textarea")
        |> LazyHTML.attribute("name")
        |> Enum.sort()

      assert names == ["agent_id", "api_key[value]"]
    end

    test "the owner saves a key: stored, and the agent restarts with it", %{
      conn: conn,
      owner: owner
    } do
      host = host!()
      agent = native!(owner, "Bea")
      observe!(host, agent, "needs_login", %{"login" => %{"step" => "login_method"}})

      {:ok, view, _html} = live(as(conn, owner), ~p"/control/#{agent.slug}")

      html =
        view
        |> form("#native-api-key-form", %{"agent_id" => agent.id, "api_key" => %{"value" => @key}})
        |> render_submit()

      assert html =~ "Saved the API key. Restarting Bea."
      assert NativeLogin.api_key_set?(agent)

      agent_id = agent.id

      assert_receive {:host_push, "agent.restart",
                      %{"agent_id" => ^agent_id, "env" => %{"ANTHROPIC_API_KEY" => @key}}}

      # The key never appears in rendered HTML, before or after.
      refute html =~ @key
      refute render(view) =~ @key
      refute render(view) =~ String.slice(@key, -20, 20)

      # Waiting while it starts, then logged in.
      observe!(host, agent, "starting")

      assert has_element?(
               view,
               "#native-login-waiting",
               "Waiting for Bea to start with the API key."
             )

      observe!(host, agent, "running")
      assert has_element?(view, "#native-login-success", "Bea is logged in to Claude.")
      refute render(view) =~ @key
    end

    test "a key Claude Code did not take reads as refused", %{conn: conn, owner: owner} do
      host = host!()
      agent = native!(owner, "Cy")
      :ok = NativeLogin.put_api_key(owner.id, agent, @key)
      observe!(host, agent, "needs_login", %{"login" => %{"step" => "api_key_confirm"}})

      {:ok, view, html} = live(as(conn, owner), ~p"/control/#{agent.slug}")

      assert has_element?(view, "#native-login-key-refused")
      assert has_element?(view, "#native-api-key-remove")
      refute html =~ @key
    end

    test "an invalid key is refused and nothing is stored", %{conn: conn, owner: owner} do
      host = host!()
      agent = native!(owner, "Dee")
      observe!(host, agent, "needs_login")

      {:ok, view, _html} = live(as(conn, owner), ~p"/control/#{agent.slug}")

      html =
        render_hook(view, "native_api_key_save", %{
          "agent_id" => agent.id,
          "api_key" => %{"value" => "not-a-key-0123456789abcdefghij"}
        })

      assert html =~ "That is not an Anthropic API key."
      refute NativeLogin.api_key_set?(agent)
      refute_receive {:host_push, "agent.restart", _}, 100
    end

    test "Remove deletes the key and restarts the agent", %{conn: conn, owner: owner} do
      host = host!()
      agent = native!(owner, "Eve")
      :ok = NativeLogin.put_api_key(owner.id, agent, @key)
      observe!(host, agent, "running")

      {:ok, view, _html} = live(as(conn, owner), ~p"/control/#{agent.slug}")
      render_click(element(view, "#native-api-key-remove"))

      refute NativeLogin.api_key_set?(agent)
      agent_id = agent.id
      assert_receive {:host_push, "agent.restart", %{"agent_id" => ^agent_id, "env" => env}}
      assert env == %{}
    end
  end

  describe "a non-manager cannot start a login" do
    test "no form is shown, and the event is refused server-side", %{conn: conn, owner: owner} do
      host = host!()
      agent = native!(owner, "Fay")
      observe!(host, agent, "needs_login")
      other = member!("member")

      {:ok, view, _html} = live(as(conn, other), ~p"/control/#{agent.slug}")

      assert has_element?(view, "#native-login-locked", "Someone who manages Fay can log it in.")
      refute has_element?(view, "#native-api-key-form")

      html =
        render_hook(view, "native_api_key_save", %{
          "agent_id" => agent.id,
          "api_key" => %{"value" => @key}
        })

      assert html =~ "Only the agent&#39;s owner or an admin can do that."
      assert Vault.list(scope: {:agent, agent.id}) == []
      refute_receive {:host_push, _, _}, 100

      # POSITIVE CONTROL: an admin may.
      admin = member!("admin")
      {:ok, admin_view, _html} = live(as(build_conn(), admin), ~p"/control/#{agent.slug}")

      render_hook(admin_view, "native_api_key_save", %{
        "agent_id" => agent.id,
        "api_key" => %{"value" => @key}
      })

      assert NativeLogin.api_key_set?(agent)
    end
  end

  # ── No surface accepts a login code ───────────────────────────────

  describe "no Suite surface accepts a Claude login code" do
    test "a hypothetical paste event is refused and reaches nothing", %{
      conn: conn,
      owner: owner
    } do
      host = host!()
      agent = native!(owner, "Gus")
      observe!(host, agent, "needs_login", %{"login" => %{"step" => "login_url"}})
      code = "PASTED-LOGIN-CODE-01a10322-s6#state"

      {:ok, view, _html} = live(as(conn, owner), ~p"/control/#{agent.slug}")

      for event <-
            ~w(native_login_code native_paste_code native_login_submit native_pane_input native_send_keys) do
        # Refused: the page's catch-all takes it, does nothing, and logs only
        # the event's name, never its params.
        {html, log} =
          ExUnit.CaptureLog.with_log(fn ->
            render_hook(view, event, %{"agent_id" => agent.id, "code" => code})
          end)

        assert log =~ ~s{refused unknown event "#{event}"}
        refute log =~ "PASTED-LOGIN-CODE"
        refute html =~ "PASTED-LOGIN-CODE"
      end

      # The view is still alive (positive control: a real event still works).
      assert render_hook(view, "native_recent_output", %{"agent_id" => agent.id}) =~
               "Recent output"

      assert_receive {:pane_requested, _}

      # Nothing else was sent to the host, and nothing was stored.
      refute_receive {:host_push, _, _}, 100
      assert Vault.list(scope: {:agent, agent.id}) == []
    end

    test "the only commands core sends the host are lifecycle, logs, the read-only pane and the key check" do
      source = File.read!(Path.join(File.cwd!(), "lib/platform/agent_host/reconciler.ex"))

      pushed =
        ~r/push\([^,]+,\s*"(agent\.[a-z_]+)"/
        |> Regex.scan(source, capture: :all_but_first)
        |> List.flatten()

      starts =
        ~r/send_start\([^,]+,\s*[^,]+,\s*"(agent\.[a-z_]+)"/
        |> Regex.scan(source, capture: :all_but_first)
        |> List.flatten()

      # Positive control: the scan finds the pushes that exist.
      assert "agent.stop" in pushed

      # `agent.check_auth` (stage 7 round 2) carries only `{agent_id, ref}`:
      # the host checks the agent's OWN stored API key and answers ok,
      # rejected or unknown. It never carries, and never asks for, a login
      # code; a subscription login is not checked at all (auth.ts).
      assert Enum.sort(Enum.uniq(pushed ++ starts ++ ["agent.start"])) ==
               [
                 "agent.check_auth",
                 "agent.logs",
                 "agent.pane",
                 "agent.restart",
                 "agent.start",
                 "agent.stop"
               ]

      # And no route on the router takes keystrokes for an agent.
      routes =
        PlatformWeb.Router
        |> Phoenix.Router.routes()
        |> Enum.map(& &1.path)

      refute Enum.any?(routes, &(&1 =~ ~r/agent.?host|pane|keys|login.?code/i))
    end
  end

  # ── Recent output ─────────────────────────────────────────────────

  describe "Recent output" do
    test "a manager reads it, scrubbed, read only", %{conn: conn, owner: owner} do
      host =
        host!(%{
          "lines" => ["working on it", "export ANTHROPIC_API_KEY=" <> @key, "done"],
          "hidden" => nil
        })

      agent = native!(owner, "Hana")
      observe!(host, agent, "running")

      {:ok, view, _html} = live(as(conn, owner), ~p"/control/#{agent.slug}")
      assert has_element?(view, "#native-logs h2", "Logs")

      html = render_click(element(view, "#native-recent-output-load"))

      agent_id = agent.id
      assert_receive {:pane_requested, %{"agent_id" => ^agent_id}}
      assert has_element?(view, "#native-recent-output-text", "working on it")
      assert html =~ "ANTHROPIC_API_KEY=[redacted]"
      refute html =~ @key

      # Read only: no input of any kind inside the disclosure.
      refute has_element?(view, "#native-recent-output input")
      refute has_element?(view, "#native-recent-output textarea")
      refute has_element?(view, "#native-recent-output form")
    end

    test "a login screen is withheld by core even when the host sent it", %{
      conn: conn,
      owner: owner
    } do
      host =
        host!(%{
          "lines" => [
            "Browser didn't open? Use the url below to sign in (c to copy)",
            "https://claude.com/cai/oauth/authorize?code=true&state=SECRETSTATE",
            "Paste code here if prompted >"
          ],
          "hidden" => nil
        })

      agent = native!(owner, "Ian")
      observe!(host, agent, "running")

      {:ok, view, _html} = live(as(conn, owner), ~p"/control/#{agent.slug}")
      html = render_click(element(view, "#native-recent-output-load"))

      assert has_element?(view, "#native-recent-output-hidden")
      refute html =~ "oauth/authorize"
      refute html =~ "SECRETSTATE"
      refute has_element?(view, "#native-recent-output-text")
    end

    test "a non-manager sees no Logs, and the event is refused", %{conn: conn, owner: owner} do
      host = host!(%{"lines" => ["private"], "hidden" => nil})
      agent = native!(owner, "Jo")
      observe!(host, agent, "running")
      other = member!("member")

      {:ok, view, _html} = live(as(conn, other), ~p"/control/#{agent.slug}")
      refute has_element?(view, "#native-logs")

      html = render_hook(view, "native_recent_output", %{"agent_id" => agent.id})
      assert html =~ "Only the agent&#39;s owner or an admin can do that."
      refute html =~ "private"
      refute_receive {:pane_requested, _}, 100
    end
  end

  # ── Identity for native agents ────────────────────────────────────

  describe "identity and voice on a native agent" do
    test "a non-manager sees the form disabled and a save is refused", %{
      conn: conn,
      owner: owner
    } do
      host = host!()
      agent = native!(owner, "Kit")
      observe!(host, agent, "running")
      other = member!("member")

      {:ok, view, _html} = live(as(conn, other), ~p"/control/#{agent.slug}")

      assert has_element?(view, "#native-identity-locked")
      assert has_element?(view, "#federated-identity-fieldset[disabled]")

      html = render_hook(view, "save_config", %{"config" => %{"name" => "Hijacked"}})
      assert html =~ "Only the agent&#39;s owner or an admin can do that."
      assert Repo.get!(Agent, agent.id).name == "Kit"

      assert render_hook(view, "remove_avatar", %{}) =~
               "Only the agent&#39;s owner or an admin can do that."

      # POSITIVE CONTROL: the owner's form is enabled and the save lands.
      {:ok, owner_view, _html} = live(as(build_conn(), owner), ~p"/control/#{agent.slug}")
      refute has_element?(owner_view, "#federated-identity-fieldset[disabled]")
      render_hook(owner_view, "save_config", %{"config" => %{"name" => "Kit Two"}})
      assert Repo.get!(Agent, agent.id).name == "Kit Two"
    end

    test "a non-manager's bundle change on a native agent is refused", %{
      conn: conn,
      owner: owner
    } do
      host = host!()
      agent = native!(owner, "Lou")
      observe!(host, agent, "running")

      before =
        Platform.Access.RuntimeProfiles.tool_profile(NativeAgents.get_managed_runtime(agent))

      other = member!("member")

      {:ok, view, _html} = live(as(conn, other), ~p"/control/#{agent.slug}")
      html = render_hook(view, "save_tool_profile", %{"modules" => ["memory"]})

      assert html =~ "Only the agent&#39;s owner or an admin can do that."

      assert Platform.Access.RuntimeProfiles.tool_profile(NativeAgents.get_managed_runtime(agent)) ==
               before
    end
  end
end
