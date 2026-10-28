defmodule PlatformWeb.AgentConfigLiveTest do
  @moduledoc """
  The configuration screen (task 01a17b1c stage 5) over the fake runtime host
  (federated agents, `runtime_host:`) and the workspace store (native).
  Elements are found with `LazyHTML.query/2` and `has_element?/2`, never
  `LazyHTML.filter/2`.

  Mutants these name (each run and pasted in the stage evidence):

    * render a secret's value next to its name -> "a secret's value is in no
      render" goes red;
    * add an Overwrite button to the conflict line -> "a conflict offers
      Compare and Copy my version, and no overwrite" goes red.
  """
  use PlatformWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.{Agent, NativeAgents}
  alias Platform.{FakeRuntimeHost, Federation, Repo}
  alias Platform.Tenancy.OrgMembership

  # ── fixtures ───────────────────────────────────────────────────────

  defp member!(role) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "acl-#{role}-#{n}@example.com",
        name: "Acl #{role} #{n}",
        oidc_sub: "oidc-acl-#{role}-#{n}"
      })

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

  defp tmp! do
    dir = Path.join(System.tmp_dir!(), "acl-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp put!(root, path, content) do
    full = Path.join(root, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, content)
  end

  defp probe, do: "probe-" <> Ecto.UUID.generate()

  # A federated agent whose fake host has joined `runtime_host:<id>`.
  defp federated!(owner, opts \\ []) do
    root = tmp!()
    for {path, content} <- Keyword.get(opts, :files, []), do: put!(root, path, content)
    n = System.unique_integer([:positive])
    {:ok, runtime} = Federation.register_runtime(owner.id, %{runtime_id: "acl-rt-#{n}"})
    {:ok, runtime, _token} = Federation.activate_runtime(runtime)

    agent =
      %Agent{}
      |> Agent.changeset(%{
        slug: "acl-agent-#{n}",
        name: "Saru #{n}",
        status: "active",
        runtime_type: "external"
      })
      |> Repo.insert!()

    {:ok, agent} = Federation.link_agent(runtime, agent)

    if Keyword.get(opts, :host, true) do
      pid =
        start_supervised!(
          {FakeRuntimeHost,
           [runtime_id: runtime.runtime_id, root: root, test_process: self()] ++
             Keyword.take(opts, [:opt_in, :harness, :session, :capabilities, :resumes])},
          id: {:host, n}
        )

      :ok = FakeRuntimeHost.ready(pid)
    end

    %{agent: agent, runtime: runtime, root: root}
  end

  defp q(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)
  defp texts(html, selector), do: html |> q(selector) |> Enum.map(&LazyHTML.text/1)
  defp present?(html, selector), do: Enum.count(q(html, selector)) > 0

  defp section_labels(html) do
    html
    |> texts("#config-sections button[id^=section-] > span:first-child")
    |> Enum.map(&String.trim/1)
  end

  setup do
    %{owner: member!("member"), other: member!("member"), admin: member!("admin")}
  end

  # ── sections per harness ───────────────────────────────────────────

  describe "sections come from the harness" do
    test "Claude Code: every concept, plain label with the real path", %{conn: conn, owner: owner} do
      %{agent: agent} =
        federated!(owner,
          files: [
            {"CLAUDE.md", "# Saru\n"},
            {".claude/skills/triage/SKILL.md",
             "---\nname: triage\ndescription: Sort the inbox\n---\n"},
            {".mcp.json",
             ~s({"mcpServers": {"linear": {"command": "npx", "args": ["linear-mcp"]}}})}
          ]
        )

      {:ok, _view, html} = live(as(conn, owner), ~p"/control/#{agent.slug}/config")

      assert texts(html, "#agent-config-header h1") |> hd() |> String.contains?("· Claude Code")

      assert section_labels(html) ==
               [
                 "Instructions",
                 "Skills (1)",
                 "Subagents (0)",
                 "Commands (0)",
                 "Settings",
                 "MCP servers (1)"
               ]

      paths = texts(html, "#config-sections .font-mono") |> Enum.map(&String.trim/1)

      assert paths ==
               [
                 "CLAUDE.md",
                 ".claude/skills/",
                 ".claude/agents/",
                 ".claude/commands/",
                 ".claude/settings.json",
                 ".mcp.json"
               ]
    end

    test "Codex: only Codex's concepts; no empty or 'not supported' section", %{
      conn: conn,
      owner: owner
    } do
      %{agent: agent} =
        federated!(owner,
          harness: "codex",
          files: [{"AGENTS.md", "# B\n"}, {".codex/config.toml", "model = \"o4\"\n"}]
        )

      {:ok, _view, html} = live(as(conn, owner), ~p"/control/#{agent.slug}/config")

      assert texts(html, "#agent-config-header h1") |> hd() |> String.contains?("· Codex")
      assert section_labels(html) == ["Instructions", "Skills (0)", "Settings", "MCP servers (0)"]
      refute present?(html, "#section-subagents")
      refute present?(html, "#section-commands")
      refute html =~ ~r/not supported|not available/i
      assert texts(html, "#config-editor-path") == ["AGENTS.md"]
    end

    test "a harness with no adapter: one line, no sections", %{conn: conn, owner: owner} do
      %{agent: agent} = federated!(owner, harness: "hermes")
      {:ok, _view, html} = live(as(conn, owner), ~p"/control/#{agent.slug}/config")

      assert texts(html, "#agent-config-unsupported") |> Enum.map(&String.trim/1) ==
               ["Configuration isn't available for this agent's harness."]

      refute present?(html, "#config-sections")
    end

    test "opt-in off: one plain line naming the CLI command, no error fill", %{
      conn: conn,
      owner: owner
    } do
      %{agent: agent} = federated!(owner, opt_in: "off")
      {:ok, _view, html} = live(as(conn, owner), ~p"/control/#{agent.slug}/config")

      [line] = q(html, "#agent-config-opt_in") |> Enum.to_list()
      assert LazyHTML.text(line) =~ "Config editing is off for this agent."
      assert LazyHTML.text(line) =~ "burrow config-access <dir> owner|admins"
      refute present?(html, "#agent-config-opt_in.bg-error, #agent-config .alert-error")
    end

    test "no runtime_host joined: offline unless the agent is connected (then: update the CLI)",
         %{
           conn: conn,
           owner: owner
         } do
      %{agent: agent, runtime: runtime} = federated!(owner, host: false)
      {:ok, _view, html} = live(as(conn, owner), ~p"/control/#{agent.slug}/config")
      assert present?(html, "#agent-config-offline")

      Platform.Federation.RuntimePresence.track(runtime.runtime_id)
      on_exit(fn -> Platform.Federation.RuntimePresence.untrack(runtime.runtime_id) end)

      {:ok, _view, html} = live(as(conn, owner), ~p"/control/#{agent.slug}/config")
      assert texts(html, "#agent-config-cli_update") |> hd() =~ "burrow CLI needs updating"
    end
  end

  # ── access ─────────────────────────────────────────────────────────

  describe "access" do
    test "a non-owner is redirected before anything is read", %{
      conn: conn,
      owner: owner,
      other: other
    } do
      %{agent: agent} = federated!(owner, files: [{"CLAUDE.md", "# secret plans\n"}])

      assert {:error, {:live_redirect, %{to: to}}} =
               live(as(conn, other), ~p"/control/#{agent.slug}/config")

      assert to == "/control/#{agent.slug}"
    end

    test "a root admin is refused at owner_only", %{conn: conn, owner: owner, admin: admin} do
      %{agent: agent} = federated!(owner, files: [{"CLAUDE.md", "# secret plans\n"}])

      assert {:error, {:live_redirect, _}} =
               live(as(conn, admin), ~p"/control/#{agent.slug}/config")

      # POSITIVE CONTROL: the owner gets the file.
      {:ok, _view, html} = live(as(conn, owner), ~p"/control/#{agent.slug}/config")
      assert html =~ "secret plans"
    end
  end

  # ── save, pending strip, restart ───────────────────────────────────

  describe "save hands the primary to Restart" do
    test "Save is primary only while dirty; after Save the strip is pending and Restart is primary",
         %{
           conn: conn,
           owner: owner
         } do
      %{agent: agent, root: root} = federated!(owner, files: [{"CLAUDE.md", "# Saru\n"}])
      {:ok, view, html} = live(as(conn, owner), ~p"/control/#{agent.slug}/config")

      assert present?(html, "#session-strip-up-to-date")
      assert present?(html, "#config-save[disabled]")
      refute present?(html, ".btn-primary")

      html = view |> form("#config-file-form", file: %{content: "# Saru v2\n"}) |> render_change()
      assert present?(html, "#config-save.btn-primary")
      refute present?(html, "#session-strip-restart.btn-primary")
      assert Enum.count(q(html, ".btn-primary")) == 1

      html = view |> form("#config-file-form", file: %{content: "# Saru v2\n"}) |> render_submit()

      assert File.read!(Path.join(root, "CLAUDE.md")) == "# Saru v2\n"

      assert texts(html, "#session-strip-pending") |> hd() =~
               "1 saved change applies on next session"

      assert present?(html, ~s(#session-strip-restart.btn-primary[data-primary="true"]))
      refute present?(html, "#config-save.btn-primary")
      assert Enum.count(q(html, ".btn-primary")) == 1
    end

    test "the restart diff renders + and − rows, then 'Last restart' keeps it", %{
      conn: conn,
      owner: owner
    } do
      %{agent: agent} =
        federated!(owner,
          files: [{"CLAUDE.md", "# Saru\n"}],
          session:
            {["linear/search", "old/gone"], ["linear/search", "linear/update", "figma/get"]}
        )

      {:ok, view, _} = live(as(conn, owner), ~p"/control/#{agent.slug}/config")
      # Assert the event response itself: a second LiveView round trip can
      # arrive after the fast fake restart has already completed.
      restarting = view |> element("#session-strip-restart") |> render_click()
      assert present?(restarting, "#session-strip-restarting")
      assert texts(restarting, "#session-strip-restarting") |> hd() =~ "Restarting…"

      html = render_async(view)
      assert present?(html, "#session-strip-restarted")

      assert texts(html, "#session-strip-diff p:first-child > span:first-child") |> hd() =~
               ~r/Tools \d+ → \d+:/

      added = texts(html, ~s(#session-strip-diff [data-diff="added"])) |> Enum.map(&String.trim/1)

      removed =
        texts(html, ~s(#session-strip-diff [data-diff="removed"])) |> Enum.map(&String.trim/1)

      assert added == ["+figma/get", "+linear/update"]
      assert removed == ["−old/gone"]

      # The 10 s collapse, sent now.
      %{session: %{token: token}} = :sys.get_state(view.pid).socket.assigns
      send(view.pid, {:session_strip_collapse, token})
      html = render(view)
      assert present?(html, "#session-strip-up-to-date")
      assert present?(html, ~s(#session-strip-last-diff [data-diff="added"]))
    end

    test "mid-task: the confirm names the task, and Cancel restarts nothing", %{
      conn: conn,
      owner: owner
    } do
      %{agent: agent} = federated!(owner, session: {[], ["a/b"]})

      {:ok, project} =
        Platform.Tasks.create_project(%{name: "Acl #{System.unique_integer([:positive])}"})

      {:ok, task} =
        Platform.Tasks.create_task(%{
          project_id: project.id,
          title: "Calendar direction",
          phase_assignees: %{
            "execution" => %{"assignee_id" => agent.id, "assignee_type" => "agent"}
          }
        })

      {:ok, _} = task |> Ecto.Changeset.change(status: "in_progress") |> Repo.update()

      {:ok, view, _} = live(as(conn, owner), ~p"/control/#{agent.slug}/config")
      html = view |> element("#session-strip-restart") |> render_click()

      assert texts(html, "#session-strip-confirm-copy") |> hd() |> String.trim() ==
               "#{agent.name} is working on 'Calendar direction'. Restarting resumes the conversation, " <>
                 "but the step in progress may need to be redone."

      html = view |> element("#session-strip-confirm-cancel") |> render_click()
      refute present?(html, "#session-strip-confirm")
      refute present?(html, "#session-strip-restarting")
    end

    test "the agent page carries the same strip and the Configuration entry", %{
      conn: conn,
      owner: owner
    } do
      %{agent: agent} = federated!(owner)
      {:ok, view, _} = live(as(conn, owner), ~p"/control/#{agent.slug}")
      assert has_element?(view, "#agent-session-strip-up-to-date", "Session is up to date")
      assert has_element?(view, "#agent-session-strip-restart", "Restart session")
      assert has_element?(view, ~s(#open-agent-config[href="/control/#{agent.slug}/config"]))
    end
  end

  describe "the strip's other states" do
    test "a harness that cannot resume says so before the click", %{conn: conn, owner: owner} do
      %{agent: agent} = federated!(owner, resumes: false)
      {:ok, _view, html} = live(as(conn, owner), ~p"/control/#{agent.slug}/config")

      assert texts(html, "#session-strip-fresh") |> Enum.map(&String.trim/1) == [
               "Starts a fresh conversation"
             ]

      # POSITIVE CONTROL: one that resumes does not.
      %{agent: other} = federated!(owner)
      {:ok, _view, html} = live(as(conn, owner), ~p"/control/#{other.slug}/config")
      refute present?(html, "#session-strip-fresh")
    end

    test "a diff with no earlier baseline carries the muted note" do
      diff = %{
        before: ["a/x"],
        after: ["a/x", "b/y"],
        added: ["b/y"],
        removed: [],
        outcome: "ready",
        resumed: true,
        before_basis: "now",
        restarted_at: ~U[2026-10-27 14:02:00Z]
      }

      session = %{
        phase: :restarted,
        diff: diff,
        last: diff,
        pending: 0,
        error: nil,
        confirm: nil,
        restart?: true,
        resumes?: true,
        agent_name: "Saru"
      }

      html =
        render_component(&PlatformWeb.AgentConfig.SessionStrip.strip/1, id: "s", session: session)

      assert texts(html, "#s-diff-basis") |> hd() =~
               "taken just now, so earlier changes may not show"

      assert texts(html, "#s-diff p:first-child > span:first-child") |> hd() =~ "Tools 1 → 2:"

      html =
        render_component(&PlatformWeb.AgentConfig.SessionStrip.strip/1,
          id: "s",
          session: %{session | diff: %{diff | before_basis: "loaded"}}
        )

      refute present?(html, "#s-diff-basis")
    end
  end

  # ── conflict ───────────────────────────────────────────────────────

  describe "conflict" do
    test "a conflict offers Compare and Copy my version, and no overwrite", %{
      conn: conn,
      owner: owner
    } do
      %{agent: agent, root: root} = federated!(owner, files: [{"CLAUDE.md", "# Saru\n"}])
      {:ok, view, _} = live(as(conn, owner), ~p"/control/#{agent.slug}/config")

      # The agent edits its own file after the page opened it.
      put!(root, "CLAUDE.md", "# Saru\nagent's own line\n")

      html =
        view |> form("#config-file-form", file: %{content: "# Saru, mine\n"}) |> render_submit()

      assert texts(html, "#config-conflict") |> hd() =~
               "Changed on the machine since you opened it"

      assert present?(html, "#config-compare")
      assert present?(html, "#config-copy-mine")
      refute html =~ ~r/overwrite/i
      refute present?(html, "[id*=overwrite], [phx-click*=overwrite], [data-action*=overwrite]")

      refute present?(
               html,
               "#config-conflict.bg-error, #config-file-form.bg-error, #config-source.bg-error"
             )

      # The refusal is the point: the machine's version is untouched.
      assert File.read!(Path.join(root, "CLAUDE.md")) == "# Saru\nagent's own line\n"

      html = view |> element("#config-compare") |> render_click()
      assert texts(html, "#config-compare-theirs") |> hd() =~ "agent's own line"
      assert texts(html, "#config-compare-yours") |> hd() =~ "# Saru, mine"

      # Edit on top of theirs, then save: written over THEIR hash, not past it.
      view |> element("#config-take-theirs") |> render_click()
      merged = "# Saru, mine\nagent's own line\n"
      view |> form("#config-file-form", file: %{content: merged}) |> render_submit()
      assert File.read!(Path.join(root, "CLAUDE.md")) == merged
    end
  end

  # ── secrets ────────────────────────────────────────────────────────

  describe "secrets" do
    test "a secret's value is in no render; names show with 'value hidden'", %{
      conn: conn,
      owner: owner
    } do
      p = probe()

      mcp =
        Jason.encode!(%{
          "mcpServers" => %{
            "fake-probe" => %{
              "command" => "node",
              "args" => ["srv.js"],
              "env" => %{"FAKE_TOKEN" => p}
            },
            "remote" => %{
              "type" => "http",
              "url" => "https://mcp.example.test/",
              "headers" => %{"X-Api-Key" => p}
            }
          }
        })

      %{agent: agent, root: root} =
        federated!(owner,
          files: [{".env", "API_KEY=#{p}\n"}, {".mcp.json", mcp}, {"CLAUDE.md", "# x\n"}]
        )

      {:ok, view, html0} = live(as(conn, owner), ~p"/control/#{agent.slug}/config")
      html_settings = view |> element("#section-settings") |> render_click()
      html_mcp = view |> element("#section-mcp_servers") |> render_click()
      html_raw = view |> element("#config-toggle-raw") |> render_click()

      for html <- [html0, html_settings, html_mcp, html_raw], do: refute(html =~ p)

      assert present?(html_settings, ~s([data-secret-row="API_KEY"]))
      assert texts(html_settings, ~s([data-secret-row="API_KEY"])) |> hd() =~ "value hidden"
      assert present?(html_mcp, ~s([data-secret-row="FAKE_TOKEN"]))
      assert present?(html_mcp, ~s([data-secret-row="X-Api-Key"]))
      # Write-only: an empty password field, no reveal, no copy.
      refute present?(html_mcp, "[data-secret-row] input[type=password][value]:not([value=''])")
      refute html_mcp =~ ~r/reveal|show value/i

      # Replace FAKE_TOKEN: the disk changes, the page still hides it.
      view |> element("#section-mcp_servers") |> render_click()
      fresh = probe()

      html =
        render_submit(view, "secret_set", %{
          "path" => ".mcp.json",
          "pointer" => "mcpServers/fake-probe/env/FAKE_TOKEN",
          "secret" => fresh
        })

      assert File.read!(Path.join(root, ".mcp.json")) =~ fresh
      refute html =~ fresh
      refute render(view) =~ fresh
    end

    test "a replaced secret never reaches the debug log (the field name is filtered)", %{
      conn: conn,
      owner: owner
    } do
      original_level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: original_level) end)

      mcp =
        Jason.encode!(%{
          "mcpServers" => %{
            "fake-probe" => %{"command" => "node", "env" => %{"FAKE_TOKEN" => "old"}}
          }
        })

      %{agent: agent, root: root} =
        federated!(owner, files: [{".mcp.json", mcp}, {"CLAUDE.md", "# x\n"}])

      {:ok, view, _} = live(as(conn, owner), ~p"/control/#{agent.slug}/config")
      view |> element("#section-mcp_servers") |> render_click()
      sentinel = "SENTINEL-" <> probe()

      log =
        capture_log([level: :debug], fn ->
          render_submit(view, "secret_set", %{
            "path" => ".mcp.json",
            "pointer" => "mcpServers/fake-probe/env/FAKE_TOKEN",
            "secret" => sentinel
          })
        end)

      # Positive control: the event's Parameters line is in the capture.
      assert log =~ "HANDLE EVENT"
      assert log =~ "mcpServers/fake-probe/env/FAKE_TOKEN"
      refute log =~ sentinel
      assert File.read!(Path.join(root, ".mcp.json")) =~ sentinel
    end
  end

  # ── settings, entries, MCP ─────────────────────────────────────────

  describe "settings" do
    test "Edit raw: a parse error keeps Save disabled and names the line", %{
      conn: conn,
      owner: owner
    } do
      %{agent: agent} =
        federated!(owner, files: [{".claude/settings.json", ~s({"model": "opus"})}])

      {:ok, view, _} = live(as(conn, owner), ~p"/control/#{agent.slug}/config")
      html = view |> element("#section-settings") |> render_click()
      assert present?(html, ~s(#settings-form input[name="settings[model]"][value="opus"]))

      view |> element("#config-toggle-raw") |> render_click()

      html =
        view
        |> form("#config-file-form", file: %{content: "{\n  \"model\": \"opus\",\n  oops\n}"})
        |> render_change()

      assert texts(html, "#config-parse-error") |> hd() =~ "line 3"
      assert present?(html, "#config-save[disabled]")
    end

    test "Codex: a known key is edited in place and comments survive", %{conn: conn, owner: owner} do
      toml = "# mine\nmodel = \"o4\"\n\n[mcp_servers.a]\ncommand = \"x\"\n"

      %{agent: agent, root: root} =
        federated!(owner, harness: "codex", files: [{".codex/config.toml", toml}])

      {:ok, view, _} = live(as(conn, owner), ~p"/control/#{agent.slug}/config")
      view |> element("#section-settings") |> render_click()
      view |> form("#settings-form", settings: %{model: "o5"}) |> render_submit()

      assert File.read!(Path.join(root, ".codex/config.toml")) ==
               "# mine\nmodel = \"o5\"\n\n[mcp_servers.a]\ncommand = \"x\"\n"
    end
  end

  describe "skills, subagents, commands" do
    test "New creates the file; Delete asks and names the file", %{conn: conn, owner: owner} do
      %{agent: agent, root: root} =
        federated!(owner,
          capabilities: ["file", "session", "file.delete"],
          files: [
            {".claude/skills/triage/SKILL.md",
             "---\nname: triage\ndescription: Sort the inbox\n---\n"}
          ]
        )

      {:ok, view, _} = live(as(conn, owner), ~p"/control/#{agent.slug}/config")
      html = view |> element("#section-skills") |> render_click()
      assert texts(html, "#config-entry-list li") |> Enum.join() =~ "Sort the inbox"

      view |> element("#entry-new-toggle") |> render_click()
      view |> form("#entry-new-form", entry: %{name: "probe-skill"}) |> render_submit()
      assert File.exists?(Path.join(root, ".claude/skills/probe-skill/SKILL.md"))
      assert has_element?(view, "#config-editor[data-path='.claude/skills/probe-skill/SKILL.md']")

      html =
        view
        |> element(
          ~s(#config-entry-list button[phx-value-path=".claude/skills/triage/SKILL.md"][aria-label])
        )
        |> render_click()

      assert texts(html, "#entry-delete-copy") |> hd() =~ ".claude/skills/triage/SKILL.md"
      view |> element("#entry-delete-yes") |> render_click()
      refute File.exists?(Path.join(root, ".claude/skills/triage/SKILL.md"))
    end

    test "no Delete where the host cannot delete", %{conn: conn, owner: owner} do
      %{agent: agent} =
        federated!(owner, files: [{".claude/skills/triage/SKILL.md", "---\nname: triage\n---\n"}])

      {:ok, view, _} = live(as(conn, owner), ~p"/control/#{agent.slug}/config")
      html = view |> element("#section-skills") |> render_click()
      assert present?(html, "#config-entry-list li")
      refute present?(html, "#config-entry-list button[aria-label^=Delete]")
    end
  end

  describe "MCP servers" do
    test "New writes the server and its approval (Claude Code)", %{conn: conn, owner: owner} do
      %{agent: agent, root: root} = federated!(owner)
      {:ok, view, _} = live(as(conn, owner), ~p"/control/#{agent.slug}/config")
      view |> element("#section-mcp_servers") |> render_click()
      view |> element("#mcp-new-toggle") |> render_click()

      view
      |> form("#mcp-new-form", mcp: %{name: "fake-probe", command: "bun", args: "srv.ts"})
      |> render_submit()

      assert %{"mcpServers" => %{"fake-probe" => %{"command" => "bun", "args" => ["srv.ts"]}}} =
               Jason.decode!(File.read!(Path.join(root, ".mcp.json")))

      assert %{"enabledMcpjsonServers" => ["fake-probe"]} =
               Jason.decode!(File.read!(Path.join(root, ".claude/settings.local.json")))

      assert has_element?(view, "#session-strip-pending")
    end
  end

  # ── markdown, native ───────────────────────────────────────────────

  describe "markdown and native agents" do
    test "Preview renders the markdown (Earmark)", %{conn: conn, owner: owner} do
      %{agent: agent} = federated!(owner, files: [{"CLAUDE.md", "# Heading\n\n- one\n"}])
      {:ok, view, _} = live(as(conn, owner), ~p"/control/#{agent.slug}/config")
      html = view |> element("#config-mode-preview") |> render_click()
      assert present?(html, "#config-preview li")
      assert present?(html, "#config-source.hidden")
    end

    test "a phone viewport opens markdown in Preview", %{conn: conn, owner: owner} do
      %{agent: agent} = federated!(owner, files: [{"CLAUDE.md", "# Heading\n"}])
      {:ok, view, _} = live(as(conn, owner), ~p"/control/#{agent.slug}/config")
      html = render_hook(view, "viewport", %{"below" => true})
      assert present?(html, ~s(#config-mode-preview[aria-pressed="true"]))
    end

    test "native Claude Code: the owner edits through the store", %{conn: conn, owner: owner} do
      {:ok, agent, _} = NativeAgents.create(owner.id, %{name: "Ada", harness: "claude_code"})
      {:ok, view, html} = live(as(conn, owner), ~p"/control/#{agent.slug}/config")
      assert texts(html, "#config-editor-path") == ["CLAUDE.md"]
      assert present?(html, "#session-strip-restart")

      view |> form("#config-file-form", file: %{content: "# Ada v2\n"}) |> render_submit()

      assert %{content: "# Ada v2\n"} =
               Platform.Agents.MemoryContext.get_workspace_file(agent.id, "CLAUDE.md")
    end

    test "native Codex: no Restart control (the agent host has no restart for it)", %{
      conn: conn,
      owner: owner
    } do
      {:ok, agent, _} = NativeAgents.create(owner.id, %{name: "Bo", harness: "codex"})
      {:ok, _view, html} = live(as(conn, owner), ~p"/control/#{agent.slug}/config")
      assert present?(html, "#session-strip")
      refute present?(html, "#session-strip-restart")
    end
  end
end
