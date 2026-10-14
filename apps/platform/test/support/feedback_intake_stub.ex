defmodule Platform.Test.FeedbackIntakeStub do
  @moduledoc """
  Test doubles for external-feedback intake (task 01a11ec3 stage 3).

    * The module itself is a provider, installed through
      `:feedback_intake_classifier_provider`. Every call sends
      `{:feedback_classifier_called, credentials, messages, opts}` to the
      installing test process and answers with the planted reply fun.
    * `Platform.Test.FeedbackIntakeStub.Disposition` is a disposition adapter,
      installed through `Platform.Feedback.Intake`'s `:disposition_adapter`.
      Every call sends `{:feedback_disposition, disposition, opts}`.

  Application env, not the process dictionary, because intake may run outside
  the test process. Tests using it must be `async: false`.
  """

  @behaviour Platform.Agents.Providers.Provider

  import Ecto.Query

  alias Platform.Agents.Agent
  alias Platform.Repo
  alias Platform.Roles

  @env_key :feedback_intake_stub

  @doc """
  Install the classifier stub (reporting to `self()`, answering with `reply`)
  and the disposition stub, set the feedback policy and disposition mode, and
  restore everything on exit.
  """
  def install!(opts \\ []) do
    reply = Keyword.get(opts, :reply, fn _c, _m, _o -> {:error, :no_reply_planted} end)
    policy = Keyword.get(opts, :policy, "quarantined")
    mode = Keyword.get(opts, :disposition_mode, "comment")

    prev_provider = Application.get_env(:platform, :feedback_intake_classifier_provider)
    prev_policy = Application.get_env(:platform, :feedback_policy)
    prev_intake = Application.get_env(:platform, Platform.Feedback.Intake)

    Application.put_env(:platform, :feedback_intake_classifier_provider, __MODULE__)
    Application.put_env(:platform, :feedback_policy, policy)

    Application.put_env(:platform, Platform.Feedback.Intake,
      disposition_mode: mode,
      disposition_adapter: __MODULE__.Disposition,
      project_id: Keyword.get(opts, :project_id)
    )

    Application.put_env(:platform, @env_key, %{
      pid: self(),
      reply: reply,
      disposition: Keyword.get(opts, :disposition_result, :ok)
    })

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:platform, @env_key)
      restore(:feedback_intake_classifier_provider, prev_provider)
      restore(:feedback_policy, prev_policy)
      restore(Platform.Feedback.Intake, prev_intake)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:platform, key)
  defp restore(key, value), do: Application.put_env(:platform, key, value)

  @doc "Replace the reply fun without reinstalling."
  def reply!(reply) when is_function(reply, 3) do
    env = Application.fetch_env!(:platform, @env_key)
    Application.put_env(:platform, @env_key, %{env | reply: reply})
  end

  @doc "A reply fun answering with `map` encoded as JSON."
  def json(map), do: fn _c, _m, _o -> {:ok, %{content: Jason.encode!(map)}} end

  @doc "A well-formed verdict map, with overrides."
  def verdict(overrides \\ %{}) do
    Map.merge(
      %{
        "verdict" => "accept_bug",
        "reason_code" => "reproducible_defect",
        "summary" => "Board drag and drop loses the card position after reload",
        "confidence" => 0.8,
        "duplicate_of" => nil
      },
      overrides
    )
  end

  @doc "Insert an external agent and pin it to `triage_officer`."
  def classifier_agent! do
    agent =
      %Agent{}
      |> Agent.changeset(%{
        slug: "intake-#{System.unique_integer([:positive])}",
        name: "Intake classifier",
        status: "active",
        kind: "external",
        runtime_type: "external",
        endpoint_kind: "openai_compat",
        base_url: "http://stub.example.local/v1",
        model: "stub-model"
      })
      |> Repo.insert!()

    Roles.unassign_role("triage_officer")
    {:ok, _} = Roles.assign_role("triage_officer", agent.id)
    agent
  end

  @doc "Every task carrying the given external identity (case-insensitive)."
  def external_tasks(repository, number) do
    lowered = String.downcase(repository)

    from(t in Platform.Tasks.Task,
      where:
        fragment("lower(?)", t.external_repository_identity) == ^lowered and
          t.external_issue_number == ^number
    )
    |> Repo.all()
  end

  @impl true
  def chat(credentials, messages, opts) do
    case Application.get_env(:platform, @env_key) do
      %{pid: pid, reply: reply} ->
        send(pid, {:feedback_classifier_called, credentials, messages, opts})
        reply.(credentials, messages, opts)

      nil ->
        {:error, :no_stub_configured}
    end
  end

  @impl true
  def stream(_credentials, _messages, _opts), do: {:error, :not_implemented}

  @impl true
  def models(_credentials), do: {:ok, []}

  @impl true
  def validate_credentials(_credentials), do: :ok

  defmodule Disposition do
    @moduledoc false
    @behaviour Platform.Feedback.Disposition

    @impl true
    def apply_disposition(disposition, opts) do
      case Application.get_env(:platform, :feedback_intake_stub) do
        %{pid: pid, disposition: result} ->
          send(pid, {:feedback_disposition, disposition, opts})
          result

        nil ->
          {:error, :no_stub_configured}
      end
    end
  end
end
