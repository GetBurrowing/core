defmodule Platform.Feedback.BrokerServer do
  @moduledoc """
  The hosted half of the feedback broker (task 01a1a6a5 stage 3). Installs
  hold no GitHub credential; their `Platform.Feedback.GithubPublisher.Broker`
  adapter POSTs the sanitized submission here, and this node creates the
  issue with its own GitHub App.

  On only when `config :platform, :feedback_broker_server, enabled: true`
  (`FEEDBACK_BROKER_SERVER=true` in `config/runtime.exs`). Off, every broker
  route is a 404 (`PlatformWeb.Plugs.FeedbackBrokerGate`).

  ## Every caller is hostile

  The endpoint is unauthenticated: the feedback repository is public, so a
  broker credential baked into installs would be public too. So `create/2`
  trusts nothing the caller built:

    * it refuses unless this node runs the GithubApp adapter, so a broker can
      never forward to another broker (a loop);
    * it refuses a `repository` other than `GithubPublisher.repository/0`;
    * it runs `Platform.Feedback.Submission.submit/3` on `params["submission"]`
      ONLY, so the allowlist, redaction, bounds, fencing (the issue is built
      here, from scratch), dedupe and caps all run on this node. Any
      top-level `title`, `body`, `labels` or other key is ignored;
    * it answers only `%{repository, issue_number}` or a bounded error atom.

  The actor is an agent-kind actor whose `agent_id` is a UUIDv5 of the
  client IP (so the per-actor cap is per IP) and whose slug is the caller's
  installation label reduced to a safe charset. The wire's `source` is only
  a display hint (validated to agent | person) that keeps the person footer
  and the person required-field rule.

  ## Shared ledger on the broker host

  The broker host (the install `GithubPublisher.Broker.default_broker_url/0`
  points at) is also an ordinary install, so the broker shares its
  `feedback_submissions` table, and so the installation-wide cap, with that
  install's own agents and people. This is accepted: one table is what makes
  a submission from any install and from the host itself dedupe to one
  issue.
  """

  import Ecto.Query, only: [from: 2]

  alias Platform.Feedback.GithubPublisher
  alias Platform.Feedback.GithubPublisher.GithubApp
  alias Platform.Feedback.Submission
  alias Platform.Feedback.SubmissionRecord
  alias Platform.Repo
  alias Platform.Tasks.RepoRef

  @default_rate_per_hour 30
  # Fixed namespace for the per-IP actor id (a random UUID minted for this).
  @ip_namespace <<0x6B, 0x1F, 0x3C, 0x52, 0x9A, 0x04, 0x4E, 0x8D, 0xB2, 0x67, 0x15, 0xD0, 0x4C,
                  0x9E, 0x21, 0xA3>>
  @fingerprint_format ~r/\A[0-9a-f]{64}\z/

  @doc "True when this node runs the broker (`FEEDBACK_BROKER_SERVER`)."
  @spec enabled?() :: boolean()
  def enabled?, do: server_config()[:enabled] == true

  @doc "Requests per client IP per hour."
  @spec rate_per_hour() :: pos_integer()
  def rate_per_hour do
    case server_config()[:rate_per_hour] do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_rate_per_hour
    end
  end

  @doc """
  Create (or find the duplicate of) the issue for one install's request.

  Returns `{:ok, "created" | "duplicate", %{repository, issue_number}}` or
  `{:error, code}` with a bounded atom.
  """
  @spec create(map(), :inet.ip_address()) ::
          {:ok, String.t(), %{repository: String.t(), issue_number: pos_integer()}}
          | {:error, atom()}
  def create(params, remote_ip) when is_map(params) do
    with :ok <- serving(),
         :ok <- repository(params["repository"]),
         {:ok, submission} <- submission(params["submission"]) do
      label = label(params["installation"])

      actor = %{agent_id: ip_actor_id(remote_ip), slug: label}
      opts = [source: source_hint(submission["source"]), installation: label]

      case Submission.submit(submission, actor, opts) do
        {:ok, %{status: status, issue: %{repository: repo, issue_number: number}}} ->
          {:ok, status, %{repository: repo, issue_number: number}}

        {:error, %{code: code}} when is_atom(code) ->
          {:error, code}

        _ ->
          {:error, :publisher_unavailable}
      end
    end
  end

  def create(_params, _remote_ip), do: {:error, :invalid_arguments}

  @doc """
  The published issue a fingerprint produced, or nil. Answers only when the
  broker is serving; nothing but the bounded identity is returned.
  """
  @spec find(term()) ::
          {:ok, %{repository: String.t(), issue_number: pos_integer()} | nil} | {:error, atom()}
  def find(fingerprint) do
    with :ok <- serving() do
      if is_binary(fingerprint) and Regex.match?(@fingerprint_format, fingerprint) do
        case Repo.one(
               from(r in SubmissionRecord,
                 where: r.fingerprint == ^fingerprint and r.status == "published"
               )
             ) do
          %SubmissionRecord{external_repository: repo, external_issue_number: number} ->
            {:ok, %{repository: repo, issue_number: number}}

          nil ->
            {:ok, nil}
        end
      else
        {:ok, nil}
      end
    end
  end

  @doc false
  # The per-IP actor id: a deterministic UUIDv5 of the address.
  def ip_actor_id(ip) do
    name = ip |> :inet.ntoa() |> to_string()

    <<a::48, _v::4, b::12, _r::2, c::62, _rest::binary>> =
      :crypto.hash(:sha, @ip_namespace <> name)

    Ecto.UUID.cast!(<<a::48, 5::4, b::12, 2::2, c::62>>)
  end

  # ── private ────────────────────────────────────────────────────────────

  defp serving do
    cond do
      not enabled?() -> {:error, :not_found}
      GithubPublisher.adapter() != GithubApp -> {:error, :publisher_not_configured}
      true -> :ok
    end
  end

  defp repository(repo) when is_binary(repo) do
    if RepoRef.same?(repo, GithubPublisher.repository()),
      do: :ok,
      else: {:error, :repository_mismatch}
  end

  defp repository(_), do: {:error, :repository_mismatch}

  defp submission(%{} = submission), do: {:ok, submission}
  defp submission(_), do: {:error, :invalid_arguments}

  defp source_hint(value) when value in ["agent", "person"], do: value
  defp source_hint(_), do: nil

  defp label(value) when is_binary(value) do
    case value |> String.replace(~r/[^A-Za-z0-9._-]/, "") |> String.slice(0, 64) do
      "" -> nil
      clean -> clean
    end
  end

  defp label(_), do: nil

  defp server_config, do: Application.get_env(:platform, :feedback_broker_server, [])
end
