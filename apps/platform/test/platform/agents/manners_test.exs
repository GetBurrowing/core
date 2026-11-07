defmodule Platform.Agents.MannersTest do
  @moduledoc """
  Every agent prompt path hands work to a person directly (task 01a1b733
  stage 1): each entry of `Manners.prompt_paths/0` is rendered through its
  real builder and must carry `Manners.handoff_rule/0`, and a scan of `lib/`
  fails on any prompt builder the registry does not list.

  Mutants these name:

    * drop `Manners.handoff_rule()` from `NativeAgents.identity_template/2`
      → the native and Burrow seed cases go red;
    * drop `Manners.ensure/1` from `NativeAgents.start_files/1` → "a stored
      file without the rule gets it at start" goes red;
    * drop `Manners.handoff_rule()` from `QuickAgent.build_system_prompt/1`
      → the built-in chat case goes red;
    * drop `Manners.ensure/1` from `PromptTemplates.federation_preamble/1`
      → the operator-edited row cases go red; drop it from the
      `@federation_preamble` constant → the no-row and seeded-row cases;
    * delete a registry entry → the enumeration guard goes red naming the file.
  """
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Agents.{Burrow, Manners, MemoryContext, NativeAgents, QuickAgent}
  alias Platform.Orchestration.{HeartbeatScheduler, PromptTemplate, PromptTemplates}

  @lib Path.expand("../../../lib", __DIR__)

  setup do
    previous = Application.get_env(:platform, :agent_host_token)
    Application.put_env(:platform, :agent_host_token, "manners-test-host-token")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:platform, :agent_host_token, previous),
        else: Application.delete_env(:platform, :agent_host_token)
    end)
  end

  defp rule, do: Manners.handoff_rule()

  defp count(text, needle), do: length(:binary.matches(text, needle))

  defp assert_rule_once(text, label) do
    assert count(text, String.trim_trailing(rule())) == 1,
           "#{label} must carry the handoff rule exactly once"

    assert count(text, Manners.marker()) == 1, "#{label}: one rule heading"
  end

  # ── ensure/1 ─────────────────────────────────────────────────────────

  describe "ensure/1" do
    test "appends when absent, is idempotent, and keeps the trailing whitespace" do
      once = Manners.ensure("# Ada\n\nOld text.\n")
      assert_rule_once(once, "ensure/1")
      assert String.starts_with?(once, "# Ada\n\nOld text.\n\n## Handing work to a person")
      assert String.ends_with?(once, "\n")
      assert Manners.ensure(once) == once

      no_newline = Manners.ensure("body")
      refute String.ends_with?(no_newline, "\n")
      assert_rule_once(no_newline, "ensure/1 without a final newline")
    end
  end

  # ── paths 1 and 3: seeds ─────────────────────────────────────────────

  describe "seeded instructions" do
    test "the native identity template carries the rule for both harnesses" do
      for harness <- ~w(claude_code codex) do
        assert_rule_once(NativeAgents.identity_template("Sam", harness), "native #{harness}")
      end
    end

    test "the Burrow identity template carries the rule for both harnesses" do
      for harness <- ~w(claude_code codex) do
        assert_rule_once(Burrow.identity_template("Burrow", harness), "Burrow #{harness}")
      end
    end
  end

  # ── path 2: every start ──────────────────────────────────────────────

  defp native!(name, harness) do
    owner = Platform.TenancyFixtures.root_admin!()
    {:ok, agent, _runtime} = NativeAgents.create(owner.id, %{name: name, harness: harness})
    agent
  end

  defp started(agent, key) do
    agent |> NativeAgents.start_files() |> Enum.find(&(&1["key"] == key))
  end

  describe "start_files/1" do
    test "a stored file without the rule gets it at start, exactly once" do
      for {harness, key} <- [{"claude_code", "CLAUDE.md"}, {"codex", "AGENTS.md"}] do
        agent = native!("Alex #{harness}", harness)
        {:ok, _} = MemoryContext.upsert_workspace_file(agent.id, key, "# Alex\n\nOld file.\n")
        stored = MemoryContext.get_workspace_file(agent.id, key)

        file = started(agent, key)
        assert String.starts_with?(file["content"], "# Alex\n\nOld file.\n")
        assert_rule_once(file["content"], "start_files #{harness}")
        # Not stored: the row and its version are untouched.
        assert file["version"] == stored.version
        assert MemoryContext.get_workspace_file(agent.id, key).content == "# Alex\n\nOld file.\n"
      end
    end

    test "a stored file that already has the rule still carries it once" do
      agent = native!("Sam", "claude_code")
      stored = MemoryContext.get_workspace_file(agent.id, "CLAUDE.md")
      assert_rule_once(stored.content, "the new seed")

      assert started(agent, "CLAUDE.md")["content"] == stored.content
    end

    test "other files are not touched" do
      agent = native!("Sam", "claude_code")
      assert started(agent, ".claude/settings.json")["content"] == "{}"
    end

    test "the Burrow agent's file carries the rule once, before the admins section" do
      owner = Platform.TenancyFixtures.root_admin!()
      {:ok, agent} = Burrow.ensure(owner.id, "codex")
      {:ok, _} = MemoryContext.upsert_workspace_file(agent.id, "AGENTS.md", "# Burrow\n")

      content = started(agent, "AGENTS.md")["content"]
      assert_rule_once(content, "Burrow start")
      [before_admins, _] = String.split(content, "## Owner and admins", parts: 2)
      assert before_admins =~ Manners.marker()
    end
  end

  # ── path 4: built-in chat ────────────────────────────────────────────

  defp tmp_dir!(label) do
    dir =
      Path.join(System.tmp_dir!(), "manners-#{label}-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  describe "QuickAgent system prompt" do
    test "the fixed frame carries the rule, with or without workspace files" do
      empty = tmp_dir!("quick-empty")
      assert_rule_once(QuickAgent.build_system_prompt(empty), "QuickAgent, no files")

      with_files = tmp_dir!("quick-files")
      File.write!(Path.join(with_files, "SOUL.md"), "Be kind.")
      prompt = QuickAgent.build_system_prompt(with_files)
      assert prompt =~ "Be kind."
      assert_rule_once(prompt, "QuickAgent, with files")
    end
  end

  # ── path 5: the federation preamble ──────────────────────────────────

  defp delete_preamble_row! do
    Repo.delete_all(from(t in PromptTemplate, where: t.slug == "federation.preamble"))
    :ok
  end

  defp edit_preamble_row!(content) do
    :ok = PromptTemplates.seed_defaults()
    row = PromptTemplates.get_template_by_slug("federation.preamble")
    {:ok, _} = PromptTemplates.update_template(row, %{content: content})
    :ok
  end

  # A running stage, so `DispatchPhase` resolves `dispatch.in_progress`
  # (with no plan and stage it would render `dispatch.planning`).
  defp in_progress_dispatch do
    stage = %{
      id: "01a1b733-0000-4000-8000-0000000000b1",
      position: 1,
      name: "Do the work",
      description: "The stage's own description.",
      status: "running",
      validations: [
        %{id: "01a1b733-0000-4000-8000-0000000000c1", kind: "test_pass", status: "pending"}
      ]
    }

    HeartbeatScheduler.dispatch_prompt(
      %{
        id: "01a1b733-0000-4000-8000-0000000000a1",
        title: "Handoff rule probe",
        description: "Probe task for the handoff rule",
        status: "in_progress",
        priority: "medium",
        project_id: nil,
        epic_id: nil,
        inserted_at: ~U[2026-11-07 08:00:00Z]
      },
      %{version: 1, stages: [stage]},
      stage
    )
  end

  describe "federation_preamble/1" do
    test "with no row" do
      :ok = delete_preamble_row!()
      assert_rule_once(PromptTemplates.federation_preamble(%{}), "preamble, no row")
    end

    test "with the seeded row" do
      :ok = delete_preamble_row!()
      :ok = PromptTemplates.seed_defaults()

      assert_rule_once(
        PromptTemplates.get_template_by_slug("federation.preamble").content,
        "seeded row"
      )

      assert_rule_once(PromptTemplates.federation_preamble(%{}), "preamble, seeded row")
    end

    test "with an operator-edited row that lacks the rule" do
      :ok = edit_preamble_row!("## Operator preamble\n\nOperator text.")

      preamble = PromptTemplates.federation_preamble(%{})
      assert String.starts_with?(preamble, "## Operator preamble\n\nOperator text.")
      assert_rule_once(preamble, "preamble, edited row")
    end

    test "rendered into dispatch.in_progress, default and edited row" do
      :ok = PromptTemplates.seed_defaults()
      dispatch = in_progress_dispatch()
      # The in_progress body, not the planning one.
      assert dispatch =~ "The stage's own description."
      assert_rule_once(dispatch, "dispatch.in_progress")

      :ok = edit_preamble_row!("## Operator preamble\n\nOperator text.")
      dispatch = in_progress_dispatch()
      assert dispatch =~ "Operator text."
      assert_rule_once(dispatch, "dispatch.in_progress, edited row")
    end
  end

  # ── no shipped text tells a person to go and look ────────────────────

  describe "shipped prompt text" do
    test "says neither 'check your inbox' nor 'it's in your inbox' outside the rule" do
      quick = QuickAgent.build_system_prompt(tmp_dir!("quick-scan"))

      texts =
        [{"QuickAgent frame", quick}] ++
          for(
            h <- ~w(claude_code codex),
            do: {"native identity #{h}", NativeAgents.identity_template("Sam", h)}
          ) ++
          for(
            h <- ~w(claude_code codex),
            do: {"Burrow identity #{h}", Burrow.identity_template("Burrow", h)}
          ) ++
          for(t <- PromptTemplates.default_templates(), do: {t.slug, t.content})

      rule_text = String.trim_trailing(rule())

      for {label, text} <- texts do
        stripped = String.replace(text, rule_text, "")

        refute stripped =~ ~r/check your inbox|it['’]s in your inbox/i,
               "#{label} tells a person to look in their inbox"
      end
    end
  end

  # ── the registry covers every prompt builder in lib/ ─────────────────

  @builders [
    {~r/^\s*def\s+identity_template\b/m, :identity_template, :any},
    {~r/^\s*defp?\s+build_system_prompt\b/m, :build_system_prompt, "platform/agents/"},
    {~r/^\s*def\s+federation_preamble\b/m, :federation_preamble, :any}
  ]

  # `{file, function | :template}` for every prompt builder under `root`.
  # Comment lines are skipped, so a mention in a comment is not a builder.
  @doc false
  def scan(root) do
    for path <- Path.wildcard(Path.join(root, "**/*.ex")),
        source = strip_comments(File.read!(path)),
        finding <- findings(Path.relative_to(path, root), source),
        do: {Path.expand(path), finding}
  end

  defp strip_comments(source) do
    source
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(String.trim_leading(&1), "#"))
    |> Enum.join("\n")
  end

  defp findings(rel, source) do
    funs =
      for {regex, fun, scope} <- @builders,
          scope == :any or String.starts_with?(rel, scope),
          Regex.match?(regex, source),
          do: fun

    if String.contains?(source, "{{federation_preamble}}"), do: [:template | funs], else: funs
  end

  defp source_of(module), do: module.module_info(:compile)[:source] |> to_string()

  defp unregistered(found, registry) do
    Enum.reject(found, fn {file, fun} ->
      Enum.any?(registry, fn {_id, mod, f} ->
        source_of(mod) == file and (fun == :template or fun == f)
      end)
    end)
  end

  defp failure(missing) do
    lines = for {file, fun} <- missing, do: "  #{Path.relative_to(file, @lib)}: #{fun}"

    "prompt builders missing from Manners.prompt_paths/0 (add the handoff " <>
      "rule there and register it):\n" <> Enum.join(lines, "\n")
  end

  describe "prompt_paths/0" do
    test "every registered builder exists" do
      for {id, mod, fun} <- Manners.prompt_paths() do
        assert Code.ensure_loaded?(mod), "#{id}: #{inspect(mod)} does not exist"

        assert Keyword.has_key?(mod.__info__(:functions), fun),
               "#{id}: #{inspect(mod)}.#{fun} does not exist"
      end
    end

    test "every prompt builder in lib/ is registered" do
      found = scan(@lib)

      # The scan must see the builders it is meant to find, or it proves nothing.
      assert Enum.any?(found, &match?({_, :identity_template}, &1))
      assert Enum.any?(found, &match?({_, :build_system_prompt}, &1))
      assert Enum.any?(found, &match?({_, :federation_preamble}, &1))
      assert Enum.any?(found, &match?({_, :template}, &1))

      missing = unregistered(found, Manners.prompt_paths())
      assert missing == [], failure(missing)
    end

    test "dropping an entry is caught, and the message names the file" do
      [_ | rest] = Manners.prompt_paths()
      missing = unregistered(scan(@lib), rest)

      assert [{file, :identity_template}] = missing
      assert failure(missing) =~ "platform/agents/native_agents.ex"
      assert file == source_of(NativeAgents)
    end

    test "a new builder in a scanned file is caught" do
      root = tmp_dir!("scan")
      File.mkdir_p!(Path.join(root, "platform/agents"))

      File.write!(Path.join(root, "platform/agents/new_agent.ex"), """
      defmodule NewAgent do
        # def identity_template(name) - a comment, not a builder
        def identity_template(name), do: name
      end
      """)

      File.write!(Path.join(root, "platform/agents/commented.ex"), """
      defmodule Commented do
        # def identity_template(name), do: name
      end
      """)

      missing = unregistered(scan(root), Manners.prompt_paths())
      assert [{file, :identity_template}] = missing
      assert String.ends_with?(file, "platform/agents/new_agent.ex")
    end
  end
end
