defmodule Platform.Goals.GoalsTest do
  # Sets the global `:goals, :enabled`, so not async.
  use Platform.DataCase, async: false

  import Platform.GoalsFixtures

  alias Platform.Goals
  alias Platform.Goals.{Goal, Grant}

  setup do
    enable_goals!()
    org_id = org_id!()
    {:ok, org_id: org_id, owner: member!(org_id)}
  end

  defp grant_count(goal),
    do: Repo.aggregate(from(gr in Grant, where: gr.goal_id == ^goal.id), :count)

  describe "the switch" do
    test "every function answers :goals_disabled while off", %{org_id: org_id, owner: owner} do
      goal = goal!(owner, org_id)
      Application.put_env(:goals, :enabled, false)

      disabled = {:error, :goals_disabled}
      assert Goals.create_goal(owner, %{org_id: org_id, title: "x"}) == disabled
      assert Goals.list_goals(owner) == disabled
      assert Goals.get_goal(owner, goal.id) == disabled
      assert Goals.update_goal(owner, goal.id, %{title: "x"}) == disabled
      assert Goals.open_goal(owner, goal.id, {:team, org_id}) == disabled
      assert Goals.close_goal(owner, goal.id, {:team, org_id}) == disabled
      assert Goals.list_audience(owner, goal.id) == disabled
      assert Goals.describe_goals(owner) == disabled
      assert Goals.describe_goal(owner, goal.id) == disabled
      assert Goals.list_audience_options(owner, goal.id) == disabled
    end
  end

  describe "create_goal/2" do
    test "the owner is the actor, kind defaults to personal, and attrs cannot set the owner",
         %{org_id: org_id, owner: owner} do
      someone = user!()

      assert {:ok, goal} =
               Goals.create_goal(owner, %{
                 "org_id" => org_id,
                 "title" => "Read 20 books",
                 "owner_user_id" => someone.id
               })

      assert goal.owner_user_id == owner.id
      assert goal.org_id == org_id
      assert goal.kind == "personal"
    end

    test "an org the user cannot read is refused", %{owner: owner} do
      elsewhere = org_id!()

      assert Goals.create_goal(owner, %{org_id: elsewhere, title: "x"}) ==
               {:error, :org_not_visible}

      assert Goals.create_goal(owner, %{org_id: "nope", title: "x"}) == {:error, :org_not_visible}
      assert Goals.create_goal(owner, %{title: "x"}) == {:error, :org_not_visible}
    end

    test "an agent cannot create a goal", %{org_id: org_id} do
      assert Goals.create_goal(agent!(), %{org_id: org_id, title: "x"}) == {:error, :not_found}
    end

    test "a bad value is a changeset error", %{org_id: org_id, owner: owner} do
      assert {:error, %Ecto.Changeset{}} =
               Goals.create_goal(owner, %{org_id: org_id, title: "x", rhythm: "hourly"})
    end
  end

  describe "list_goals/1" do
    test "newest first, the owner's own", %{org_id: org_id, owner: owner} do
      first = goal!(owner, org_id, %{title: "first"})
      second = goal!(owner, org_id, %{title: "second"})

      assert {:ok, [a, b]} = Goals.list_goals(owner)
      assert [a.id, b.id] == [second.id, first.id]
    end
  end

  describe "update_goal/3" do
    test "the owner changes settings but never owner or org", %{org_id: org_id, owner: owner} do
      goal = goal!(owner, org_id)
      other_org = org_id!()

      assert {:ok, updated} =
               Goals.update_goal(owner, goal.id, %{
                 title: "Ship v2",
                 status: "paused",
                 unit: "users",
                 target_value: 100,
                 rhythm: "weekly",
                 rhythm_weekday: 3,
                 owner_user_id: user!().id,
                 org_id: other_org
               })

      assert updated.title == "Ship v2"
      assert updated.status == "paused"
      assert updated.rhythm_weekday == 3
      assert updated.owner_user_id == owner.id
      assert updated.org_id == org_id
    end

    test "back to personal is refused while an audience exists", %{org_id: org_id, owner: owner} do
      goal = goal!(owner, org_id)
      {:ok, _} = Goals.open_goal(owner, goal.id, {:team, org_id})

      assert Goals.update_goal(owner, goal.id, %{kind: "personal"}) == {:error, :has_audience}

      {:ok, closed} = Goals.close_goal(owner, goal.id, {:team, org_id})
      assert closed.kind == "shared"

      assert {:ok, %Goal{kind: "personal"}} =
               Goals.update_goal(owner, goal.id, %{kind: "personal"})
    end
  end

  describe "open_goal/3 and close_goal/3" do
    test "opening is idempotent and shares a personal goal in the same step",
         %{org_id: org_id, owner: owner} do
      goal = goal!(owner, org_id)
      reader = user!()

      assert {:ok, %Goal{kind: "shared"}} = Goals.open_goal(owner, goal.id, {:user, reader.id})
      assert {:ok, %Goal{kind: "shared"}} = Goals.open_goal(owner, goal.id, {:user, reader.id})
      assert grant_count(goal) == 1

      assert {:ok, [%Grant{audience_type: "user", user_id: user_id, granted_by_user_id: by}]} =
               Goals.list_audience(owner, goal.id)

      assert user_id == reader.id
      assert by == owner.id
    end

    test "a failed open leaves a personal goal personal with no grant",
         %{org_id: org_id, owner: owner} do
      goal = goal!(owner, org_id)

      assert Goals.open_goal(owner, goal.id, {:user, Ecto.UUID.generate()}) ==
               {:error, :audience_not_available}

      assert {:ok, %Goal{kind: "personal"}} = Goals.get_goal(owner, goal.id)
      assert grant_count(goal) == 0
    end

    test "unavailable audiences are refused", %{org_id: org_id, owner: owner} do
      goal = goal!(owner, org_id)
      not_mine_org = org_id!()
      external_org = org_id!()
      join_org!(owner, external_org, external: true)
      not_my_space = space!(org_id)

      for audience <- [
            {:user, owner.id},
            {:user, Ecto.UUID.generate()},
            {:user, "nope"},
            {:team, not_mine_org},
            {:team, external_org},
            {:space, not_my_space.id},
            {:space, Ecto.UUID.generate()},
            {:everyone, org_id},
            :everyone
          ] do
        assert Goals.open_goal(owner, goal.id, audience) == {:error, :audience_not_available},
               "#{inspect(audience)} was opened"
      end

      assert grant_count(goal) == 0
    end

    test "closing an audience that was not open is a no-op", %{org_id: org_id, owner: owner} do
      goal = goal!(owner, org_id)
      reader = user!()
      {:ok, _} = Goals.open_goal(owner, goal.id, {:user, reader.id})

      assert {:ok, %Goal{}} = Goals.close_goal(owner, goal.id, {:team, org_id})
      assert {:ok, %Goal{}} = Goals.close_goal(owner, goal.id, {:user, user!().id})
      assert {:ok, %Goal{}} = Goals.close_goal(owner, goal.id, {:user, "nope"})
      assert grant_count(goal) == 1
    end
  end

  describe "source guard" do
    @lib Path.expand("../../../lib", __DIR__)
    @forbidden [
      "Repo.get(",
      "Repo.get!(",
      "Repo.get_by(",
      "Repo.all(Goal",
      "Repo.all(Stop",
      "Repo.all(Entry",
      "Repo.all(Grant",
      "Repo.all(Reading",
      "Repo.all(WakeUp",
      "Repo.all(GoalClock",
      "Repo.all(Ask",
      "Repo.all(TaskLink",
      "Repo.all(BriefItem",
      "Repo.all(Proposal"
    ]

    defp hits(text), do: Enum.filter(@forbidden, &String.contains?(text, &1))

    test "the scan can hit (positive control)" do
      assert hits("goal = Repo.get(Goal, id)") == ["Repo.get("]

      for schema <-
            ~w(Goal Stop Entry Grant Reading WakeUp GoalClock Ask TaskLink BriefItem Proposal) do
        assert "Repo.all(#{schema}" in hits("Repo.all(#{schema})")
      end
    end

    test "apps/goals/lib has no unscoped read" do
      files = Path.wildcard(Path.join(@lib, "**/*.{ex,exs}"))
      assert Enum.any?(files, &String.ends_with?(&1, "platform/goals.ex")), "no lib files scanned"

      assert Enum.any?(files, &String.ends_with?(&1, "platform/goals/retro_changes.ex")),
             "retro reads must be scanned"

      assert Enum.any?(files, &String.ends_with?(&1, "platform/goals/owner_pace.ex")),
             "pacing reads must be scanned"

      assert Enum.any?(files, &String.ends_with?(&1, "platform/goals/proposals.ex")),
             "proposal reads must be scanned"

      found =
        for file <- files, hit <- hits(File.read!(file)), do: {Path.relative_to(file, @lib), hit}

      assert found == []
    end

    # Task 01a1eb3f: the text scan above misses a by-id read written as a query,
    # `Repo.one(from(p in Proposal, where: p.id == ^id))`, which loads any row whose
    # id the caller holds. This scan reads the AST instead of the text, so line
    # breaks, pipes, the Repo wrapper (`one`, `one!`, `exists?`, `update_all`) and
    # extra keywords (`lock:`, `preload:`) do not hide a hit, and each hit names
    # its enclosing function for a stable allowlist key. It flags
    # `from(x in Schema, ...)` where Schema is a Goals-owned schema named by its
    # alias and `where:` compares `x.id` with a pinned value. A `from` whose source
    # is a call (`visible_proposals(actor)`, `children(actor, Stop, id)`,
    # `rows(...)`) is scoped and is not flagged.
    #
    # Out of scope: by-id loads of CORE schemas (Platform.Agents.Agent,
    # Platform.Accounts.User, Platform.Tasks.Task). They are not Goals rows and
    # Goals does not gate them by actor; task 01a1eb3f lists them as findings.
    @goals_schemas ~w(Goal Stop Entry Grant Reading WakeUp GoalClock Ask AskAnswer TaskLink BriefItem Proposal)a

    @unscoped_by_id_allowed [
      {"platform/goals/proposals.ex", {:fetch_open, 1},
       "the only reader is the operator-only resend_start_signal/1, run by a deployer in a " <>
         "release rpc with no actor"},
      {"platform/goals/proposals.ex", {:lock_live, 1},
       "every caller (confirm_proposal/3, cancel_proposal/2, propose_goal/3) first reads the " <>
         "same id through addressed/2 or get_proposal/2, which are actor-scoped"},
      {"platform/goals/proposals.ex", {:claim, 2},
       "a conditional update of the row confirm_proposal/3 already read through addressed/2 " <>
         "and locked with lock_live/1"},
      {"platform/goals/clock.ex", {:claim, 4},
       "the clock acts with no actor by design; same file is already allowed in the " <>
         "goal-binding scan"},
      {"platform/goals/clock.ex", {:sweep, 1},
       "the clock acts with no actor by design; same file is already allowed in the " <>
         "goal-binding scan"},
      {"platform/goals.ex", {:claim_close, 3},
       "a conditional update of the wake-up close_wake_up/4 and close_retro/3 already read " <>
         "through editable_wake/2, which reads Clock.visible_wakes(actor)"},
      {"platform/goals.ex", {:answer_ask, 4},
       "the query inner-joins subquery(Visibility.visible_goals(actor)), so it is scoped"},
      {"platform/goals/space_updates.ex", {:claim, 4},
       "the update is restricted to gr.goal_id in subquery(visible_goals(coach)), and the " <>
         "grant came from space_grants(coach, goal_id)"}
    ]

    defp by_id_reads(source) do
      {_ast, {_stack, hits}} =
        source
        |> Code.string_to_quoted!()
        |> Macro.traverse({[], []}, &by_id_pre/2, &by_id_post/2)

      Enum.reverse(hits)
    end

    defp by_id_pre({kind, _, [head | _]} = node, {stack, hits}) when kind in [:def, :defp],
      do: {node, {[fun_key(head) | stack], hits}}

    defp by_id_pre(
           {:from, meta, [{:in, _, [{var, _, ctx}, {:__aliases__, _, parts}]}, kw]} = node,
           {stack, hits}
         )
         when is_atom(var) and is_atom(ctx) and is_list(kw) do
      if goals_schema?(parts) and by_id_where?(kw, var),
        do: {node, {stack, [{List.first(stack), meta[:line]} | hits]}},
        else: {node, {stack, hits}}
    end

    defp by_id_pre(node, acc), do: {node, acc}

    defp by_id_post({kind, _, [_ | _]} = node, {[_ | stack], hits}) when kind in [:def, :defp],
      do: {node, {stack, hits}}

    defp by_id_post(node, acc), do: {node, acc}

    defp fun_key({:when, _, [call | _]}), do: fun_key(call)
    defp fun_key({name, _, args}) when is_atom(name), do: {name, length(List.wrap(args))}
    defp fun_key(_head), do: :unknown

    defp goals_schema?([schema]), do: schema in @goals_schemas
    defp goals_schema?([:Platform, :Goals, schema]), do: schema in @goals_schemas
    defp goals_schema?(_parts), do: false

    defp by_id_where?(kw, var) do
      Enum.any?(kw, fn
        {:where, expr} -> id_compare?(expr, var)
        _ -> false
      end)
    end

    defp id_compare?(expr, var) do
      {_expr, found?} =
        Macro.prewalk(expr, false, fn
          {:==, _, [a, b]} = node, acc ->
            {node, acc or (id_field?(a, var) and pinned?(b)) or (id_field?(b, var) and pinned?(a))}

          node, acc ->
            {node, acc}
        end)

      found?
    end

    defp id_field?({{:., _, [{var, _, ctx}, :id]}, _, _}, var) when is_atom(ctx), do: true
    defp id_field?(_ast, _var), do: false

    defp pinned?({:^, _, _}), do: true
    defp pinned?(_ast), do: false

    defp lib_by_id_reads do
      for file <- Path.wildcard(Path.join(@lib, "**/*.{ex,exs}")),
          relative = Path.relative_to(file, @lib),
          {fun, line} <- by_id_reads(File.read!(file)),
          do: {relative, fun, line}
    end

    test "the by-id scan can hit (positive control)" do
      flagged = fn source -> by_id_reads(source) |> Enum.map(&elem(&1, 0)) end

      assert flagged.("def f(id), do: Repo.one(from(p in Proposal, where: p.id == ^id))") ==
               [{:f, 1}]

      assert flagged.("""
             defp g(id) do
               Repo.one(
                 from(p in Proposal,
                   where:
                     p.id == ^id
                 )
               )
             end
             """) == [{:g, 1}]

      assert flagged.("""
             def h(id) do
               from(g in Goal, where: g.id == ^id)
               |> Repo.one()
             end
             """) == [{:h, 1}]

      assert flagged.("def i(id), do: Repo.one(from(p in Proposal, where: ^id == p.id))") ==
               [{:i, 1}]

      assert flagged.("def j(id), do: Repo.one(from(g in Platform.Goals.Goal, where: g.id == ^id))") ==
               [{:j, 1}]

      assert flagged.(
               ~S|def k(id), do: Repo.one(from(p in Proposal, where: p.id == ^id, lock: "FOR UPDATE"))|
             ) == [{:k, 1}]

      assert flagged.("""
             def l(id) when is_binary(id) do
               from p in Stop, where: p.id == ^id
             end
             """) == [{:l, 1}]

      assert flagged.("def m(row), do: from(w in WakeUp, where: w.id == ^row.id and w.x == 1)") ==
               [{:m, 1}]

      for schema <- @goals_schemas do
        assert flagged.("def n(id), do: from(x in #{schema}, where: x.id == ^id)") == [{:n, 1}]
      end

      assert flagged.("""
             defmodule M do
               def outer(id), do: id
               defp inner(id), do: Repo.exists?(from(a in Ask, where: a.id == ^id))
             end
             """) == [{:inner, 1}]

      assert flagged.("def o(actor, id), do: from(p in visible_proposals(actor), where: p.id == ^id)") ==
               []

      assert flagged.("def p(id), do: from(p in Proposal, where: p.goal_id == ^id)") == []
      assert flagged.("def q(id), do: from(a in Agent, where: a.id == ^id)") == []

      assert flagged.("def r(id), do: from(c in GoalClock, join: g in Goal, where: g.id == ^id)") ==
               []

      assert flagged.("def s(id), do: from(row in schema, where: row.id == ^id)") == []
    end

    test "apps/goals/lib has no unscoped by-id read" do
      allowed = MapSet.new(@unscoped_by_id_allowed, fn {file, fun, _} -> {file, fun} end)

      found =
        for {file, fun, line} <- lib_by_id_reads(),
            {file, fun} not in allowed,
            do: "#{file}:#{line} in #{inspect(fun)}"

      assert found == [],
             "unscoped by-id read of a Goals schema; read through an actor-scoped query " <>
               "(visible_*/children/rows) or justify it in @unscoped_by_id_allowed:\n" <>
               Enum.join(found, "\n")
    end

    test "every by-id allowlist entry still matches a read" do
      hits = MapSet.new(lib_by_id_reads(), fn {file, fun, _line} -> {file, fun} end)

      stale =
        for {file, fun, _reason} <- @unscoped_by_id_allowed,
            {file, fun} not in hits,
            do: {file, fun}

      assert stale == [], "allowlist entries that match no read: #{inspect(stale)}"
    end

    test "every by-id allowlist entry carries a reason" do
      for {file, fun, reason} <- @unscoped_by_id_allowed do
        assert is_binary(reason) and String.trim(reason) != "",
               "#{file} #{inspect(fun)} has no reason"
      end
    end

    defp actorless_goal_binding?(text) do
      Regex.match?(~r/\b(?:from|join:?)\s*\(?\s*\w+\s+in\s+(?:Platform\.Goals\.)?Goal\b/, text)
    end

    test "goal binding scan catches a planted query" do
      assert actorless_goal_binding?("from g in Goal, select: g.id")
      assert actorless_goal_binding?("join: g in Platform.Goals.Goal, on: g.id == c.goal_id")
      assert actorless_goal_binding?("join g in Platform.Goals.Goal, on: g.id == c.goal_id")
      refute actorless_goal_binding?("from g in visible_goals(actor), select: g")
    end

    test "only the audited context, visibility, the clock and the space claim bind goals" do
      # The two actor-less queries are Clock.due/2 and SpaceClaim.claimed?/1
      # (Goals 7/8 stage 4), which returns a boolean and nothing else.
      allowed =
        ~w(platform/goals.ex platform/goals/visibility.ex platform/goals/clock.ex platform/goals/space_claim.ex)

      found =
        for file <- Path.wildcard(Path.join(@lib, "**/*.ex")),
            relative = Path.relative_to(file, @lib),
            relative not in allowed,
            actorless_goal_binding?(File.read!(file)),
            do: relative

      assert found == []
    end

    test "the scan reads the Goals 4/8 page reads too" do
      source = File.read!(Path.join(@lib, "platform/goals.ex"))

      for name <- ~w(describe_goals describe_goal list_audience_options),
          do: assert(source =~ "def #{name}(", "#{name} is not in the scanned file")
    end

    test "the scan reads the Goals 7/8 hand-off module and its entry points" do
      assert File.exists?(Path.join(@lib, "platform/goals/handoff.ex"))
      source = File.read!(Path.join(@lib, "platform/goals.ex"))

      for name <- ~w(hand_goal_to_space take_goal_back list_contributors),
          do: assert(source =~ "def #{name}(", "#{name} is not in the scanned file")

      handoff = File.read!(Path.join(@lib, "platform/goals/handoff.ex"))
      assert hits(handoff) == []
      refute actorless_goal_binding?(handoff)
      assert handoff =~ "Visibility.visible_goals(actor)"
    end

    test "the space update module reads through the coach's visible goals" do
      updates = File.read!(Path.join(@lib, "platform/goals/space_updates.ex"))
      assert hits(updates) == []
      refute actorless_goal_binding?(updates)
      assert updates =~ "Visibility.visible_goals(coach)"

      claim = File.read!(Path.join(@lib, "platform/goals/space_claim.ex"))
      assert hits(claim) == []
      assert actorless_goal_binding?(claim)
    end

    # Goals 9 (task 01a1e229): `goals.use` is compared against a person in
    # exactly one place, `Platform.Goals.Visibility.may_use?/1`; extension.ex
    # declares the permission. Moduledoc prose names it without quotes.
    defp permission_literal?(text), do: String.contains?(text, ~s("goals.use"))

    test "the permission scan can hit (positive control)" do
      assert permission_literal?(~S|Platform.Access.can?(scope, "goals.use")|)
      assert permission_literal?(~S|rail: [%{key: :goals, permission: "goals.use"}]|)
      refute permission_literal?("A user without `goals.use` sees no goal.")
      refute permission_literal?("Visibility.may_use?(user)")
    end

    test "the goals.use string appears only in visibility.ex and extension.ex" do
      files = Path.wildcard(Path.join(@lib, "**/*.{ex,exs,heex}"))
      assert Enum.any?(files, &String.ends_with?(&1, "platform_web/live/goals_live.ex"))

      found =
        for file <- files,
            permission_literal?(File.read!(file)),
            do: Path.relative_to(file, @lib)

      assert Enum.sort(found) == ["platform/goals/extension.ex", "platform/goals/visibility.ex"]

      visibility = File.read!(Path.join(@lib, "platform/goals/visibility.ex"))

      assert length(String.split(visibility, ~s("goals.use"))) == 2,
             "visibility.ex must compare the permission exactly once"

      assert visibility =~ ~S|def may_use?(%User{|
    end

    test "Platform.Goals has no arity-0 function but enabled?/0" do
      zero = for {name, 0} <- Platform.Goals.__info__(:functions), do: name
      assert zero == [:enabled?]
    end
  end
end
