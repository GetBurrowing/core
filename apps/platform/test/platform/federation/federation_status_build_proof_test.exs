defmodule Platform.Federation.FederationStatusBuildProofTest do
  @moduledoc """
  `federation_status/0` and the `federation_status` tool report the build a
  runtime is running and the capabilities core has OBSERVED it exercise, as
  facts separate from whether its socket happens to be up right now.

  The originating incident: an agent showed a green dot all evening and could
  not hear a meeting, because its process was running a plugin build without
  the `meeting_transcript` listener. Nothing on any surface said so. Every
  test here pins one of the three statements that would have.

  `async: false` — `RuntimePresence` is a named global Agent shared across the
  node, not sandboxed per test.
  """
  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.Federation
  alias Platform.Federation.RuntimePresence
  alias Platform.Federation.ToolSurface
  alias Platform.Repo

  setup do
    on_exit(fn -> Agent.update(RuntimePresence, fn _ -> %{} end) end)
    :ok
  end

  defp create_user do
    Repo.insert!(%User{
      email: "fedstatus_#{System.unique_integer([:positive])}@example.com",
      name: "Fed Status User",
      oidc_sub: "oidc-fedstatus-#{System.unique_integer([:positive])}"
    })
  end

  # An ACTIVE runtime (federation_status/0 only reports active rows), whose
  # stored `client_info` carries whatever the handshake in stage 1 would have
  # persisted. `build: nil` means "this client never told us".
  defp active_runtime!(prefix, client_info) do
    user = create_user()
    runtime_id = "#{prefix}-#{System.unique_integer([:positive])}"

    {:ok, runtime} = Federation.register_runtime(user.id, %{runtime_id: runtime_id})
    {:ok, runtime, _token} = Federation.activate_runtime(runtime)

    if client_info do
      {:ok, _} = Federation.update_metadata(runtime, %{"client_info" => client_info})
    end

    runtime_id
  end

  defp row_for(runtime_id) do
    Federation.federation_status()
    |> Enum.find(&(&1.runtime_id == runtime_id))
  end

  defp tool_row_for(runtime_id) do
    {:ok, %{runtimes: runtimes}} = ToolSurface.execute("federation_status", %{}, %{})
    Enum.find(runtimes, &(&1.runtime_id == runtime_id))
  end

  describe "two runtimes on different builds are distinguishable in one call" do
    test "the same federation_status call reports each runtime's own build" do
      # The whole ticket in one assertion. Two processes, two builds, ONE
      # call — and the values are compared to EACH OTHER, not to constants.
      # A `client_build/1` that returned any single hardcoded string would
      # satisfy a pair of separate equality assertions against literals and
      # still fail here, because the two rows would agree.
      old = active_runtime!("rt-build-old", %{"build" => "b238164e"})
      new = active_runtime!("rt-build-new", %{"build" => "63229eb"})

      status = Federation.federation_status()

      old_row = Enum.find(status, &(&1.runtime_id == old))
      new_row = Enum.find(status, &(&1.runtime_id == new))

      assert old_row, "the old-build runtime is missing from federation_status/0"
      assert new_row, "the new-build runtime is missing from federation_status/0"

      refute old_row.client_build == new_row.client_build,
             "two runtimes on different builds reported the same build " <>
               "(#{inspect(old_row.client_build)}) — the surface cannot tell them apart, " <>
               "which is the exact defect this ticket exists to fix"

      assert old_row.client_build == "b238164e"
      assert new_row.client_build == "63229eb"
    end

    test "the federation_status TOOL keeps the two builds distinct in one response" do
      old = active_runtime!("rt-tool-old", %{"build" => "b238164e"})
      new = active_runtime!("rt-tool-new", %{"build" => "63229eb"})

      {:ok, %{runtimes: runtimes}} = ToolSurface.execute("federation_status", %{}, %{})

      old_row = Enum.find(runtimes, &(&1.runtime_id == old))
      new_row = Enum.find(runtimes, &(&1.runtime_id == new))

      refute old_row.client_build == new_row.client_build,
             "the tool response collapsed two different builds to " <>
               "#{inspect(old_row.client_build)}"

      assert old_row.client_build == "b238164e"
      assert new_row.client_build == "63229eb"
    end
  end

  describe "a runtime that never declared a build" do
    test "reports the literal string \"unknown\", not nil and not a blank" do
      # Pinned as a LITERAL. `nil` would render as an empty cell, which reads
      # as a rendering gap and gets skipped past; "unknown" is a positive
      # statement that core asked and was not told.
      runtime_id = active_runtime!("rt-no-build", %{"features" => ["system_event_prompt"]})

      row = tool_row_for(runtime_id)

      assert row.client_build == "unknown"
      refute row.client_build == nil
      refute row.client_build == ""
      refute row.client_build == "-"
    end

    test "a runtime with no client_info at all also reports \"unknown\"" do
      runtime_id = active_runtime!("rt-legacy", nil)

      assert tool_row_for(runtime_id).client_build == "unknown"
    end

    test "federation_status/0 itself reports nil — \"unknown\" is a rendering decision" do
      # The context layer must not invent a string; the absence stays nil
      # until something renders it. Pins where the substitution happens.
      runtime_id = active_runtime!("rt-nil-build", nil)

      assert row_for(runtime_id).client_build == nil
    end
  end

  describe "a capability core never observed" do
    test "reports the literal string \"never\" for the transcript capability" do
      # THE row that would have ended the originating incident in ten
      # seconds. `meeting_transcript` has no inbound ack frame today, so it
      # is unprovable by construction — and it must still occupy a cell.
      runtime_id = active_runtime!("rt-unproven", %{"build" => "63229eb"})
      RuntimePresence.track(runtime_id)

      row = tool_row_for(runtime_id)

      assert row.proven["meeting_transcript"] == "never"
    end

    test "an unobserved capability is present as a key, not omitted" do
      # Omitting it is the failure mode: a reader sees a short list rather
      # than a gap, and the gap is the information.
      runtime_id = active_runtime!("rt-unproven-keys", %{"build" => "63229eb"})
      RuntimePresence.track(runtime_id)

      row = tool_row_for(runtime_id)

      assert Map.has_key?(row.proven, "meeting_transcript"),
             "the unproven capability vanished from the response instead of reading \"never\""

      for capability <- RuntimePresence.reported_capabilities() do
        assert Map.has_key?(row.proven, capability),
               "#{capability} has no cell in the tool response"
      end
    end

    test "a proven capability reports its timestamp while its neighbours stay \"never\"" do
      # Anti-vacuity: if every cell said "never" unconditionally, the two
      # tests above would pass and the surface would be useless.
      runtime_id = active_runtime!("rt-mixed", %{"build" => "63229eb"})
      RuntimePresence.track(runtime_id)
      RuntimePresence.prove(runtime_id, "chat_reply")

      row = tool_row_for(runtime_id)

      assert row.proven["meeting_transcript"] == "never"
      assert row.proven["meeting_voice"] == "never"

      refute row.proven["chat_reply"] == "never"
      assert {:ok, %DateTime{}, _} = DateTime.from_iso8601(row.proven["chat_reply"])
    end

    test "an observation under a name outside the reported list is still reported" do
      # `reported_capabilities/0` is a floor, not an allowlist. Core saw it,
      # so core says so.
      runtime_id = active_runtime!("rt-extra-proof", %{"build" => "63229eb"})
      RuntimePresence.track(runtime_id)
      RuntimePresence.prove(runtime_id, "some_future_capability")

      row = tool_row_for(runtime_id)

      refute row.proven["some_future_capability"] == "never"
      assert {:ok, %DateTime{}, _} = DateTime.from_iso8601(row.proven["some_future_capability"])
    end
  end

  describe "build and liveness are independent facts" do
    test "an OFFLINE runtime still reports its stored build, with an empty proof set" do
      # The build is a property of the last handshake, read off the DB row.
      # Losing it when the socket drops would mean the one surface that can
      # answer "what code is that box running?" goes blank exactly when
      # someone is debugging why the box is not answering.
      runtime_id = active_runtime!("rt-offline", %{"build" => "b238164e"})
      refute RuntimePresence.online?(runtime_id)

      row = row_for(runtime_id)

      assert row.online == false
      assert row.client_build == "b238164e"
      assert row.proven == %{}

      tool_row = tool_row_for(runtime_id)

      assert tool_row.online == false
      assert tool_row.client_build == "b238164e"
      assert tool_row.proven["meeting_transcript"] == "never"
      assert tool_row.proven["chat_reply"] == "never"
    end

    test "online stays true for a runtime whose build is unknown and whose proofs are empty" do
      # `online` means the socket is live and ONLY that. Folding build age or
      # proof state into it would hide the disagreement this surface exists
      # to expose — a green dot next to "build unknown, transcript never" is
      # the deliverable, not a bug to smooth over.
      runtime_id = active_runtime!("rt-green-and-blind", nil)
      RuntimePresence.track(runtime_id)

      row = tool_row_for(runtime_id)

      assert row.online == true
      assert row.client_build == "unknown"
      assert row.proven["meeting_transcript"] == "never"
    end

    test "a freshly connected runtime can be running a build older than its connection" do
      # "Connected 20 seconds ago, running six-day-old code" — the sentence
      # nobody could read on the night this happened. Process age and
      # connection age are separate fields and must not be derived from each
      # other.
      started_at = DateTime.add(DateTime.utc_now(), -6 * 24 * 3600, :second)

      runtime_id =
        active_runtime!("rt-old-process", %{
          "build" => "b238164e",
          "started_at" => DateTime.to_iso8601(started_at)
        })

      RuntimePresence.track(runtime_id)

      row = row_for(runtime_id)

      assert row.online == true
      assert DateTime.compare(row.process_started_at, row.connected_at) == :lt

      tool_row = tool_row_for(runtime_id)

      assert tool_row.process_started_at == DateTime.to_iso8601(started_at)
      refute tool_row.process_started_at == tool_row.connected_at
    end
  end

  describe "declared_features is carried for provenance, not for verdicts" do
    test "two runtimes either side of the capability boundary declare the same list" do
      # Measured on the real plugin repo: `63229eb` added the
      # `meeting_transcript` listener and `b238164e` lacks it, yet both
      # report `["system_event_prompt"]` and package.json `0.3.0`. This test
      # encodes WHY the features column cannot be read as authoritative: the
      # two rows are identical on `declared_features` and differ only on
      # `client_build`. If this ever goes red because the lists diverge, the
      # reasoning changed, not the code.
      declared = ["system_event_prompt"]

      cannot =
        active_runtime!("rt-decl-cannot", %{"build" => "b238164e", "features" => declared})

      can = active_runtime!("rt-decl-can", %{"build" => "63229eb", "features" => declared})

      cannot_row = tool_row_for(cannot)
      can_row = tool_row_for(can)

      assert cannot_row.declared_features == can_row.declared_features,
             "the fixture no longer models the measured boundary"

      refute cannot_row.client_build == can_row.client_build,
             "client_build must discriminate what declared_features cannot"
    end

    test "declaring a capability does not prove it" do
      # A claim by the process whose competence is in question. The proof
      # cell must not be back-filled from the declaration.
      runtime_id =
        active_runtime!("rt-declares-transcript", %{
          "build" => "63229eb",
          "features" => ["meeting_transcript"]
        })

      RuntimePresence.track(runtime_id)

      row = tool_row_for(runtime_id)

      assert "meeting_transcript" in row.declared_features
      assert row.proven["meeting_transcript"] == "never"
    end
  end
end
