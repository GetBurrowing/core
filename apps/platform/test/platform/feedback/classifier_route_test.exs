defmodule Platform.Feedback.ClassifierRouteTest do
  @moduledoc """
  `Platform.Feedback.ClassifierRoute` (task 01a1e670 stage 1): who decides
  feedback intake, and whether that agent has a model endpoint. The setting
  is the existing `feedback.intake` responsibility override; the role holder
  is never rewritten.

  async: false — reads OLLAMA_BASE_URL and the global role tables.
  """

  use Platform.DataCase, async: false

  alias Platform.Agents.Agent
  alias Platform.Feedback.ClassifierRoute
  alias Platform.Repo
  alias Platform.Roles

  setup do
    saved = System.get_env("OLLAMA_BASE_URL")
    System.delete_env("OLLAMA_BASE_URL")

    on_exit(fn ->
      if saved,
        do: System.put_env("OLLAMA_BASE_URL", saved),
        else: System.delete_env("OLLAMA_BASE_URL")
    end)

    Roles.clear_override("feedback.intake")
    Roles.unassign_role("triage_officer")
    :ok
  end

  defp agent!(attrs) do
    n = System.unique_integer([:positive])

    %Agent{}
    |> Agent.changeset(
      Map.merge(
        %{slug: "classifier-route-#{n}", name: "Route agent #{n}", status: "active"},
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp endpoint_agent!(attrs \\ %{}) do
    agent!(
      Map.merge(
        %{
          kind: "external",
          runtime_type: "external",
          endpoint_kind: "openai_compat",
          base_url: "http://classifier-route-endpoint.example.local/v1",
          model: "classifier-route-model"
        },
        attrs
      )
    )
  end

  test "a native role holder has no endpoint" do
    native = agent!(%{})
    {:ok, _} = Roles.assign_role("triage_officer", native.id)

    assert ClassifierRoute.status() == {:off, :no_endpoint}

    health = ClassifierRoute.health()
    assert health.status == "off"
    assert health.reason == "no_endpoint"
    assert health.agent_name == native.name
    assert health.overridden? == false
  end

  test "override endpoint agent wins over native role holder" do
    native = agent!(%{})
    {:ok, _} = Roles.assign_role("triage_officer", native.id)
    endpoint = endpoint_agent!()

    {:ok, _} = Roles.set_override("feedback.intake", endpoint.id)

    assert ClassifierRoute.status() == :ok
    health = ClassifierRoute.health()
    assert %{status: "ok", reason: nil, overridden?: true} = health
    assert health.agent_name == endpoint.name

    # The role stays with its holder: only the override row routes the work.
    assert Roles.agent_id_for_role("triage_officer") == native.id
  end

  test "nobody holding the responsibility is no_assignee" do
    assert ClassifierRoute.status() == {:off, :no_assignee}

    assert %{status: "off", reason: "no_assignee", agent_name: nil, exhausted: 0} =
             ClassifierRoute.health()
  end

  test "health carries exactly the bounded keys and counts pending records" do
    assert ClassifierRoute.health() |> Map.keys() |> Enum.sort() ==
             Enum.sort([:status, :reason, :agent_name, :overridden?, :pending, :exhausted])

    before = ClassifierRoute.health().pending

    Repo.insert!(%Platform.Feedback.IntakeRecord{
      repository_identity: "GetBurrowing/core",
      issue_number: System.unique_integer([:positive]),
      status: "pending",
      note: "no_endpoint",
      last_delivered_at: DateTime.utc_now()
    })

    assert ClassifierRoute.health().pending == before + 1
  end

  test "health never carries the agent's base_url, model or vault_key" do
    n = System.unique_integer([:positive])

    agent =
      endpoint_agent!(%{
        base_url: "http://c5-base-url-#{n}.example.local/v1",
        model: "c5-model-#{n}",
        vault_key: "c5-vault-key-#{n}"
      })

    {:ok, _} = Roles.set_override("feedback.intake", agent.id)

    rendered = inspect(ClassifierRoute.health())
    assert rendered =~ agent.name
    refute rendered =~ agent.base_url
    refute rendered =~ agent.model
    refute rendered =~ agent.vault_key
  end
end
