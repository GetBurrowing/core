defmodule Platform.Federation.ToolAliasesTest do
  @moduledoc """
  Task 01a14a7f stage 3: core's 17 formerly dotted tool names are listed by
  their underscore name only, and the dotted name still CALLS, through one
  resolve at `ToolCall.invoke/4`. Task 01a14b9e-50a4 stage 1 added the two
  code-mode tools' earlier names, `suite_run` and `suite_run_describe`
  (now `burrow_run` / `burrow_run_describe`), to the same table: 19.

  Anti-vacuity: delete one entry from `ToolAliases`' `@aliases` and that
  alias's parity test below fails (its dotted call is then refused as
  forbidden, which no canonical result here is: the positive control in the
  test), alongside the table-size test. Each alias has its own test,
  generated from this file's literal `@parity` list rather than from the
  table under test, so a removed alias fails ITS test, not a shared one.
  """

  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  import Platform.PrototypeFixtures,
    only: [scratch_storage!: 1, set_settings!: 1, bundle_files: 0]

  import Platform.TenancyFixtures

  alias Platform.Access.RuntimeProfiles
  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Chat
  alias Platform.Chat.Canvas.Server, as: CanvasServer
  alias Platform.CodeMode.Bindings
  alias Platform.CodeMode.Run
  alias Platform.Extensions
  alias Platform.FixtureExtension
  alias Platform.Federation.ToolAliases
  alias Platform.Federation.ToolCall
  alias Platform.Federation.ToolCallRecord
  alias Platform.Federation.ToolSurface
  alias Platform.Repo

  @broker Platform.Feedback.GithubPublisher.Broker

  # How each alias's two calls are compared. `:equal` for reads, whose
  # results must be identical; `:shape` for writes, where the second call
  # necessarily differs in ids or revision, so the ok/error tag and the
  # result's keys are compared instead.
  @parity %{
    "attachment.get_inline" => :equal,
    "attachment.upload_inline" => :shape,
    "attachment.upload_start" => :shape,
    "canvas.create" => :shape,
    "canvas.describe" => :equal,
    "canvas.list_kinds" => :equal,
    "canvas.patch" => :shape,
    "canvas.restore" => :shape,
    "canvas.template" => :equal,
    "canvas.versions" => :equal,
    "feedback.submit" => :shape,
    "prototype.publish" => :shape,
    "prototype.rollback" => :shape,
    "prototype.versions" => :equal,
    "skill.get" => :equal,
    "skill.list" => :equal,
    "skill.upsert" => :shape,
    "suite_run" => :shape,
    "suite_run_describe" => :equal
  }

  # The two legacy names that are not a dot-to-underscore swap (task
  # 01a14b9e-50a4 stage 1). Every other canonical name is the legacy name
  # with its dot replaced.
  @renamed %{"suite_run" => "burrow_run", "suite_run_describe" => "burrow_run_describe"}

  defp canonical_of(legacy), do: Map.get(@renamed, legacy, String.replace(legacy, ".", "_"))

  setup do
    saved = Application.fetch_env(:platform, :feedback_policy)

    on_exit(fn ->
      case saved do
        {:ok, v} -> Application.put_env(:platform, :feedback_policy, v)
        :error -> Application.delete_env(:platform, :feedback_policy)
      end
    end)

    Application.put_env(:platform, :feedback_policy, "quarantined")

    Req.Test.stub(@broker, fn conn ->
      Req.Test.json(Plug.Conn.put_status(conn, 201), %{
        "repository" => "Startup-Suite/core",
        "issue_number" => 7
      })
    end)

    scratch_storage!("tool_aliases_test")
    set_settings!(%{enabled: true, who_may_publish: "members"})

    n = System.unique_integer([:positive])

    agent =
      %Agent{}
      |> Agent.changeset(%{
        slug: "alias-agent-#{n}",
        name: "Alias Agent",
        status: "active",
        metadata: %{"org_id" => acme_org_id()}
      })
      |> Repo.insert!()

    {:ok, space} =
      Chat.create_space(%{name: "Alias #{n}", slug: "alias-space-#{n}", kind: "channel"})

    {:ok, _participant} = Chat.add_agent_participant(space.id, agent)

    raw_token = AgentRuntime.generate_token()
    modules = RuntimeProfiles.valid_modules()

    runtime =
      %AgentRuntime{}
      |> AgentRuntime.changeset(%{
        runtime_id: "alias-rt-#{n}",
        owner_user_id: root_admin!().id,
        agent_id: agent.id,
        auth_token_hash: AgentRuntime.hash_token(raw_token),
        status: "active"
      })
      |> Repo.insert!()

    {:ok, _profile} =
      RuntimeProfiles.create_for_runtime(
        runtime,
        modules,
        RuntimeProfiles.translated_permissions(modules)
      )

    %{agent: agent, space: space, runtime: runtime, token: raw_token}
  end

  # ── fixtures: the args for one call of each alias ─────────────────────

  defp document(text) do
    %{
      "version" => 1,
      "revision" => 1,
      "root" => %{
        "id" => "root",
        "type" => "stack",
        "children" => [%{"id" => "t", "type" => "text", "props" => %{"value" => text}}]
      }
    }
  end

  defp ok!(name, args, ctx) do
    assert {:ok, data} = ToolCall.invoke(name, args, ctx.runtime)
    data
  end

  defp canvas!(ctx) do
    data =
      ok!(
        "canvas_create",
        %{"space_id" => ctx.space.id, "title" => "Alias", "document" => document("one")},
        ctx
      )

    on_exit(fn -> CanvasServer.stop(data.canvas_id) end)
    data.canvas_id
  end

  defp revision(canvas_id) do
    {:ok, %{revision: revision}} = CanvasServer.describe(canvas_id)
    revision
  end

  # `args_for(alias, ctx)` returns a function of the call's turn (`:legacy`,
  # then `:canonical`) giving that call's args, so a write's second call can
  # read the state the first left.
  defp args_for("attachment.get_inline", ctx) do
    up =
      ok!(
        "attachment_upload_inline",
        %{
          "space_id" => ctx.space.id,
          "filename" => "a.txt",
          "content_type" => "text/plain",
          "data_base64" => Base.encode64("alias bytes")
        },
        ctx
      )

    fn _ -> %{"attachment_id" => up.id, "space_id" => ctx.space.id} end
  end

  defp args_for("attachment.upload_inline", ctx) do
    fn turn ->
      %{
        "space_id" => ctx.space.id,
        "filename" => "#{turn}.txt",
        "content_type" => "text/plain",
        "data_base64" => Base.encode64("bytes for #{turn}")
      }
    end
  end

  defp args_for("attachment.upload_start", ctx) do
    fn turn ->
      %{
        "space_id" => ctx.space.id,
        "filename" => "#{turn}.bin",
        "content_type" => "application/octet-stream",
        "byte_size" => 64
      }
    end
  end

  defp args_for("canvas.create", ctx) do
    fn turn ->
      %{"space_id" => ctx.space.id, "title" => "C #{turn}", "document" => document("#{turn}")}
    end
  end

  defp args_for("canvas.describe", ctx) do
    canvas_id = canvas!(ctx)
    fn _ -> %{"canvas_id" => canvas_id} end
  end

  defp args_for("canvas.list_kinds", _ctx), do: fn _ -> %{} end

  defp args_for("canvas.patch", ctx) do
    canvas_id = canvas!(ctx)

    fn turn ->
      %{
        "canvas_id" => canvas_id,
        "base_revision" => revision(canvas_id),
        "operations" => [["set_props", "t", %{"value" => "patched #{turn}"}]]
      }
    end
  end

  defp args_for("canvas.restore", ctx) do
    canvas_id = canvas!(ctx)

    ok!(
      "canvas_patch",
      %{
        "canvas_id" => canvas_id,
        "base_revision" => revision(canvas_id),
        "operations" => [["set_props", "t", %{"value" => "two"}]]
      },
      ctx
    )

    fn _ -> %{"canvas_id" => canvas_id, "revision" => 1} end
  end

  defp args_for("canvas.template", _ctx), do: fn _ -> %{"name" => "checklist"} end

  defp args_for("canvas.versions", ctx) do
    canvas_id = canvas!(ctx)
    fn _ -> %{"canvas_id" => canvas_id} end
  end

  defp args_for("feedback.submit", _ctx) do
    fn turn ->
      %{
        "category" => "bug",
        "title" => "Alias parity #{turn} #{System.unique_integer([:positive])}",
        "expected_behavior" => "Both names answer.",
        "observed_behavior" => "Checking that they do."
      }
    end
  end

  defp args_for("prototype.publish", _ctx) do
    fn turn -> %{"org_id" => acme_org_id(), "name" => "P #{turn}", "files" => bundle_files()} end
  end

  defp args_for("prototype.rollback", ctx) do
    published = prototype!(ctx)
    fn _ -> %{"prototype_id" => published.prototype_id, "version" => 1} end
  end

  defp args_for("prototype.versions", ctx) do
    published = prototype!(ctx)
    fn _ -> %{"prototype_id" => published.prototype_id} end
  end

  defp args_for("skill.get", ctx) do
    skill = skill!(ctx)
    fn _ -> %{"slug" => skill.slug} end
  end

  defp args_for("skill.list", ctx) do
    skill!(ctx)
    fn _ -> %{} end
  end

  defp args_for("suite_run", _ctx), do: fn _ -> %{"script" => "[1 + 1, suite === burrow]"} end
  defp args_for("suite_run_describe", _ctx), do: fn _ -> %{"tools" => ["skill_list"]} end

  defp args_for("skill.upsert", _ctx) do
    fn turn ->
      %{"name" => "Alias skill #{turn}", "content" => "# #{turn}", "description" => "d"}
    end
  end

  defp prototype!(ctx) do
    published =
      ok!(
        "prototype_publish",
        %{"org_id" => acme_org_id(), "name" => "P", "files" => bundle_files()},
        ctx
      )

    ok!(
      "prototype_publish",
      %{"prototype_id" => published.prototype_id, "files" => bundle_files()},
      ctx
    )

    published
  end

  defp skill!(ctx) do
    ok!(
      "skill_upsert",
      %{
        "name" => "Alias parity skill #{System.unique_integer([:positive])}",
        "content" => "# body"
      },
      ctx
    )
  end

  # ── helpers ───────────────────────────────────────────────────────────

  defp ledger_tools(runtime) do
    Repo.all(
      from(r in ToolCallRecord,
        where: r.runtime_id == ^runtime.runtime_id,
        order_by: [asc: r.inserted_at, asc: r.id],
        select: r.tool
      )
    )
  end

  defp runtime_with!(agent, modules, prefix) do
    runtime =
      %AgentRuntime{}
      |> AgentRuntime.changeset(%{
        runtime_id: "#{prefix}-#{System.unique_integer([:positive])}",
        owner_user_id: root_admin!().id,
        agent_id: agent.id,
        status: "active"
      })
      |> Repo.insert!()

    {:ok, _} =
      RuntimeProfiles.create_for_runtime(
        runtime,
        modules,
        RuntimeProfiles.translated_permissions(modules)
      )

    runtime
  end

  defp shape({:ok, %{} = data}), do: {:ok, data |> Map.keys() |> Enum.sort()}
  defp shape({:error, %{} = data}), do: {:error, data |> Map.keys() |> Enum.sort()}
  defp shape(other), do: other

  defp assert_parity(:equal, legacy, canonical), do: assert(legacy == canonical)

  defp assert_parity(:shape, legacy, canonical),
    do: assert(shape(legacy) == shape(canonical))

  defp mcp(token, method, params) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> post("/mcp", %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params})
    |> json_response(200)
  end

  # ── the table itself ──────────────────────────────────────────────────

  describe "the alias table" do
    test "holds the 19 measured names: 17 dot-to-underscore, 2 suite-to-burrow" do
      assert length(ToolAliases.legacy_names()) == 19
      assert Enum.sort(Map.keys(@parity)) == ToolAliases.legacy_names()

      for {legacy, canonical} <- ToolAliases.aliases() do
        assert canonical == canonical_of(legacy)

        if Map.has_key?(@renamed, legacy) do
          refute String.contains?(legacy, ".")
          assert String.starts_with?(canonical, "burrow_")
        else
          assert String.contains?(legacy, ".")
        end
      end

      assert ToolAliases.aliases() |> Map.take(Map.keys(@renamed)) == @renamed
    end

    test "resolve/1 maps a legacy name and leaves everything else alone" do
      assert ToolAliases.resolve("skill.list") == {:alias, "skill_list"}
      assert ToolAliases.resolve("skill_list") == :canonical
      assert ToolAliases.resolve("skill.lsit") == :canonical
      assert ToolAliases.resolve("canvas_update") == :canonical
      assert ToolAliases.resolve("suite_run") == {:alias, "burrow_run"}
      assert ToolAliases.resolve("suite_run_describe") == {:alias, "burrow_run_describe"}
      assert ToolAliases.resolve("burrow_run") == :canonical
    end
  end

  # ── (a) tools/list lists no dotted name ───────────────────────────────

  describe "tools/list" do
    test "an all-bundle runtime is listed zero dotted names over HTTP", %{token: token} do
      # Positive control: there ARE dotted names to leak.
      assert ToolAliases.legacy_names() != []
      assert Enum.count(ToolAliases.legacy_names(), &String.contains?(&1, ".")) == 17

      names = mcp(token, "tools/list", %{})["result"]["tools"] |> Enum.map(& &1["name"])

      assert "skill_list" in names
      assert "feedback_submit" in names
      assert "burrow_run" in names
      assert "burrow_run_describe" in names
      refute "suite_run" in names
      refute "suite_run_describe" in names
      assert Enum.filter(names, &String.contains?(&1, ".")) == []
      assert Enum.filter(names, &(&1 in ToolAliases.legacy_names())) == []
    end
  end

  # ── (b) parity: one generated test per alias ──────────────────────────

  describe "alias parity through ToolCall.invoke/4" do
    # Generated from `@parity`, this file's own literal list of the 17, NEVER
    # from `ToolAliases.aliases/0`: a test derived from the table under test
    # disappears together with the entry it should catch. (Mutation probe 1
    # of task 01a14a7f stage 3 measured exactly that: with `skill.get`
    # deleted from the table and the loop over `aliases/0`, no parity test
    # failed.)
    for {legacy, _mode} <- Enum.sort(@parity) do
      @legacy legacy
      @canonical Map.get(@renamed, legacy, String.replace(legacy, ".", "_"))

      test "#{legacy} answers as #{Map.get(@renamed, legacy, String.replace(legacy, ".", "_"))}, ledgered and counted as sent",
           ctx do
        args = args_for(@legacy, ctx)
        before = ledger_tools(ctx.runtime)

        Platform.TelemetryHelpers.attach_scoped(
          ToolAliases.legacy_event(),
          {:runtime_id, ctx.runtime.runtime_id},
          self(),
          tag: :legacy
        )

        legacy_result = ToolCall.invoke(@legacy, args.(:legacy), ctx.runtime)
        canonical_result = ToolCall.invoke(@canonical, args.(:canonical), ctx.runtime)

        # The positive control: the canonical call is not refused, so a dotted
        # refusal (what a removed alias produces) cannot compare equal to it.
        refute canonical_result == {:error, :forbidden}
        assert_parity(Map.fetch!(@parity, @legacy), legacy_result, canonical_result)

        assert ledger_tools(ctx.runtime) -- before == [@legacy, @canonical]

        assert_received {:legacy, _event, %{count: 1}, %{legacy: @legacy, canonical: @canonical}}
        refute_received {:legacy, _, _, _}
      end
    end

    test "a dotted name needs its canonical name's grant, never more", %{agent: agent} do
      runtime =
        %AgentRuntime{}
        |> AgentRuntime.changeset(%{
          runtime_id: "alias-narrow-#{System.unique_integer([:positive])}",
          owner_user_id: root_admin!().id,
          agent_id: agent.id,
          status: "active"
        })
        |> Repo.insert!()

      {:ok, _} =
        RuntimeProfiles.create_for_runtime(
          runtime,
          ["task"],
          RuntimeProfiles.translated_permissions(["task"])
        )

      assert {:error, :forbidden} = ToolCall.invoke("skill_list", %{}, runtime)
      assert {:error, :forbidden} = ToolCall.invoke("skill.list", %{}, runtime)
      assert ledger_tools(runtime) == ["skill_list", "skill.list"]
    end

    test "suite_run and suite_run_describe need exactly burrow_run's grant", %{agent: agent} do
      narrow =
        %AgentRuntime{}
        |> AgentRuntime.changeset(%{
          runtime_id: "alias-narrow-cm-#{System.unique_integer([:positive])}",
          owner_user_id: root_admin!().id,
          agent_id: agent.id,
          status: "active"
        })
        |> Repo.insert!()

      {:ok, _} =
        RuntimeProfiles.create_for_runtime(
          narrow,
          ["task"],
          RuntimeProfiles.translated_permissions(["task"])
        )

      for name <- ~w(burrow_run suite_run burrow_run_describe suite_run_describe) do
        assert {:error, :forbidden} = ToolCall.invoke(name, %{"script" => "1"}, narrow)
      end

      assert ledger_tools(narrow) ==
               ~w(burrow_run suite_run burrow_run_describe suite_run_describe)

      # One reason under both names: a refused legacy name reads as the
      # permission miss its canonical name reads as, not as an unknown tool.
      legacy = Platform.Federation.ToolAuthorization.deny_message("suite_run")
      canonical = Platform.Federation.ToolAuthorization.deny_message("burrow_run")
      assert canonical =~ "requires permission"
      assert String.replace(legacy, "suite_run", "burrow_run") == canonical

      # And with the grant, both names call.
      granted = runtime_with!(agent, ["task", "code_mode"], "alias-granted-cm")

      assert {:ok, %{ok: true, result: 1}} =
               ToolCall.invoke("suite_run", %{"script" => "1"}, granted)

      assert {:ok, %{ok: true, result: 1}} =
               ToolCall.invoke("burrow_run", %{"script" => "1"}, granted)
    end

    test "an unknown dotted name is still unknown", %{runtime: runtime} do
      assert {:error, :forbidden} = ToolCall.invoke("skill.lsit", %{}, runtime)

      assert Platform.Federation.ToolAuthorization.deny_message("skill.lsit") =~
               "unknown tool 'skill.lsit'"
    end
  end

  # ── (c) the full-catalogue collision guard ────────────────────────────

  describe "the catalogue" do
    test "with Feedback and an extension: unique after normalising, no dot, aliases sound" do
      FixtureExtension.register()
      names = Enum.map(ToolSurface.tool_definitions(), & &1.name)

      assert "feedback_submit" in names
      assert "fixture_echo" in names

      normalised = Enum.map(names, &Extensions.normalise_tool_name/1)
      assert length(Enum.uniq(normalised)) == length(names)
      assert Enum.filter(names, &String.contains?(&1, ".")) == []

      for {legacy, canonical} <- ToolAliases.aliases() do
        assert canonical in names, "#{legacy} aliases #{canonical}, which is not listed"
        refute legacy in names, "#{legacy} is listed"
      end

      assert Extensions.validate() == :ok
    end

    test "normalise_tool_name/1 reads '.' and '-' as '_'" do
      for name <- ~w(skill_list skill.list skill-list Skill.List) do
        assert Extensions.normalise_tool_name(name) == "skill_list"
      end

      refute Extensions.normalise_tool_name("skilllist") == "skill_list"
    end

    for {mod, name} <- [
          {__MODULE__.UnderscoreClash, "skill_list"},
          {__MODULE__.DottedClash, "skill.list"},
          {__MODULE__.HyphenClash, "skill-list"}
        ] do
      @mod mod
      @name name

      test "an extension declaring #{name} is refused at boot" do
        FixtureExtension.register([@mod])
        assert {:error, messages} = Extensions.validate()
        assert Enum.any?(messages, &(&1 =~ inspect(@name))), inspect(messages)

        assert_raise ArgumentError, fn -> Extensions.validate!() end
      end
    end

    test "two extensions whose names differ only by separator are refused" do
      FixtureExtension.register([__MODULE__.DottedPeer, __MODULE__.UnderscorePeer])
      assert {:error, [message]} = Extensions.validate()
      assert message =~ ~s("peer_tool")
      assert message =~ ~s("peer.tool")
    end
  end

  # ── (e) code mode ─────────────────────────────────────────────────────

  describe "code mode" do
    test "dotted, generic and underscore bindings all call; describe lists no dotted name",
         ctx do
      canvas_id = canvas!(ctx)

      bound = Bindings.tool_names(ctx.runtime)
      assert "canvas.describe" in bound
      assert "canvas_describe" in bound

      script = """
      const a = suite.canvas.describe({canvas_id: '#{canvas_id}'});
      const b = suite.canvas_describe({canvas_id: '#{canvas_id}'});
      const c = suite.call('skill.list', {});
      const d = suite.skill_list({});
      [a.revision === b.revision && a.canvas_id === b.canvas_id, c.total === d.total]
      """

      assert {:ok, %{ok: true, result: [true, true]}} = Run.execute(ctx.runtime, script)

      assert {:ok, index} = ToolCall.invoke("burrow_run_describe", %{}, ctx.runtime)
      text = inspect(index)
      assert text =~ "canvas_describe"
      assert text =~ "burrow_run_describe"

      for legacy <- ToolAliases.legacy_names() do
        # Delimited by anything but an identifier character, so a listed
        # `burrow.suite_run_describe(` would match while `suite_run_calls`
        # (a metric field) would not.
        refute text =~ ~r/(^|[^a-z_])#{Regex.escape(legacy)}($|[^a-z_])/,
               "burrow_run_describe lists #{legacy}"
      end
    end
  end

  # ── extensions used above ─────────────────────────────────────────────

  defmodule ClashBase do
    @moduledoc false
    defmacro __using__({bundle, names}) do
      quote do
        @behaviour Platform.Extension
        def canvas_kinds, do: []

        def mcp_tool_bundles do
          [
            %{
              name: unquote(bundle),
              definitions:
                Enum.map(unquote(names), fn name ->
                  %{
                    name: name,
                    description: "clash",
                    parameters: %{},
                    returns: "",
                    limitations: "",
                    when_to_use: ""
                  }
                end),
              execute: fn _, _, _ -> {:ok, %{}} end
            }
          ]
        end

        def runtime_channel_events, do: []
        def handle_runtime_event(_e, _r, _p), do: :ok
        def runtime_disconnected(_r), do: :ok
        def live_hooks, do: []
        def experiment_surfaces, do: []
        def experiment_metrics, do: %{}
        def migrations_path, do: nil
      end
    end
  end

  defmodule UnderscoreClash do
    @moduledoc false
    use ClashBase, {"clash_underscore", ["skill_list"]}
  end

  defmodule DottedClash do
    @moduledoc false
    use ClashBase, {"clash_dotted", ["skill.list"]}
  end

  defmodule HyphenClash do
    @moduledoc false
    use ClashBase, {"clash_hyphen", ["skill-list"]}
  end

  defmodule DottedPeer do
    @moduledoc false
    use ClashBase, {"peer_dotted", ["peer.tool"]}
  end

  defmodule UnderscorePeer do
    @moduledoc false
    use ClashBase, {"peer_underscore", ["peer_tool"]}
  end
end
