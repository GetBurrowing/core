defmodule Platform.InstructionPacks.OutcomesTest do
  use Platform.DataCase, async: false
  import Ecto.Query
  alias Platform.InstructionPacks.{Entry, Outcomes, State}
  alias Platform.Sharing.{UsageEvents, UsageReceiver}

  @row %{
    "pack_id" => "setup-guide",
    "selected_version" => 2,
    "effective_versions" => [1, 2],
    "status" => "mixed_or_local",
    "habits_provenance" => "unavailable"
  }

  test "literal allowlist refuses identifiers, text, errors and unknown provenance" do
    assert Outcomes.valid?([@row])

    for key <- ~w(prompt content changelog actor_id space_id agent_id message_id error) do
      refute Outcomes.valid?([Map.put(@row, key, "SENTINEL_PRIVATE_BODY sentinel@example.test")])
    end

    refute Outcomes.valid?([%{@row | "habits_provenance" => "current_version"}])
    refute Outcomes.valid?([%{@row | "effective_versions" => ["SENTINEL"]}])
    refute Outcomes.valid?([%{@row | "pack_id" => "https://evil.invalid"}])
    refute Outcomes.valid?(List.duplicate(@row, 51))
  end

  test "effective inventory uses applied state and detects edits rather than cached releases" do
    Repo.insert!(%State{pack_id: "setup-guide", version: 2, highest_version: 9})

    Repo.insert!(%Entry{
      pack_id: "setup-guide",
      type: "prompt_template",
      target: "missing-template",
      effective_version: 1,
      applied_hash: Entry.hash("vendor")
    })

    assert [
             %{
               "selected_version" => 2,
               "effective_versions" => [],
               "status" => "mixed_or_local",
               "habits_provenance" => "unavailable"
             }
           ] = Outcomes.snapshot()
  end

  test "vendor provenance requires unchanged bytes and the original stored identity" do
    {:ok, skill} = Platform.Skills.create_skill(%{name: "Outcome vendor", content: "vendor"})

    Repo.insert!(%State{
      pack_id: "setup-guide",
      version: 2,
      highest_version: 9,
      pinned_version: 2
    })

    {cached, _roots} =
      Platform.InstructionPackFixtures.envelope(
        Platform.InstructionPackFixtures.manifest(%{
          "version" => 9,
          "previous_digest" => String.duplicate("a", 64)
        })
      )

    Repo.insert!(%Platform.InstructionPacks.RetainedRelease{
      pack_id: "setup-guide",
      version: 9,
      digest: Platform.InstructionPacks.Manifest.digest(cached["manifest"]),
      envelope: Jason.encode!(cached)
    })

    Repo.insert!(%Entry{
      pack_id: "setup-guide",
      type: "skill_markdown",
      target: skill.slug,
      record_id: skill.id,
      effective_version: 2,
      applied_hash: Entry.hash("vendor")
    })

    assert [%{"selected_version" => 2, "effective_versions" => [2], "status" => "vendor"}] =
             Outcomes.snapshot()

    {:ok, changed} = Platform.Skills.update_skill(skill, %{content: "SENTINEL_PRIVATE_BODY"})
    assert [%{"effective_versions" => [], "status" => "mixed_or_local"}] = Outcomes.snapshot()
    {:ok, _} = Platform.Skills.delete_skill(changed)

    {:ok, replacement} =
      Platform.Skills.create_skill(%{name: "Outcome vendor", content: "vendor"})

    refute replacement.id == skill.id
    assert [%{"effective_versions" => [], "status" => "mixed_or_local"}] = Outcomes.snapshot()
  end

  test "common broker batch roundtrips and retries dedupe without private sentinels" do
    body =
      UsageEvents.build_body(Ecto.UUID.generate(), DateTime.utc_now(), 60, %{
        "message.posted" => 1
      })
      |> Map.put("instruction_outcomes", [@row])

    assert UsageEvents.refusal(body) == nil
    assert {:ok, 1} = UsageReceiver.record(body)
    assert {:ok, 1} = UsageReceiver.record(body)
    assert Repo.aggregate(from(o in "sharing_instruction_outcomes"), :count) == 1
    encoded = Jason.encode!(body)

    for sentinel <- [
          "SENTINEL_PRIVATE_BODY",
          "sentinel@example.test",
          "actor_id",
          "space_id",
          "changelog"
        ] do
      refute encoded =~ sentinel
    end

    bad = put_in(body, ["instruction_outcomes", Access.at(0), "content"], "SENTINEL_PRIVATE_BODY")
    assert UsageEvents.refusal(bad) == :unknown_string
    assert {:error, :invalid_usage} = UsageReceiver.record(bad)
  end

  test "download consent does not authorize upload and final broker check drops queued data" do
    alias Platform.Sharing
    alias Platform.Feedback.GithubPublisher.Broker
    parent = self()

    Req.Test.stub(Broker, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(parent, {:wire, raw})
      Req.Test.json(conn, %{})
    end)

    {:ok, _} = Sharing.set(:instruction_updates, true, :system)
    {:ok, _} = Sharing.set(:usage_counts, false, :system)

    body =
      UsageEvents.build_body(Ecto.UUID.generate(), DateTime.utc_now(), 60, %{
        "message.posted" => 1
      })
      |> Map.put("instruction_outcomes", [@row])

    assert {:error, :sharing_disabled} = Broker.post_usage(body)
    refute_receive {:wire, _}
    {:ok, _} = Sharing.set(:usage_counts, true, :system)
    assert :ok = Broker.post_usage(body)
    assert_receive {:wire, raw}
    assert Jason.decode!(raw)["instruction_outcomes"] == [@row]
    {:ok, _} = Sharing.set(:instruction_updates_stopped, true, :system)
    assert {:error, :sharing_disabled} = Broker.post_usage(body)
    refute_receive {:wire, _}
    {:ok, _} = Sharing.set(:instruction_updates_stopped, false, :system)
    {:ok, _} = Sharing.set(:usage_counts, false, :system)
    assert {:error, :sharing_disabled} = Broker.post_usage(body)
    refute_receive {:wire, _}
  end
end
