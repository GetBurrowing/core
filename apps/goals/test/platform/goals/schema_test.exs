defmodule Platform.Goals.SchemaTest do
  use Platform.DataCase, async: true

  alias Platform.Goals.{Entry, Goal, Grant, Stop}
  alias Platform.Repo

  defp unique, do: System.unique_integer([:positive])

  defp org_id!, do: Platform.TenancyFixtures.tenant_org_id("goals-org-#{unique()}")

  defp user! do
    n = unique()

    %Platform.Accounts.User{}
    |> Platform.Accounts.User.changeset(%{
      email: "goals-user-#{n}@example.com",
      name: "Goals User #{n}",
      oidc_sub: "goals-user-#{n}"
    })
    |> Repo.insert!()
  end

  defp agent! do
    n = unique()
    Repo.insert!(%Platform.Agents.Agent{slug: "goals-agent-#{n}", name: "Goals Agent #{n}"})
  end

  defp space!(org_id) do
    n = unique()

    {:ok, space} =
      Platform.Chat.create_space(%{
        name: "Goals chan #{n}",
        slug: "goals-chan-#{n}",
        kind: "channel",
        org_id: org_id
      })

    space
  end

  defp goal!(attrs \\ %{}) do
    org_id = Map.get_lazy(attrs, :org_id, &org_id!/0)
    owner = Map.get_lazy(attrs, :owner, &user!/0)

    %Goal{org_id: org_id, owner_user_id: owner.id}
    |> Goal.changeset(Map.merge(%{title: "Run a 10k"}, Map.drop(attrs, [:org_id, :owner])))
    |> Repo.insert!()
  end

  defp grant(goal, attrs) do
    %Grant{goal_id: goal.id}
    |> Grant.changeset(attrs)
    |> Repo.insert()
  end

  # Goals 5/8: a takeaway needs a title and a named source.
  defp kind_attrs("takeaway"),
    do: %{kind: "takeaway", title: "A finding", sources: [%{"name" => "A source"}]}

  defp kind_attrs(kind), do: %{kind: kind}

  defp entry_changeset(goal, attrs) do
    %Entry{goal_id: goal.id, author_type: "user"}
    |> Entry.changeset(Map.merge(%{kind: "action", occurred_at: DateTime.utc_now()}, attrs))
  end

  # A raw change with only the constraint names, skipping the changeset's
  # validations, so the DATABASE's CHECK is what refuses the value.
  defp db_refuses(struct, schema, changes) do
    {:error, cs} =
      struct |> Ecto.Changeset.change(changes) |> schema.name_constraints() |> Repo.insert()

    cs
  end

  describe "goals" do
    test "defaults and a goal with no number" do
      goal = goal!()
      assert goal.kind == "personal"
      assert goal.status == "active"
      assert goal.agent_mode == "advise"
      assert goal.rhythm == "weekly"
      assert goal.outreach == "gentle"
      assert goal.source_settings == %{}
      assert goal.unit == nil and goal.target_value == nil

      reloaded = Repo.get!(Goal, goal.id)
      assert reloaded.kind == "personal" and reloaded.outreach == "gentle"
    end

    test "every in-list value is accepted" do
      for kind <- ~w(personal shared),
          status <- ~w(active paused finished),
          mode <- ~w(do advise coach) do
        assert %Goal{} = goal!(%{kind: kind, status: status, agent_mode: mode})
      end

      for rhythm <- ~w(daily weekdays weekly biweekly), outreach <- ~w(off gentle pushy) do
        assert %Goal{} = goal!(%{rhythm: rhythm, outreach: outreach, rhythm_weekday: 1})
      end

      assert %Goal{} = goal!(%{rhythm_weekday: 7})
    end

    test "each checked column refuses an out-of-list value as a changeset error" do
      org_id = org_id!()
      owner = user!()

      for {field, bad} <- [
            kind: "public",
            status: "done",
            agent_mode: "nag",
            rhythm: "monthly",
            outreach: "loud",
            rhythm_weekday: 0,
            rhythm_weekday: 8
          ] do
        assert {:error, cs} =
                 %Goal{org_id: org_id, owner_user_id: owner.id}
                 |> Goal.changeset(Map.put(%{title: "x"}, field, bad))
                 |> Repo.insert()

        assert Keyword.has_key?(cs.errors, field), "#{field}=#{inspect(bad)} was accepted"
      end
    end

    test "the database CHECK on each column refuses an out-of-list value, named" do
      org_id = org_id!()
      owner = user!()
      base = %Goal{org_id: org_id, owner_user_id: owner.id, title: "x"}

      for {field, bad, name} <- [
            {:kind, "public", "goals_kind_check"},
            {:status, "done", "goals_status_check"},
            {:agent_mode, "nag", "goals_agent_mode_check"},
            {:rhythm, "monthly", "goals_rhythm_check"},
            {:outreach, "loud", "goals_outreach_check"},
            {:rhythm_weekday, 8, "goals_rhythm_weekday_check"}
          ] do
        cs = db_refuses(base, Goal, [{field, bad}])
        assert {_, opts} = cs.errors[field], "#{field}=#{inspect(bad)} reached the table"
        assert opts[:constraint] == :check
        assert opts[:constraint_name] == name
      end
    end

    test "owner_user_id and org_id are never cast from attrs" do
      goal = goal!()
      other = user!()

      cs = Goal.changeset(goal, %{owner_user_id: other.id, org_id: org_id!(), title: "renamed"})
      refute Map.has_key?(cs.changes, :owner_user_id)
      refute Map.has_key?(cs.changes, :org_id)
      assert cs.changes.title == "renamed"

      refute %Goal{} |> Goal.changeset(%{title: "x", owner_user_id: other.id}) |> Map.get(:valid?)
    end

    test "deleting a goal removes its stops, grants and entries" do
      goal = goal!()

      stop =
        %Stop{goal_id: goal.id}
        |> Stop.changeset(%{position: 1, label: "5k", criteria: [%{"text" => "run 5k"}]})
        |> Repo.insert!()

      {:ok, grant} = grant(goal, %{audience_type: "user", user_id: user!().id})
      entry = goal |> entry_changeset(%{stop_id: stop.id}) |> Repo.insert!()

      Repo.delete!(goal)

      assert Repo.get(Stop, stop.id) == nil
      assert Repo.get(Grant, grant.id) == nil
      assert Repo.get(Entry, entry.id) == nil
    end
  end

  describe "goal_stops" do
    test "the same position twice on one goal is refused by the unique index" do
      goal = goal!()
      attrs = %{position: 1, label: "first"}
      assert {:ok, _} = %Stop{goal_id: goal.id} |> Stop.changeset(attrs) |> Repo.insert()

      assert {:error, cs} = %Stop{goal_id: goal.id} |> Stop.changeset(attrs) |> Repo.insert()
      assert {_, opts} = cs.errors[:position]
      assert opts[:constraint] == :unique

      other = goal!()
      assert {:ok, _} = %Stop{goal_id: other.id} |> Stop.changeset(attrs) |> Repo.insert()
    end
  end

  describe "goal_grants" do
    test "one of each audience is accepted" do
      org_id = org_id!()
      goal = goal!(%{org_id: org_id})

      assert {:ok, %Grant{}} = grant(goal, %{audience_type: "user", user_id: user!().id})
      assert {:ok, %Grant{}} = grant(goal, %{audience_type: "team", org_id: org_id})
      assert {:ok, %Grant{}} = grant(goal, %{audience_type: "space", space_id: space!(org_id).id})
    end

    test "an unknown audience type is refused, by the changeset and by the CHECK" do
      goal = goal!()
      user = user!()

      assert {:error, cs} = grant(goal, %{audience_type: "everyone", user_id: user.id})
      assert Keyword.has_key?(cs.errors, :audience_type)

      cs =
        db_refuses(%Grant{goal_id: goal.id}, Grant, audience_type: "everyone", user_id: user.id)

      assert {_, opts} = cs.errors[:audience_type]
      assert opts[:constraint] == :check
    end

    test "two audience columns set, or a column not matching audience_type, is refused" do
      org_id = org_id!()
      goal = goal!(%{org_id: org_id})
      user = user!()

      for attrs <- [
            %{audience_type: "user", user_id: user.id, org_id: org_id},
            %{audience_type: "team", org_id: org_id, user_id: user.id},
            %{audience_type: "user", org_id: org_id},
            %{audience_type: "space", user_id: user.id},
            %{audience_type: "team"}
          ] do
        assert {:error, cs} = grant(goal, attrs), "#{inspect(attrs)} was accepted"
        assert Keyword.has_key?(cs.errors, :audience_type)

        # And the database refuses the same row on its own.
        cs = db_refuses(%Grant{goal_id: goal.id}, Grant, Map.to_list(attrs))
        assert {_, opts} = cs.errors[:audience_type], "#{inspect(attrs)} reached the table"
        assert opts[:constraint_name] == "goal_grants_one_audience"
      end
    end

    test "the same audience twice on one goal is refused by the unique index" do
      org_id = org_id!()
      goal = goal!(%{org_id: org_id})
      user = user!()
      space = space!(org_id)

      for {attrs, field} <- [
            {%{audience_type: "user", user_id: user.id}, :user_id},
            {%{audience_type: "team", org_id: org_id}, :org_id},
            {%{audience_type: "space", space_id: space.id}, :space_id}
          ] do
        assert {:ok, _} = grant(goal, attrs)
        assert {:error, cs} = grant(goal, attrs)
        assert {_, opts} = cs.errors[field], "a second #{field} grant was accepted"
        assert opts[:constraint] == :unique
      end

      # The same audience on another goal is fine.
      assert {:ok, _} = grant(goal!(), %{audience_type: "user", user_id: user.id})
    end

    test "granted_by_user_id is never cast" do
      goal = goal!()
      cs = Grant.changeset(%Grant{goal_id: goal.id}, %{granted_by_user_id: user!().id})
      refute Map.has_key?(cs.changes, :granted_by_user_id)
    end
  end

  describe "goal_entries" do
    test "every kind and author type is accepted, with a prediction and sources" do
      goal = goal!()

      for kind <- ~w(wake_up action ask wait takeaway retro) do
        assert {:ok, %Entry{}} = goal |> entry_changeset(kind_attrs(kind)) |> Repo.insert()
      end

      agent = agent!()

      assert {:ok, entry} =
               %Entry{goal_id: goal.id, author_type: "agent", author_agent_id: agent.id}
               |> Entry.changeset(%{
                 kind: "action",
                 occurred_at: DateTime.utc_now(),
                 prediction: "expect subscribers to move by 40 within 2 weeks",
                 predicted_change: Decimal.new(40),
                 predicted_by: ~D[2026-12-01],
                 sources: [%{"name" => "YouTube Studio", "url" => "https://example.com"}]
               })
               |> Repo.insert()

      assert Repo.get!(Entry, entry.id).sources == [
               %{"name" => "YouTube Studio", "url" => "https://example.com"}
             ]
    end

    test "kind and author_type refuse an out-of-list value, by changeset and by CHECK" do
      goal = goal!()

      assert {:error, cs} = goal |> entry_changeset(%{kind: "note"}) |> Repo.insert()
      assert Keyword.has_key?(cs.errors, :kind)

      assert {:error, cs} =
               %Entry{goal_id: goal.id, author_type: "robot"}
               |> Entry.changeset(%{kind: "action", occurred_at: DateTime.utc_now()})
               |> Repo.insert()

      assert Keyword.has_key?(cs.errors, :author_type)

      now = DateTime.utc_now()

      for {field, bad, name} <- [
            {:kind, "note", "goal_entries_kind_check"},
            {:author_type, "robot", "goal_entries_author_type_check"}
          ] do
        changes =
          Keyword.merge([kind: "action", author_type: "user", occurred_at: now], [{field, bad}])

        cs = db_refuses(%Entry{goal_id: goal.id}, Entry, changes)
        assert {_, opts} = cs.errors[field]
        assert opts[:constraint_name] == name
      end
    end

    test "the author fields are never cast from attrs" do
      goal = goal!()
      user = user!()

      cs =
        Entry.changeset(%Entry{goal_id: goal.id}, %{
          kind: "action",
          occurred_at: DateTime.utc_now(),
          author_type: "user",
          author_user_id: user.id,
          author_agent_id: agent!().id
        })

      refute Map.has_key?(cs.changes, :author_type)
      refute Map.has_key?(cs.changes, :author_user_id)
      refute Map.has_key?(cs.changes, :author_agent_id)
      refute cs.valid?
    end

    test "a takeaway link and a stop link are nilified when their target goes" do
      goal = goal!()

      stop =
        %Stop{goal_id: goal.id} |> Stop.changeset(%{position: 1, label: "s"}) |> Repo.insert!()

      takeaway = goal |> entry_changeset(kind_attrs("takeaway")) |> Repo.insert!()

      entry =
        goal
        |> entry_changeset(%{kind: "retro", takeaway_id: takeaway.id, stop_id: stop.id})
        |> Repo.insert!()

      Repo.delete!(takeaway)
      Repo.delete!(stop)

      reloaded = Repo.get!(Entry, entry.id)
      assert reloaded.takeaway_id == nil
      assert reloaded.stop_id == nil
    end
  end
end
