defmodule Platform.Webhooks.GithubSignature do
  @moduledoc """
  HMAC-SHA256 verification for GitHub webhook deliveries.

  This is the single home for GitHub webhook signature logic, mirroring the
  way `Platform.Meetings.verify_livekit_jwt/2` backs
  `PlatformWeb.Plugs.VerifyLivekitSignature`. The plug layer stays thin: it
  pulls the raw body and headers off the conn and asks this module for a
  verdict.

  GitHub signs the *raw request bytes* with the secret configured on the repo
  hook and sends `X-Hub-Signature-256: sha256=<lowercase hex>`.

  ## Secret resolution — a candidate list, not one secret

  `secrets_for_repo/1` returns an ordered list of candidate secrets:

    1. the project row's `deploy_config["webhook_secret"]`, looked up by exact
       `repo_url` match, and
    2. the app-level fallback `Application.get_env(:platform, :github_webhook_secret)`
       (wired from `GITHUB_WEBHOOK_SECRET` in `config/runtime.exs`).

  Verification succeeds if the delivery matches **any** candidate.

  Why a list rather than a single secret (verified against prod 2026-07-25):
  no `Platform.Tasks.Project` row carries a `webhook_secret` at all, while the
  GitHub repo hook does have a secret set and signs every delivery. Before this
  module, every real delivery took the controller's `is_nil(secret) -> conn`
  bypass. Failing closed on a nil per-project secret alone would kill all
  CI/PR webhook processing in prod, so the app-level fallback is what makes the
  cutover possible with a value that is not stored per project. Accepting
  either candidate also gives secret-rotation headroom — the gap the LiveKit
  runbook calls out as missing for LiveKit.

  ## Attacker-influenced secret selection

  `repo_url` is read out of the webhook payload, which is attacker-controlled,
  so *which* per-project secret gets tried is attacker-influenced. That is
  safe here: no candidate is ever skipped for lack of a match, and a forged
  `repository.html_url` can only widen the candidate list — verification still
  requires actually possessing one of the candidate secrets. An empty
  candidate list fails closed with `:no_secret_configured`.

  Task 019f9b11 stage 1 — GitHub webhook auth-bypass fix.
  """

  import Ecto.Query

  alias Platform.Repo
  alias Platform.Tasks.Project

  @type reason ::
          :missing_signature
          | :malformed_signature
          | :no_secret_configured
          | :signature_mismatch

  @signature_format ~r/\Asha256=[0-9a-fA-F]+\z/

  @doc """
  Verify a GitHub webhook delivery.

  `raw_body` must be the raw request bytes (cached on `conn.assigns[:raw_body]`
  by `PlatformWeb.Plugs.CacheBodyReader`), `signature_header` the raw
  `X-Hub-Signature-256` value, and `repo_url` the payload's
  `repository.html_url` (may be `nil`).
  """
  @spec verify(binary() | nil, binary() | nil, binary() | nil) :: :ok | {:error, reason()}
  def verify(raw_body, signature_header, repo_url) do
    body = raw_body || ""

    cond do
      not is_binary(signature_header) or String.trim(signature_header) == "" ->
        {:error, :missing_signature}

      not Regex.match?(@signature_format, signature_header) ->
        {:error, :malformed_signature}

      true ->
        check_candidates(body, signature_header, secrets_for_repo(repo_url))
    end
  end

  defp check_candidates(_body, _signature, []), do: {:error, :no_secret_configured}

  defp check_candidates(body, signature, secrets) do
    if Enum.any?(secrets, &verify_hmac(body, signature, &1)) do
      :ok
    else
      {:error, :signature_mismatch}
    end
  end

  @doc """
  Constant-time compare of a `sha256=<hex>` header against the HMAC of `body`
  under `secret`.

  Moved verbatim from `PlatformWeb.GithubWebhookController.verify_hmac/3`.
  """
  @spec verify_hmac(binary(), binary(), binary()) :: boolean()
  def verify_hmac(body, signature, secret) do
    # signature format: "sha256=<hex>"
    case String.split(signature, "=", parts: 2) do
      ["sha256", hex_digest] ->
        computed = :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)
        Plug.Crypto.secure_compare(computed, String.downcase(hex_digest))

      _ ->
        false
    end
  end

  @doc """
  Ordered list of candidate secrets for `repo_url`: the per-project secret
  first, then the app-level fallback. Blanks and duplicates are dropped, so an
  unconfigured repo with no env fallback yields `[]`.
  """
  @spec secrets_for_repo(binary() | nil) :: [binary()]
  def secrets_for_repo(repo_url) do
    [project_secret(repo_url), app_secret()]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp app_secret, do: Application.get_env(:platform, :github_webhook_secret)

  defp project_secret(nil), do: nil

  # `repo_url` has no uniqueness constraint (only `projects.slug` does — see
  # `unique_index(:projects, [:slug])`), so two projects can legitimately share
  # one `repo_url`. The old `limit(1) |> Repo.one()` here picked whichever row
  # Postgres happened to return first and quietly verified against THAT
  # project's secret — the same "arbitrary row on a non-unique key" defect
  # `Platform.Vault.get/2` and `delete/2` had on `slug` before this task's
  # stages 1-2, just on a signature-verification path instead of a fetch/delete
  # one. Fail closed instead: with more than one match, no per-project secret
  # is offered to `secrets_for_repo/1` at all, so an ambiguous `repo_url` can
  # still authenticate via the app-level fallback but never via either
  # project's `webhook_secret`.
  defp project_secret(repo_url) when is_binary(repo_url) do
    case Repo.all(from(p in Project, where: p.repo_url == ^repo_url)) do
      [%{deploy_config: %{"webhook_secret" => secret}}] when is_binary(secret) and secret != "" ->
        secret

      _ ->
        nil
    end
  end

  defp project_secret(_), do: nil
end
