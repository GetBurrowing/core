defmodule Platform.Memory.Insights.DigestTest do
  @moduledoc """
  Task 01a13867 stage 3: who gets which insight in the daily digest.

  Every refusal has a positive control on the same fixture (the same insight
  IS selected once the blocking condition is removed), so a test cannot pass
  because the digest selects nothing at all.

  Mutation probes: (a) `Tier.classify/1` -> `:reversible` turns "a
  needs_call insight is never delivered for execution" red; (b) dropping the
  opt-out filter turns "an opted-out user receives nothing" red.

  Task 01a15587 stage 3 probe (a): ignoring `settings.apply_page_edits`
  (always selecting page_edit) turns "page_edit and task are selected only
  when their toggle is on" red.
  """

  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.InsightFixtures

  alias Platform.Accounts
  alias Platform.Experiments
  alias Platform.Experiments.Experiment
  alias Platform.Experiments.Variant
  alias Platform.Memory.Insight
  alias Platform.Memory.Insights.Digest
  alias Platform.Repo

  setup do
    enable_dissemination!()
    :ok
  end

  defp ids(digest, user), do: digest |> Map.get(user.id, []) |> Enum.map(& &1.id)

  test "an opted-out user receives nothing and the insight stays open" do
    person = person!()
    insight = insight!(addressee: person)

    # Positive control: before opting out, the insight is selected.
    assert ids(Digest.select(), person) == [insight.id]

    {:ok, _} = Accounts.update_user_preference(person.id, "insight_delivery_opt_out", true)
    assert Accounts.insight_delivery_opted_out?(person.id)

    digest = Digest.select()
    refute Map.has_key?(digest, person.id)

    assert %Insight{state: "open", delivered_at: nil} = Repo.get!(Insight, insight.id)
  end

  describe "confidence against the run's arm" do
    test "a medium-confidence insight is not delivered under the control arm" do
      person = person!()
      # disseminable is forced true so the digest's own confidence check is
      # what is tested, not the ingest-time flag.
      medium = insight!(addressee: person, confidence: "medium")
      high = insight!(addressee: person, confidence: "high")

      assert ids(Digest.select(), person) == [high.id]
      refute medium.id in ids(Digest.select(), person)
    end

    test "an arm with min_confidence medium delivers it" do
      running_experiment!(%{"directive" => nil, "min_confidence" => "medium"})
      person = person!()
      medium = insight!(addressee: person, confidence: "medium")
      low = insight!(addressee: person, confidence: "low")

      assert ids(Digest.select(), person) == [medium.id]
      refute low.id in ids(Digest.select(), person)
    end
  end

  test "a needs_call insight is never delivered for execution" do
    admin = person!("admin")
    guest = person!("member", external: true)
    member = person!()

    # Addressed to an external user: Tier re-checks it as needs_call.
    call = insight!(addressee: guest, action_type: "question", body: "Can you renew the cert?")
    # Positive control on the same digest: a reversible one IS delivered.
    ok = insight!(addressee: member)

    digest = Digest.select()

    refute Map.has_key?(digest, guest.id)
    assert ids(digest, member) == [ok.id]

    assert [%Insight{id: id, tier: "needs_call"}] =
             Enum.filter(Map.fetch!(digest, admin.id), &(&1.id == call.id))

    assert id == call.id

    # Only root admins see it, and always as needs_call (never executable).
    holders = for {user_id, list} <- digest, i <- list, i.id == call.id, do: {user_id, i.tier}
    admins = Digest.root_admin_ids()
    assert holders != []

    for {user_id, tier} <- holders do
      assert user_id in admins
      assert tier == "needs_call"
    end
  end

  test "legacy rows are never selected" do
    person = person!()
    legacy = insight!(addressee: person, origin: "legacy_proposal", disseminable: false)
    fresh = insight!(addressee: person)

    assert ids(Digest.select(), person) == [fresh.id]
    refute legacy.id in ids(Digest.select(), person)
  end

  test "nothing is selected while dissemination is off" do
    person = person!()
    insight!(addressee: person)
    assert Map.has_key?(Digest.select(), person.id)

    enable_dissemination!(%{dissemination_enabled: false})
    assert Digest.select() == %{}
  end

  test "a question is not delivered twice to the same person" do
    person = person!()
    first = insight!(addressee: person, action_type: "question", body: "Who owns the bucket?")
    insight!(addressee: person, action_type: "question", body: "  who owns the   BUCKET ")

    assert ids(Digest.select(), person) == [first.id]

    # Once the first is delivered, a third copy is a duplicate of an open
    # question already in front of them.
    {:ok, _} = Platform.Memory.Insights.mark_delivered(first)
    insight!(addressee: person, action_type: "question", body: "Who owns the bucket")
    assert ids(Digest.select(), person) == []
  end

  describe "page_edit and task (task 01a15587 stage 3)" do
    # A reversible page_edit (its target page exists and the hunk applies)
    # and a task, both authored by the dreaming agent.
    defp unattended_pair!(person, dreamer, attrs \\ %{}) do
      key = "org/page/digest-#{System.unique_integer([:positive])}.md"
      {:ok, _} = Platform.Org.Wiki.upsert_page(key, %{content: "Deploys go to host-a."})

      edit =
        insight!(
          Map.merge(
            %{
              addressee: person,
              action_type: "page_edit",
              authored_by: dreamer.id,
              action: %{"target" => key, "hunks" => [%{"old" => "host-a", "new" => "host-b"}]}
            },
            attrs
          )
        )

      task =
        insight!(
          Map.merge(
            %{
              addressee: person,
              action_type: "task",
              authored_by: dreamer.id,
              action: %{"target" => Ecto.UUID.generate()}
            },
            attrs
          )
        )

      assert Platform.Memory.Insights.Tier.classify(edit) == :reversible
      assert Platform.Memory.Insights.Tier.classify(task) == :reversible
      {edit, task}
    end

    test "page_edit and task are selected only when their toggle is on" do
      dreamer = dreaming_agent!()
      person = person!()
      briefing = insight!(addressee: person)
      {edit, task} = unattended_pair!(person, dreamer)

      # Both toggles off (the shipped default): only the briefing.
      assert ids(Digest.select(), person) == [briefing.id]

      enable_dissemination!(%{apply_page_edits: true})
      assert Enum.sort(ids(Digest.select(), person)) == Enum.sort([briefing.id, edit.id])

      enable_dissemination!(%{apply_page_edits: false, file_tasks: true})
      assert Enum.sort(ids(Digest.select(), person)) == Enum.sort([briefing.id, task.id])

      enable_dissemination!(%{apply_page_edits: true, file_tasks: true})
      assert Enum.sort(ids(Digest.select(), person)) == Enum.sort([briefing.id, edit.id, task.id])

      # Selection writes nothing.
      for i <- [edit, task] do
        assert %Insight{state: "open", delivered_at: nil, acted_by: nil} =
                 Repo.get!(Insight, i.id)
      end
    end

    test "with dissemination off nothing is selected even with both toggles on" do
      dreamer = dreaming_agent!()
      person = person!()
      {edit, task} = unattended_pair!(person, dreamer)

      enable_dissemination!(%{apply_page_edits: true, file_tasks: true})
      assert Enum.sort(ids(Digest.select(), person)) == Enum.sort([edit.id, task.id])

      enable_dissemination!(%{dissemination_enabled: false})
      assert Digest.select() == %{}
    end

    test "a low-confidence page_edit is not selected under the control arm" do
      enable_dissemination!(%{apply_page_edits: true, file_tasks: true})
      dreamer = dreaming_agent!()
      person = person!()

      {low_edit, low_task} = unattended_pair!(person, dreamer, %{confidence: "low"})
      # The control's auto_apply_min_confidence is medium, below the
      # briefing's high: a medium page_edit and task ARE selected.
      {medium_edit, medium_task} = unattended_pair!(person, dreamer, %{confidence: "medium"})
      medium_briefing = insight!(addressee: person, confidence: "medium")

      selected = ids(Digest.select(), person)
      assert Enum.sort(selected) == Enum.sort([medium_edit.id, medium_task.id])
      refute low_edit.id in selected
      refute low_task.id in selected
      refute medium_briefing.id in selected
    end

    test "a page_edit not authored by the dreaming agent is not selected" do
      enable_dissemination!(%{apply_page_edits: true, file_tasks: true})
      dreamer = dreaming_agent!()
      person = person!()
      {edit, task} = unattended_pair!(person, dreamer, %{authored_by: Ecto.UUID.generate()})
      {ok_edit, ok_task} = unattended_pair!(person, dreamer)

      selected = ids(Digest.select(), person)
      assert Enum.sort(selected) == Enum.sort([ok_edit.id, ok_task.id])
      refute edit.id in selected
      refute task.id in selected
    end

    test "an opted-out addressee gets no page_edit or task" do
      enable_dissemination!(%{apply_page_edits: true, file_tasks: true})
      dreamer = dreaming_agent!()
      person = person!()
      {edit, task} = unattended_pair!(person, dreamer)
      assert Enum.sort(ids(Digest.select(), person)) == Enum.sort([edit.id, task.id])

      {:ok, _} = Accounts.update_user_preference(person.id, "insight_delivery_opt_out", true)
      refute Map.has_key?(Digest.select(), person.id)
    end
  end

  defp running_experiment!(payload) do
    {:ok, experiment} =
      Experiments.create_experiment(%{
        slug: "digest-#{System.unique_integer([:positive])}",
        name: "Insight synthesis",
        surface_key: "memory.insight_synthesis",
        surface_target: "memory.dreaming"
      })

    {:ok, _} =
      Experiments.add_variant(experiment, %{slug: "treatment", payload: payload, weight: 1})

    {:ok, %Experiment{status: "running"} = running} =
      Experiments.start(experiment, Platform.TenancyFixtures.root_admin!())

    Repo.update_all(
      from(v in Variant,
        where: v.experiment_id == ^running.id and v.slug == ^Experiment.control_slug()
      ),
      set: [weight: 0]
    )

    running
  end
end
