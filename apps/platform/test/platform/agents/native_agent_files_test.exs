defmodule Platform.Agents.NativeAgentFilesTest do
  @moduledoc """
  A native agent's files (task 01a10322 stage 5): stored per agent, edited by
  its owner or an install admin ONLY, written into its work dir on every start.

  Editing them is root-equivalent on the install (`.claude/settings.json`
  hooks run as the agent, which may have sudo), so the refusal is the point
  and every refusal case has its positive control beside it: the owner and
  an admin DO succeed through the same call, so a denial is not just a save
  that never works.

  Mutants these name:

    * delete the `can_manage?/2` clause in `NativeAgents.save_file/5` →
      "a member who neither owns nor administers the agent is refused" goes
      red (the row changes);
    * delete the `can_manage?/2` check in `NativeFileEvents` AND the one in
      `save_file/5` → the LiveView refusal cases go red;
    * drop the `managed?` routing in `WorkspaceEvents` → "the old
      save_workspace_file event is refused too" goes red;
    * drop `"files"` from the reconciler's `agent.start` → the start payload
      case goes red.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.AgentHost.Reconciler
  alias Platform.Agents.{Agent, MemoryContext, NativeAgents, WorkspaceFile}
  alias Platform.Repo
  alias Platform.Tenancy.OrgMembership

  # ── Fixtures ──────────────────────────────────────────────────────

  defp user!(label) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "native-files-#{label}-#{n}@example.com",
      name: "Native Files #{label} #{n}",
      oidc_sub: "oidc-native-files-#{label}-#{n}"
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

  defp native!(owner, name, harness \\ "claude_code") do
    {:ok, agent, runtime} = NativeAgents.create(owner.id, %{name: name, harness: harness})
    {agent, runtime}
  end

  defp file(agent, key), do: MemoryContext.get_workspace_file(agent.id, key)

  defp as(conn, user), do: init_test_session(conn, current_user_id: user.id)

  defp join_host!, do: :ok = Reconciler.host_joined(self(), %{"profile" => "contained"})

  defp observe!(%Agent{id: id}, state, extra \\ %{}) do
    :ok = Reconciler.agent_state(self(), Map.merge(%{"agent_id" => id, "state" => state}, extra))
  end

  setup do
    previous = Application.get_env(:platform, :agent_host_token)
    Application.put_env(:platform, :agent_host_token, "agent-host-token-01a10322-s5-files")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:platform, :agent_host_token, previous),
        else: Application.delete_env(:platform, :agent_host_token)
    end)

    %{owner: member!("member"), admin: member!("admin"), other: member!("member")}
  end

  # ── Seeding ───────────────────────────────────────────────────────

  describe "create/2 seeds the agent's files" do
    test "Claude Code: CLAUDE.md from the identity template, and .claude/settings.json as {}",
         %{owner: owner} do
      {agent, _} = native!(owner, "Ada")

      assert %WorkspaceFile{version: 1, content: claude_md} = file(agent, "CLAUDE.md")
      assert %WorkspaceFile{version: 1, content: "{}"} = file(agent, ".claude/settings.json")
      assert is_nil(file(agent, "AGENTS.md"))

      assert claude_md =~ "You are Ada"
      assert claude_md =~ "Claude Code"
      assert claude_md =~ "sudo"
      assert claude_md =~ "install packages"
      assert claude_md =~ "run your own services"
      assert claude_md =~ "link"
      # It does not claim the agent is walled off from other agents.
      assert claude_md =~ "they are not a wall"
      refute claude_md =~ ~r/\bisolated\b|\bsandboxed\b|cannot (see|read|reach)/i
    end

    test "Codex: AGENTS.md instead of CLAUDE.md", %{owner: owner} do
      {agent, _} = native!(owner, "Cody", "codex")

      assert %WorkspaceFile{content: agents_md} = file(agent, "AGENTS.md")
      assert agents_md =~ "Codex CLI"
      assert is_nil(file(agent, "CLAUDE.md"))
      assert %WorkspaceFile{content: "# Codex settings" <> _} = file(agent, ".codex/config.toml")
      assert is_nil(file(agent, ".claude/settings.json"))
    end

    test "settings_key/1 delegates to the adapter" do
      assert NativeAgents.settings_key("claude_code") == ".claude/settings.json"
      assert NativeAgents.settings_key("codex") == ".codex/config.toml"
      assert NativeAgents.settings_key("hermes") == :unsupported
      assert NativeAgents.settings_key(nil) == :unsupported
    end
  end

  # ── Who may save ──────────────────────────────────────────────────

  describe "save_file/5: owner or admin only" do
    test "a member who neither owns nor administers the agent is refused; the row is unchanged",
         %{owner: owner, other: other} do
      {agent, _} = native!(owner, "Ada")
      before = file(agent, ".claude/settings.json")
      hook = ~s({"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"id"}]}]}})

      refute NativeAgents.can_manage?(other, agent)

      assert {:error, :forbidden} =
               NativeAgents.save_file(other, agent, ".claude/settings.json", hook, 1)

      # Also refused for a new key, a bare id and nil.
      assert {:error, :forbidden} = NativeAgents.save_file(other.id, agent, "x.md", "x", nil)
      assert {:error, :forbidden} = NativeAgents.save_file(nil, agent, "x.md", "x", nil)

      after_ = file(agent, ".claude/settings.json")
      assert after_.content == before.content
      assert after_.version == before.version
      assert after_.updated_at == before.updated_at
      assert is_nil(file(agent, "x.md"))
    end

    test "POSITIVE CONTROL: the owner and an install admin both succeed", %{
      owner: owner,
      admin: admin
    } do
      {agent, _} = native!(owner, "Ada")

      assert {:ok, %WorkspaceFile{version: 2, content: ~s({"a":1})}} =
               NativeAgents.save_file(owner, agent, ".claude/settings.json", ~s({"a":1}), 1)

      assert NativeAgents.can_manage?(admin, agent)

      assert {:ok, %WorkspaceFile{version: 3, content: ~s({"a":2})}} =
               NativeAgents.save_file(admin, agent, ".claude/settings.json", ~s({"a":2}), 2)

      # A new file, by the owner's bare id.
      assert {:ok, %WorkspaceFile{version: 1}} =
               NativeAgents.save_file(owner.id, agent, "notes/todo.md", "- one", nil)
    end

    test "a non-native agent is refused, even for an admin", %{admin: admin} do
      agent =
        Repo.insert!(%Agent{
          slug: "builtin-files-#{System.unique_integer([:positive])}",
          name: "Builtin",
          status: "active"
        })

      assert {:error, :not_managed} = NativeAgents.save_file(admin, agent, "CLAUDE.md", "x", nil)
      assert is_nil(file(agent, "CLAUDE.md"))
    end
  end

  # ── Keys ──────────────────────────────────────────────────────────

  describe "valid_file_key?/1" do
    test "accepts relative keys up to four deep (a skill is .claude/skills/<name>/SKILL.md)" do
      for key <- [
            "CLAUDE.md",
            "AGENTS.md",
            ".claude/settings.json",
            "a/b/c.md",
            ".mcp.json",
            ".claude/skills/x/SKILL.md"
          ] do
        assert NativeAgents.valid_file_key?(key), key
      end
    end

    test "refuses traversal, absolute, home-relative, too deep and odd characters" do
      for key <- [
            "../x",
            "/etc/x",
            "a/../../x",
            "a/..",
            "./x",
            "~/x",
            "~agent/x",
            "a/b/c/d/e",
            "",
            "a//b",
            "a/",
            "..",
            ".",
            "...",
            "a\nb",
            "a b",
            "-rf",
            "a\\b",
            "x\0",
            String.duplicate("a", 256),
            nil,
            42
          ] do
        refute NativeAgents.valid_file_key?(key), inspect(key)
      end
    end

    test "save_file refuses an invalid key, even for the owner", %{owner: owner} do
      {agent, _} = native!(owner, "Ada")
      assert {:error, :invalid_key} = NativeAgents.save_file(owner, agent, "../x", "x", nil)
      assert {:error, :invalid_key} = NativeAgents.save_file(owner, agent, "/etc/x", "x", nil)
      assert {:error, :invalid_key} = NativeAgents.save_file(owner, agent, "a/../../x", "x", nil)
      assert MemoryContext.list_workspace_files(agent.id) |> length() == 2
    end
  end

  # ── Versions ──────────────────────────────────────────────────────

  describe "versions" do
    test "each save bumps the version; a stale version is refused and changes nothing", %{
      owner: owner,
      admin: admin
    } do
      {agent, _} = native!(owner, "Ada")

      assert {:ok, %{version: 2}} = NativeAgents.save_file(owner, agent, "CLAUDE.md", "# v2", 1)
      assert {:ok, %{version: 3}} = NativeAgents.save_file(admin, agent, "CLAUDE.md", "# v3", 2)

      # The owner's editor still holds version 2.
      assert {:error, :stale_workspace_file} =
               NativeAgents.save_file(owner, agent, "CLAUDE.md", "# lost", 2)

      assert %{version: 3, content: "# v3"} = file(agent, "CLAUDE.md")

      # A "new file" save over an existing key is refused, not an overwrite.
      assert {:error, :file_exists} =
               NativeAgents.save_file(owner, agent, "CLAUDE.md", "# new", nil)

      assert %{version: 3, content: "# v3"} = file(agent, "CLAUDE.md")
    end

    test "a .json file that does not parse is refused, with its line", %{owner: owner} do
      {agent, _} = native!(owner, "Ada")

      assert {:error, {:invalid_json, 3}} =
               NativeAgents.save_file(
                 owner,
                 agent,
                 ".claude/settings.json",
                 "{\n  \"a\": 1,\n  oops\n}",
                 1
               )

      assert %{version: 1, content: "{}"} = file(agent, ".claude/settings.json")

      # A markdown file is not parsed.
      assert {:ok, _} = NativeAgents.save_file(owner, agent, "CLAUDE.md", "{ not json", 1)
    end
  end

  # ── Write on start ────────────────────────────────────────────────

  describe "agent.start carries the files" do
    test "start_files/1 lists every valid-key file; an invalid stored key is left out", %{
      owner: owner
    } do
      {agent, _} = native!(owner, "Ada")
      # A row written by some other path, with a key the host would refuse.
      {:ok, _} = MemoryContext.upsert_workspace_file(agent.id, "../evil", "x")

      files = NativeAgents.start_files(agent)

      assert Enum.map(files, & &1["key"]) |> Enum.sort() == [".claude/settings.json", "CLAUDE.md"]

      assert %{"content" => "{}", "version" => 1} =
               Enum.find(files, &(&1["key"] == ".claude/settings.json"))
    end

    test "the reconciler's agent.start includes the latest saved files", %{owner: owner} do
      join_host!()
      {agent, _} = native!(owner, "Ada")
      {:ok, _} = NativeAgents.save_file(owner, agent, "CLAUDE.md", "# Ada v2", 1)

      :ok = Platform.AgentHost.start_agent(agent)

      assert_receive {:agent_host_push, "agent.start", %{"agent_id" => id, "files" => files}}
      assert id == agent.id

      assert %{"content" => "# Ada v2", "version" => 2} =
               Enum.find(files, &(&1["key"] == "CLAUDE.md"))
    end
  end

  # ── Restart to apply ──────────────────────────────────────────────

  describe "pending_file_keys/2 and restart_to_apply?/2" do
    test "derived from stored versions against what the host applied", %{owner: owner} do
      {agent, _} = native!(owner, "Ada")
      files = NativeAgents.list_files(agent)
      applied = %{"CLAUDE.md" => 1, ".claude/settings.json" => 1}

      # Everything applied: nothing pending.
      refute NativeAgents.restart_to_apply?(files, %{state: :running, files_applied: applied})

      # A save after the start.
      {:ok, _} = NativeAgents.save_file(owner, agent, "CLAUDE.md", "# v2", 1)
      files = NativeAgents.list_files(agent)
      observed = %{state: :running, files_applied: applied}
      assert NativeAgents.pending_file_keys(files, observed) == ["CLAUDE.md"]
      assert NativeAgents.restart_to_apply?(files, observed)
      assert NativeAgents.restart_to_apply?(files, %{observed | state: :needs_login})

      # A file the host never wrote is pending too.
      {:ok, _} = NativeAgents.save_file(owner, agent, "notes.md", "n", nil)
      files = NativeAgents.list_files(agent)

      assert NativeAgents.pending_file_keys(files, observed) |> Enum.sort() == [
               "CLAUDE.md",
               "notes.md"
             ]

      # Not up: the next start applies everything, so nothing reads pending.
      for state <- [:stopped, :crashed] do
        refute NativeAgents.restart_to_apply?(files, %{state: state, files_applied: applied})
      end

      # Nothing known: no host report, or a report without files_applied.
      refute NativeAgents.restart_to_apply?(files, nil)
      refute NativeAgents.restart_to_apply?(files, %{state: :running, files_applied: nil})
    end
  end

  # ── The editor on Agent Resources ─────────────────────────────────

  describe "Agent files on Agent Resources" do
    test "a non-manager sees the message, not the files", %{
      conn: conn,
      owner: owner,
      other: other
    } do
      {agent, _} = native!(owner, "Ada")

      {:ok, view, html} = live(as(conn, other), ~p"/control/#{agent.slug}")

      assert has_element?(
               view,
               "#native-files-locked",
               "Only the agent's owner or an admin can edit its files."
             )

      refute has_element?(view, "#native-file-form")
      refute html =~ "You are Ada"

      # Positive control: the owner sees the editor and the file.
      {:ok, owner_view, _} = live(as(conn, owner), ~p"/control/#{agent.slug}")
      assert has_element?(owner_view, "#native-file-form")
      refute has_element?(owner_view, "#native-files-locked")
    end

    test "a non-manager's save is refused server-side even when sent directly", %{
      conn: conn,
      owner: owner,
      other: other
    } do
      {agent, _} = native!(owner, "Ada")
      before = file(agent, ".claude/settings.json")
      hook = ~s({"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"id"}]}]}})

      {:ok, view, _} =
        live(as(conn, other), ~p"/control/#{agent.slug}?file=.claude/settings.json")

      render_hook(view, "native_file_save", %{
        "native_file" => %{"file_key" => ".claude/settings.json", "content" => hook},
        "intent" => "save"
      })

      # The older editor's event is not a way around it either.
      render_hook(view, "save_workspace_file", %{
        "workspace_file" => %{"file_key" => ".claude/settings.json", "content" => hook}
      })

      render_hook(view, "save_workspace_file", %{
        "workspace_file" => %{"file_key" => "new.md", "content" => "x"}
      })

      after_ = file(agent, ".claude/settings.json")
      assert {after_.content, after_.version} == {before.content, before.version}
      assert is_nil(file(agent, "new.md"))
    end

    test "POSITIVE CONTROL: the owner's same direct save is written", %{conn: conn, owner: owner} do
      {agent, _} = native!(owner, "Ada")

      {:ok, view, _} =
        live(as(conn, owner), ~p"/control/#{agent.slug}?file=.claude/settings.json")

      render_hook(view, "native_file_save", %{
        "native_file" => %{"file_key" => ".claude/settings.json", "content" => ~s({"a":1})},
        "intent" => "save"
      })

      assert %{version: 2, content: ~s({"a":1})} = file(agent, ".claude/settings.json")
    end

    test "unsaved dot, invalid JSON, and the stopped Save-only hint", %{conn: conn, owner: owner} do
      join_host!()
      {agent, _} = native!(owner, "Ada")
      observe!(agent, "stopped")

      {:ok, view, _} =
        live(as(conn, owner), ~p"/control/#{agent.slug}?file=.claude/settings.json")

      refute has_element?(view, "[data-role=unsaved-dot]")
      # Stopped: Save only.
      assert has_element?(view, "#native-file-save")
      refute has_element?(view, "#native-file-save-restart")

      view
      |> form("#native-file-form", native_file: %{content: "{\n  \"a\": 1,\n  oops\n}"})
      |> render_change()

      assert has_element?(view, "[data-role=unsaved-dot]")
      assert has_element?(view, "#native-files-json-error", "line 3")
      assert has_element?(view, "#native-file-save[disabled]")

      view
      |> form("#native-file-form", native_file: %{content: ~s({"a": 1})})
      |> render_change()

      refute has_element?(view, "#native-files-json-error")
      refute has_element?(view, "#native-file-save[disabled]")

      view
      |> form("#native-file-form", native_file: %{content: ~s({"a": 1})})
      |> render_submit(%{"intent" => "save"})

      assert %{version: 2} = file(agent, ".claude/settings.json")
      refute has_element?(view, "[data-role=unsaved-dot]")

      assert has_element?(
               view,
               "#native-files-meta",
               "Saved. Ada will use this the next time it starts."
             )

      refute has_element?(view, "#native-files-applied-bar")
    end

    test "saved while running: the info bar, Restart now, and Save and restart", %{
      conn: conn,
      owner: owner
    } do
      join_host!()
      {agent, _} = native!(owner, "Ada")
      {:ok, _} = NativeAgents.set_desired_state(agent, "running")

      observe!(agent, "running", %{
        "files_applied" => %{"CLAUDE.md" => 1, ".claude/settings.json" => 1}
      })

      {:ok, view, _} = live(as(conn, owner), ~p"/control/#{agent.slug}?file=CLAUDE.md")

      assert has_element?(view, "#native-file-save-restart.btn-primary")
      refute has_element?(view, "#native-files-applied-bar")

      view
      |> form("#native-file-form", native_file: %{content: "# Ada v2"})
      |> render_submit(%{"intent" => "save"})

      assert has_element?(
               view,
               "#native-files-applied-bar",
               "Saved. Ada is still running the earlier version."
             )

      assert has_element?(view, "#native-files-restart-now", "Restart now")
      # The row says so too.
      assert has_element?(
               view,
               "#agent-row-#{agent.slug} [data-role=row-tag]",
               "Restart to apply"
             )

      # Save and restart sends agent.restart carrying the new file.
      view
      |> form("#native-file-form", native_file: %{content: "# Ada v3"})
      |> render_submit(%{"intent" => "save_restart"})

      assert_receive {:agent_host_push, "agent.restart", %{"files" => files}}

      assert %{"content" => "# Ada v3", "version" => 3} =
               Enum.find(files, &(&1["key"] == "CLAUDE.md"))

      # Once the host reports the new versions applied, the bar goes.
      observe!(agent, "running", %{
        "files_applied" => %{"CLAUDE.md" => 3, ".claude/settings.json" => 1}
      })

      refute has_element?(view, "#native-files-applied-bar")
      refute has_element?(view, "#agent-row-#{agent.slug} [data-role=row-tag]")
    end

    test "narrow screens get a select and a read-only copy", %{conn: conn, owner: owner} do
      {agent, _} = native!(owner, "Ada")

      {:ok, view, _} = live(as(conn, owner), ~p"/control/#{agent.slug}?file=CLAUDE.md")

      assert has_element?(view, "#native-files-narrow.md\\:hidden select#native-files-select")
      assert has_element?(view, "#native-files-narrow pre#native-files-readonly", "You are Ada")
      assert has_element?(view, "#native-files-narrow", "Edit files on a larger screen.")
      refute has_element?(view, "#native-files-narrow textarea")
      assert has_element?(view, "#native-files-wide.hidden.md\\:grid")
    end
  end
end
