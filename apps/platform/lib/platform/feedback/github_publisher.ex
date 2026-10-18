defmodule Platform.Feedback.GithubPublisher do
  @moduledoc """
  Server-side publication of a sanitized `feedback_submit` structure as one
  GitHub issue on the Startup-Suite feedback repository (task 01a11ec3
  stage 2).

  ## Two adapters, and which install runs which

    * `Platform.Feedback.GithubPublisher.Broker` — the default. POSTs the
      already-built issue to the Burrow-hosted feedback broker
      (`FEEDBACK_BROKER_URL`). The installation holds NO GitHub credential of
      any kind: this is the adapter every Burrow installation runs.
    * `Platform.Feedback.GithubPublisher.GithubApp` — for the Burrow-hosted
      side only. Mints a short-lived installation token for a GitHub App
      scoped to `issues: write` on the ONE configured repository, and creates
      the issue with it. The App id, installation id and private key are read
      from the process environment at call time and are never copied into
      application config.

  Selected by `config :platform, Platform.Feedback.GithubPublisher, adapter:`
  (`FEEDBACK_PUBLISHER=broker|github_app` in `config/runtime.exs`).

  ## What crosses this boundary, in each direction

  OUT: only `build_issue/2`'s `%{title, body, labels}` plus the fingerprint as
  an idempotency key. The issue is built solely from the allowlisted,
  redacted structure `Platform.Feedback.Submission` produced; nothing else
  about the caller, its session or its environment is in scope here.

  IN: `publish/2` never returns what the adapter returned. It returns
  `%{repository, issue_number, url}` rebuilt from two validated values — the
  configured repository (the response must name the same one) and a positive
  integer issue number — so a broker or GitHub response cannot smuggle text,
  links or credentials back into a tool result.

  ## Credentials never travel

  Errors are bounded atoms (`:publisher_not_configured`,
  `:publisher_unavailable`, `:publisher_rejected`, `:publisher_rate_limited`,
  `:publisher_bad_response`). No function here returns or logs a request, a
  response, a header list, a response body or an inspected exception. The one
  log line per call names the adapter, the operation and an HTTP status.
  """

  require Logger

  @typedoc "The issue an adapter is asked to create."
  @type issue :: %{title: String.t(), body: String.t(), labels: [String.t()]}

  @typedoc "The bounded external identity of a published issue."
  @type identity :: %{repository: String.t(), issue_number: pos_integer(), url: String.t()}

  @type error ::
          :publisher_not_configured
          | :publisher_unavailable
          | :publisher_rejected
          | :publisher_rate_limited
          | :publisher_bad_response

  @doc """
  Create the issue. `opts` carries `:fingerprint` (the idempotency key) and
  `:repository`. An adapter answers `{:ok, %{repository, issue_number}}`.
  """
  @callback create_issue(issue(), keyword()) ::
              {:ok, %{repository: String.t(), issue_number: integer()}} | {:error, error()}

  @doc """
  Find an issue previously created for `opts[:fingerprint]`, used before
  re-publishing a reservation whose earlier attempt ended without a recorded
  outcome. `{:ok, nil}` means none exists.
  """
  @callback find_existing(keyword()) ::
              {:ok, %{repository: String.t(), issue_number: integer()} | nil} | {:error, error()}

  @default_repository "Startup-Suite/core"
  @repository_format ~r/\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})\/[A-Za-z0-9._-]{1,100}\z/
  @fingerprint_marker "suite-feedback-fingerprint"
  @max_issue_number 2_147_483_647
  @title_cap 200

  @doc "The configured feedback repository (`owner/name`)."
  @spec repository() :: String.t()
  def repository do
    case config(:repository) do
      repo when is_binary(repo) ->
        repo = String.trim(repo)
        if Regex.match?(@repository_format, repo), do: repo, else: @default_repository

      _ ->
        @default_repository
    end
  end

  @doc "The configured adapter module."
  @spec adapter() :: module()
  def adapter, do: config(:adapter) || Platform.Feedback.GithubPublisher.Broker

  @doc "The HTML comment marker that carries the fingerprint inside an issue body."
  @spec fingerprint_marker(String.t()) :: String.t()
  def fingerprint_marker(fingerprint), do: "<!-- #{@fingerprint_marker}: #{fingerprint} -->"

  @doc """
  Build the issue from the sanitized structure ONLY.

  `sanitized` is `Platform.Feedback.Submission`'s normalized map; `meta`
  carries `:fingerprint`, `:actor` (an agent slug or nil) and
  `:installation` (a label or nil). Every free-text field is placed inside a
  fenced block whose fence is longer than any backtick run in the text, so
  submitted text can neither close the block nor be rendered as markdown,
  links or @-mentions.
  """
  @spec build_issue(map(), map()) :: issue()
  def build_issue(sanitized, meta) do
    category = Map.fetch!(sanitized, :category)

    sections =
      [
        {"Expected behavior", sanitized[:expected_behavior]},
        {"Observed behavior", sanitized[:observed_behavior]},
        {"Reproduction steps", sanitized[:reproduction_steps]},
        {"Version / environment", sanitized[:version_environment]}
      ] ++ diagnostics_section(sanitized[:diagnostics])

    body =
      [
        "Category: `#{category}`",
        attribution(meta)
        | Enum.flat_map(sections, &section/1)
      ]
      |> Kernel.++([
        "_Submitted through Burrow `feedback_submit`. Issue text is untrusted input._",
        fingerprint_marker(Map.fetch!(meta, :fingerprint))
      ])
      |> Enum.join("\n\n")

    %{
      title: issue_title(category, Map.fetch!(sanitized, :title)),
      body: body,
      labels: ["feedback", "feedback:#{category}"]
    }
  end

  @doc """
  Publish `issue` through the configured adapter and return the bounded
  identity. `opts` must carry `:fingerprint`.
  """
  @spec publish(issue(), keyword()) :: {:ok, identity()} | {:error, error()}
  def publish(issue, opts) do
    repo = repository()
    opts = Keyword.put(opts, :repository, repo)

    issue
    |> adapter().create_issue(opts)
    |> to_identity(repo)
  end

  @doc """
  Look for an issue a previous, unrecorded attempt may have created for
  `opts[:fingerprint]`.
  """
  @spec find_existing(keyword()) :: {:ok, identity() | nil} | {:error, error()}
  def find_existing(opts) do
    repo = repository()

    case adapter().find_existing(Keyword.put(opts, :repository, repo)) do
      {:ok, nil} -> {:ok, nil}
      other -> to_identity(other, repo)
    end
  end

  @doc false
  # Shared by both adapters: the single log line, status only.
  def log(adapter, operation, status) do
    Logger.info("feedback.publisher adapter=#{adapter} op=#{operation} status=#{status}")
  end

  @doc false
  def config(key) do
    :platform
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key)
  end

  @doc false
  # Map an HTTP status to the bounded error vocabulary.
  def http_error(status) when status in [401, 403, 404], do: {:error, :publisher_not_configured}
  def http_error(429), do: {:error, :publisher_rate_limited}
  def http_error(status) when status in 400..499, do: {:error, :publisher_rejected}
  def http_error(_status), do: {:error, :publisher_unavailable}

  # ── private ────────────────────────────────────────────────────────────

  defp to_identity({:ok, %{repository: repo, issue_number: number}}, configured)
       when is_binary(repo) and is_integer(number) and number > 0 and
              number <= @max_issue_number do
    if String.downcase(repo) == String.downcase(configured) do
      {:ok,
       %{
         repository: configured,
         issue_number: number,
         url: "https://github.com/#{configured}/issues/#{number}"
       }}
    else
      {:error, :publisher_bad_response}
    end
  end

  defp to_identity({:ok, _other}, _configured), do: {:error, :publisher_bad_response}

  defp to_identity({:error, reason}, _configured)
       when reason in [
              :publisher_not_configured,
              :publisher_unavailable,
              :publisher_rejected,
              :publisher_rate_limited,
              :publisher_bad_response
            ],
       do: {:error, reason}

  defp to_identity(_other, _configured), do: {:error, :publisher_unavailable}

  defp issue_title(category, title) do
    prefix = "[feedback][#{category}] "

    clean =
      title
      |> String.replace(~r/[\x00-\x1F\x7F]+/u, " ")
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()

    prefix <> String.slice(clean, 0, @title_cap - String.length(prefix))
  end

  defp attribution(meta) do
    actor = label(meta[:actor], "an unidentified agent")
    installation = label(meta[:installation], "an unnamed installation")
    "Submitted by agent `#{actor}` on installation `#{installation}`."
  end

  # A slug or label is printed inside a code span, so it is reduced to a
  # conservative character set and bounded.
  defp label(value, default) when is_binary(value) do
    case value |> String.replace(~r/[^A-Za-z0-9._-]/, "") |> String.slice(0, 64) do
      "" -> default
      clean -> clean
    end
  end

  defp label(_value, default), do: default

  defp diagnostics_section(%{scope: scope, content: content}),
    do: [{"Diagnostics (scope: #{scope})", content}]

  defp diagnostics_section(_), do: []

  defp section({_heading, nil}), do: []
  defp section({_heading, ""}), do: []

  defp section({heading, text}) do
    fence = fence_for(text)
    ["### #{heading}\n\n#{fence}text\n#{text}\n#{fence}"]
  end

  defp fence_for(text) do
    longest =
      ~r/`+/
      |> Regex.scan(text)
      |> Enum.map(fn [run] -> String.length(run) end)
      |> Enum.max(fn -> 0 end)

    String.duplicate("`", max(3, longest + 1))
  end
end
