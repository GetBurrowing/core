defmodule Platform.Test.SecurityEnrichmentHelper do
  @moduledoc """
  Test helper for wiring an in-process LLM stub through
  `Platform.Security.LlmEnrichment` (task `019f3e8e-4406` v2 stage 3).

  The scanner-facing tests want to assert that findings pass through
  the enrichment seam when an `external`-runtime agent is pinned to
  the scanner's responsibility key — without touching the actual
  Ollama provider. This helper:

    * Installs a stub provider module in Application env for the
      duration of the test (auto-restored `on_exit/1`).
    * Creates an external-runtime agent in the sandbox and pins it
      to the given `responsibility_key` via
      `Roles.set_override/2`.
    * Plants a canned response fun in the process dictionary — the
      stub reads it when the scanner reaches the enrichment call.

  Call `install_llm_stub!/2` in your test's setup to opt in;
  everything else runs synchronously in the same process so the
  process-dictionary read works from any scanner call site.
  """

  alias Platform.Agents.Agent
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Repo
  alias Platform.Roles

  defmodule StubProvider do
    @moduledoc """
    Test-only provider — reads a fun from
    `:security_llm_enrichment_stub_fun` in the calling process's
    dictionary. Since `LlmEnrichment.enrich_finding/2` runs
    synchronously in the scanner's process (which IS the test
    process in ExUnit), the process-dict handoff works.
    """
    @behaviour Platform.Agents.Providers.Provider

    @impl true
    def chat(credentials, messages, opts) do
      Process.put(
        :security_llm_enrichment_call_count,
        (Process.get(:security_llm_enrichment_call_count) || 0) + 1
      )

      Process.put(:security_llm_enrichment_last_messages, messages)

      case Process.get(:security_llm_enrichment_stub_fun) do
        nil -> {:error, :no_stub_configured}
        fun when is_function(fun, 3) -> fun.(credentials, messages, opts)
      end
    end

    @impl true
    def stream(_credentials, _messages, _opts), do: {:error, :not_implemented}

    @impl true
    def models(_credentials), do: {:ok, []}

    @impl true
    def validate_credentials(_credentials), do: :ok
  end

  @doc """
  Install the LLM stub provider + create an external agent + pin it
  to `responsibility_key`. Returns the agent for callers that want
  to reference it. Auto-cleans on_exit.

  Options:
    * `:template_slug` — replace the DB template row for this slug
      with a marker-carrying test copy. Useful when the test wants
      to verify assigns extraction landed in the rendered prompt.
    * `:template_content` — content for the replacement template.
      Only used when `:template_slug` is set.
  """
  def install_llm_stub!(responsibility_key, opts \\ []) do
    prev_provider =
      Application.get_env(:platform, :security_llm_enrichment_provider)

    Application.put_env(
      :platform,
      :security_llm_enrichment_provider,
      StubProvider
    )

    agent =
      %Agent{}
      |> Agent.changeset(%{
        slug: "sec-enrich-#{System.unique_integer([:positive])}",
        name: "Security Enrichment Agent",
        status: "active",
        kind: "external",
        runtime_type: "external",
        endpoint_kind: "openai_compat",
        base_url: "http://stub.example.local/v1",
        model: "stub-model"
      })
      |> Repo.insert!()

    {:ok, _} = Roles.set_override(responsibility_key, agent.id)

    maybe_replace_template!(opts)

    ExUnit.Callbacks.on_exit(fn ->
      Process.delete(:security_llm_enrichment_stub_fun)
      Process.delete(:security_llm_enrichment_call_count)
      Process.delete(:security_llm_enrichment_last_messages)

      if is_nil(prev_provider) do
        Application.delete_env(:platform, :security_llm_enrichment_provider)
      else
        Application.put_env(
          :platform,
          :security_llm_enrichment_provider,
          prev_provider
        )
      end
    end)

    agent
  end

  @doc """
  Plant the canned-response fun. The fun signature matches the
  Provider behaviour's `chat/3`: `(credentials, messages, opts) ->
  {:ok, %{content: json_string}}`.
  """
  def plant_response!(fun) when is_function(fun, 3) do
    Process.put(:security_llm_enrichment_stub_fun, fun)
    :ok
  end

  @doc """
  Convenience for the common canned response: return the given
  summary + priority + remediation_steps as OpenAI-compat JSON.
  """
  def plant_canned!(summary, priority, remediation_steps) do
    plant_response!(fn _c, _m, _o ->
      {:ok,
       %{
         content:
           Jason.encode!(%{
             "summary" => summary,
             "priority" => priority,
             "remediation_steps" => remediation_steps
           })
       }}
    end)
  end

  @doc "How many times the stub provider's chat/3 was invoked."
  def call_count, do: Process.get(:security_llm_enrichment_call_count) || 0

  # ── template swap ────────────────────────────────────────────────────

  defp maybe_replace_template!(opts) do
    case Keyword.get(opts, :template_slug) do
      nil ->
        :ok

      slug ->
        content = Keyword.fetch!(opts, :template_content)

        case PromptTemplates.get_template_by_slug(slug) do
          nil -> :ok
          existing -> {:ok, _} = PromptTemplates.delete_template(existing)
        end

        {:ok, _} =
          PromptTemplates.create_template(%{
            slug: slug,
            name: "test-swapped",
            description: "test swapped",
            variables: [],
            content: content
          })

        :ok
    end
  end
end
