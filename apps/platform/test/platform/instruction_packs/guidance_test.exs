defmodule Platform.InstructionPacks.GuidanceTest do
  use Platform.DataCase, async: false
  import Platform.InstructionPackFixtures
  import Platform.TenancyFixtures
  alias Platform.{Repo, Sharing}
  alias Platform.Agents.NativeAgents
  alias Platform.Federation.AttentionDispatch
  alias Platform.InstructionPacks.{Entry, Guidance, Installer, Manifest, Targets}

  setup do
    owner = root_admin!()

    {:ok, agent, runtime} =
      NativeAgents.create(owner.id, %{name: "Burrow", harness: "claude_code"})

    Guidance.seed()
    {:ok, _} = Sharing.set(:instruction_updates, true, :system)
    {:ok, _} = Sharing.set(:instruction_updates_stopped, false, :system)
    PlatformWeb.Endpoint.subscribe(AttentionDispatch.topic(runtime.runtime_id))
    %{owner: owner, agent: agent, runtime: runtime}
  end

  defp release(version, previous, role, setup) do
    manifest(%{
      "minimum_client_version" => "0.1.0",
      "version" => version,
      "previous_digest" => previous,
      "entries" => [
        %{"type" => "role_prompt", "target" => "burrow", "content" => role},
        %{"type" => "setup_dialogue", "target" => "burrow", "content" => setup}
      ]
    })
    |> envelope()
  end

  defp install(e, roots) do
    {:ok, snapshot} = Installer.consent_snapshot()
    Installer.install(e, roots, snapshot)
  end

  test "signed saved guidance reaches the next actual dispatch without changing native files", %{
    owner: owner,
    agent: agent,
    runtime: runtime
  } do
    original_files = NativeAgents.list_files(agent)
    {one, roots} = release(1, nil, "ROLE_ONE_LITERAL", "GUIDE_ONE_LITERAL")
    assert {:ok, _} = install(one, roots)

    for type <- ["role_prompt", "setup_dialogue"] do
      entry = Repo.get_by!(Entry, type: type, target: "burrow")

      assert {:ok, _} =
               Installer.resolve_conflict(
                 "setup-guide",
                 type,
                 "burrow",
                 :incoming,
                 Entry.conflict_token(entry),
                 owner
               )
    end

    assert :ok =
             AttentionDispatch.broadcast(
               runtime.runtime_id,
               %{signal: %{prompt: "DO ORIGINAL WORK"}},
               agent_id: agent.id,
               source: :task_router
             )

    assert_receive %Phoenix.Socket.Broadcast{
      event: "attention",
      payload: %{signal: %{prompt: first}}
    }

    assert first =~ "GUIDE_ONE_LITERAL"
    assert first =~ "DO ORIGINAL WORK"

    {two, _} =
      release(2, Manifest.digest(one["manifest"]), "ROLE_TWO_LITERAL", "GUIDE_TWO_LITERAL")

    assert {:ok, _} = install(two, roots)
    human_message = %{content: "HUMAN_MESSAGE_UNCHANGED", author_type: "user"}

    payload = %{
      signal: %{reason: :mention},
      message: human_message,
      context: %{org: %{"org/page/identity.md" => "LOCAL_WIKI_UNCHANGED"}}
    }

    assert :ok =
             AttentionDispatch.broadcast(runtime.runtime_id, payload,
               agent_id: "burrow",
               source: :agent_responder
             )

    assert_receive %Phoenix.Socket.Broadcast{event: "attention", payload: delivered}
    assert delivered.message == human_message
    assert delivered.context.org["org/page/identity.md"] == "LOCAL_WIKI_UNCHANGED"
    assert delivered.context.org["instruction-guidance/burrow"] =~ "GUIDE_TWO_LITERAL"
    refute delivered.context.org["instruction-guidance/burrow"] =~ "GUIDE_ONE_LITERAL"
    assert NativeAgents.list_files(agent) == original_files
    assert Platform.Federation.get_runtime_for_agent(agent).desired_state == runtime.desired_state
  end

  test "no-work events stay no-work and unrelated agents receive no guide identity", %{
    owner: owner,
    agent: agent
  } do
    no_work = %{signal: %{reason: :system_event, prompt_status: :no_work}}
    assert Guidance.enrich(no_work, agent) == no_work
    {:ok, other, _} = NativeAgents.create(owner.id, %{name: "Other helper", harness: "codex"})
    task = %{signal: %{prompt: "ORIGINAL_OTHER_WORK"}}
    assert Guidance.enrich(task, other) == task
  end

  test "typed targets resolve real consumed rows and reject ambiguous generic aliases" do
    assert {:ok, {:template, role}} = Targets.resolve("role_prompt", "burrow")
    assert role.slug == "agents.burrow.role.v1"
    assert {:ok, {:template, setup}} = Targets.resolve("setup_dialogue", "burrow")
    assert setup.slug == "agents.burrow.setup.v1"
    assert setup.content =~ "Helping your owner finish setup"

    assert {:error, :reserved_target} =
             Targets.resolve("prompt_template", "agents.burrow.role.v1")

    assert {:error, :missing_target_mapping} =
             Targets.resolve("setup_dialogue", "guessed-welcome")
  end
end
