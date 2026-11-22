defmodule Platform.Social.IdeaSelectionSourceTest do
  @moduledoc """
  Source inventories for "Select for research", read as AST (comments and docs
  never count):

    * nothing updates or deletes a `social_idea_selection_events` row, and
      only `Ideas` inserts one;
    * no agent tool definition or handler reaches the selection writers, and
      the registered tool-name list is the one before this feature;
    * the agent list and projection path writes nothing and broadcasts nothing.

  Each scan is shown able to fail on a planted violation (`scan/2` tests).
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../../..", __DIR__)
  @lib Path.join(@root, "apps/*/lib/**/*.ex")
  @social Path.expand("../../../lib/platform", __DIR__)

  @writes ~w(insert insert! insert_all insert_or_update insert_or_update! update update! update_all
             delete delete! delete_all transaction)a

  # ── AST helpers ──────────────────────────────────────────────────────

  defp ast!(path), do: path |> File.read!() |> Code.string_to_quoted!()

  defp calls(ast) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        {{:., _, [mod, fun]}, _, args} = node, acc -> {node, [{mod, fun, args} | acc]}
        node, acc -> {node, acc}
      end)

    acc
  end

  defp mentions?(ast, alias_name) do
    {_, found} =
      Macro.prewalk(ast, false, fn
        {:__aliases__, _, parts} = node, acc -> {node, acc or List.last(parts) == alias_name}
        node, acc -> {node, acc}
      end)

    found
  end

  defp repo?({:__aliases__, _, parts}), do: List.last(parts) == :Repo
  defp repo?(_), do: false

  @doc false
  # Repo write calls whose arguments mention `alias_name`.
  def repo_writes_on(ast, alias_name, funs \\ @writes) do
    for {mod, fun, args} <- calls(ast),
        repo?(mod),
        fun in funs,
        mentions?(args, alias_name),
        do: fun
  end

  @doc false
  # Calls to `names` (remote or local) anywhere in `ast`.
  def calls_to(ast, names) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        {{:., _, [_, fun]}, _, _} = node, acc ->
          {node, if(fun in names, do: [fun | acc], else: acc)}

        {fun, _, args} = node, acc when is_atom(fun) and is_list(args) ->
          {node, if(fun in names, do: [fun | acc], else: acc)}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  # The bodies of the named private/public functions of a module's AST.
  defp function_bodies(ast, names) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        {kind, _, [{:when, _, [{name, _, _} | _]}, body]} = node, acc
        when kind in [:def, :defp] ->
          {node, if(name in names, do: [body | acc], else: acc)}

        {kind, _, [{name, _, _}, body]} = node, acc when kind in [:def, :defp] ->
          {node, if(name in names, do: [body | acc], else: acc)}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp lib_files, do: Path.wildcard(@lib)

  defp files_mentioning(alias_name),
    do: for(f <- lib_files(), mentions?(ast!(f), alias_name), do: Path.relative_to(f, @root))

  defp files_calling(names),
    do: for(f <- lib_files(), calls_to(ast!(f), names) != [], do: Path.relative_to(f, @root))

  # ── The scanners can fail ────────────────────────────────────────────

  describe "scan helpers fire on planted violations" do
    test "repo_writes_on sees update, delete and delete_all on the event schema" do
      for code <- [
            "Repo.update(Ecto.Changeset.change(%IdeaSelectionEvent{}, action: \"x\"))",
            "Repo.delete(%IdeaSelectionEvent{id: 1})",
            "Repo.delete_all(from(e in IdeaSelectionEvent))",
            "Repo.update_all(IdeaSelectionEvent, set: [action: \"x\"])"
          ] do
        assert repo_writes_on(Code.string_to_quoted!(code), :IdeaSelectionEvent) != [], code
      end

      assert repo_writes_on(
               Code.string_to_quoted!("Repo.update(Ecto.Changeset.change(idea))"),
               :IdeaSelectionEvent
             ) == []
    end

    test "calls_to sees remote and local calls and ignores strings" do
      assert calls_to(Code.string_to_quoted!("Ideas.select_for_research(a, b, c)"), [
               :select_for_research
             ]) != []

      assert calls_to(Code.string_to_quoted!("select_for_research(a, b, c)"), [
               :select_for_research
             ]) != []

      assert calls_to(Code.string_to_quoted!(~s|"select_for_research"|), [:select_for_research]) ==
               []
    end
  end

  # ── The event log is append-only ─────────────────────────────────────

  describe "event log" do
    test "no code updates or deletes a selection event" do
      offenders =
        for f <- lib_files(),
            ast = ast!(f),
            (w = repo_writes_on(ast, :IdeaSelectionEvent, @writes -- ~w(insert insert!)a)) != [] do
          {Path.relative_to(f, @root), w}
        end

      assert offenders == []
    end

    test "only Ideas inserts one, and the schema has no changeset" do
      inserters =
        for f <- lib_files(),
            repo_writes_on(ast!(f), :IdeaSelectionEvent, ~w(insert insert! insert_all)a) != [],
            do: Path.relative_to(f, @root)

      assert inserters == ["apps/social/lib/platform/social/ideas.ex"]

      refute function_bodies(ast!(Path.join(@social, "social/idea_selection_event.ex")), [
               :changeset
             ]) != []
    end
  end

  # ── No agent door ────────────────────────────────────────────────────

  describe "agents cannot select" do
    @writers [:select_for_research, :unselect_for_research]

    test "only the Ideas context and the Ideas page reach the writers" do
      assert Enum.sort(files_calling(@writers)) ==
               Enum.sort([
                 "apps/social/lib/platform/social/ideas.ex",
                 "apps/social/lib/platform_web/live/social_ideas_tab.ex"
               ])
    end

    test "no tool definition, handler or bundle file touches the writers or the event schema" do
      for f <- ~w(tools.ex tool_definitions.ex extension.ex) do
        ast = ast!(Path.join(@social, "social/" <> f))
        assert calls_to(ast, @writers) == [], f
        refute mentions?(ast, :IdeaSelectionEvent), f
      end

      assert Enum.sort(files_mentioning(:IdeaSelectionEvent)) == [
               "apps/social/lib/platform/social/idea_selection_event.ex",
               "apps/social/lib/platform/social/ideas.ex"
             ]
    end

    test "the registered tool names are exactly the ones before this feature" do
      assert Platform.Social.ToolDefinitions.names() ==
               ~w(social_profile_list social_profile_get social_draft_create social_studio_draft_create
                  social_draft_update social_post_list social_results_get social_clip_propose
                  social_clip_submit social_clip_render social_clip_list social_task_request
                  social_clip_job_list social_clip_job_claim social_clip_job_source
                  social_clip_job_progress social_clip_job_complete social_clip_job_fail
                  social_idea_create social_idea_list social_idea_vote social_idea_unvote
                  social_idea_archive social_idea_note_add social_weekly_note_submit
                  social_weekly_note_list)

      defined = Platform.Social.ToolDefinitions.definitions() |> Enum.map(& &1.name)
      assert defined == Platform.Social.ToolDefinitions.names()
      refute Enum.any?(defined, &(&1 =~ ~r/select|research/))
    end
  end

  # ── Agent reads write nothing ────────────────────────────────────────

  describe "the agent list and projection path is read-only" do
    @path_functions [
      :idea_list,
      :idea_json,
      :narrow_idea_json,
      :note_json,
      :narrow_note_json,
      :narrow_stage,
      :valid_board_filter?,
      :board_authority
    ]

    test "tools.ex list/projection functions make no write and no broadcast" do
      bodies = function_bodies(ast!(Path.join(@social, "social/tools.ex")), @path_functions)
      assert length(bodies) >= length(@path_functions)

      for body <- bodies do
        assert for({mod, fun, _} <- calls(body), repo?(mod), fun in @writes, do: fun) == []

        assert calls_to(body, [
                 :broadcast_changed,
                 :broadcast,
                 :select_for_research,
                 :unselect_for_research,
                 :archive,
                 :create,
                 :add
               ]) == []
      end
    end

    test "the readers it calls are read-only too" do
      reads = [
        {"social/idea_votes.ex", [:summaries]},
        {"social/ideas.ex", [:list, :posts_by_idea, :get]},
        {"social/idea_notes.ex", [:list, :list_for_ideas]}
      ]

      for {file, funs} <- reads do
        bodies = function_bodies(ast!(Path.join(@social, file)), funs)
        assert bodies != [], file

        for body <- bodies do
          assert for({mod, fun, _} <- calls(body), repo?(mod), fun in @writes, do: fun) == [],
                 file

          assert calls_to(body, [:broadcast_changed, :broadcast]) == [], file
        end
      end
    end

    test "the read-only scan fires on a planted write" do
      ast = Code.string_to_quoted!("defmodule M do\n def idea_list(a), do: Repo.update!(a)\nend")
      [body] = function_bodies(ast, [:idea_list])
      assert for({mod, fun, _} <- calls(body), repo?(mod), fun in @writes, do: fun) == [:update!]
    end
  end
end
