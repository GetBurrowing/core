defmodule Platform.Security.LlmEnrichmentTest do
  @moduledoc """
  Tests for `Platform.Security.LlmEnrichment` — the LLM-facing
  enrichment layer between each Security Guard scanner and the
  `FindingFiler` insert path (task `019f3e8e-4406` v2 stage 3,
  ADR-0043).

  Covers the four contract branches the plan calls out:

    1. No assignee → `{:noop, finding}` returned unchanged AND zero
       LLM calls made — the progressive-enhancement guarantee.
    2. Native-runtime assignee → `{:noop, finding}` (external-only
       gate). Also asserts zero LLM calls.
    3. External-runtime assignee → LLM called once with rendered
       prompt, closed-shape JSON parsed, fields merged.
    4. LLM raises → `{:noop, finding}` (crash-safe fallback),
       `Logger.warning` emitted.

  The provider is stubbed via `:security_llm_enrichment_provider`
  Application env; the stub reads a fun out of the process
  dictionary — enrich_finding runs synchronously in the caller so
  the stub sees the same process.
  """

  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Agents.Agent
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Repo
  alias Platform.Roles
  alias Platform.Security.LlmEnrichment

  @cve_key "security.cve_scan"
  @cve_slug "security.cve_scan.v1"

  # ── Provider stub ─────────────────────────────────────────────────────

  defmodule StubProvider do
    @moduledoc """
    In-test provider — reads a stub fun out of the calling process's
    dictionary. `enrich_finding/2` runs synchronously so this fires
    inside the test process.
    """

    @behaviour Platform.Agents.Providers.Provider

    @impl true
    def chat(credentials, messages, opts) do
      # Counter so tests can assert the LLM was (or was not) called.
      Process.put(
        :security_llm_enrichment_call_count,
        (Process.get(:security_llm_enrichment_call_count) || 0) + 1
      )

      Process.put(:security_llm_enrichment_last_messages, messages)
      Process.put(:security_llm_enrichment_last_opts, opts)
      Process.put(:security_llm_enrichment_last_credentials, credentials)

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

  # ── Setup ──────────────────────────────────────────────────────────────

  setup do
    # Install stub provider for the duration of the test.
    prev_provider =
      Application.get_env(:platform, :security_llm_enrichment_provider)

    Application.put_env(:platform, :security_llm_enrichment_provider, StubProvider)

    # Ensure the security.cve_scan.v1 template row exists — the
    # stage-1 migration seeds it in prod but the test DB may or may
    # not have it depending on rebuild order. Idempotent.
    ensure_cve_template!()

    on_exit(fn ->
      Process.delete(:security_llm_enrichment_call_count)
      Process.delete(:security_llm_enrichment_stub_fun)
      Process.delete(:security_llm_enrichment_last_messages)
      Process.delete(:security_llm_enrichment_last_opts)
      Process.delete(:security_llm_enrichment_last_credentials)

      if is_nil(prev_provider) do
        Application.delete_env(:platform, :security_llm_enrichment_provider)
      else
        Application.put_env(:platform, :security_llm_enrichment_provider, prev_provider)
      end
    end)

    :ok
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  # The stage-1 migration seeds the `security.cve_scan.v1` template
  # with prose that describes the assigns but does NOT contain
  # `{{variable}}` markers — the LLM reads the raw finding out of
  # the user message. For these tests we want to verify the assigns
  # extraction lands in the rendered prompt, so we replace the DB
  # row with a marker-carrying test copy. The sandbox transaction
  # rolls back at end of test, restoring the migration's original.
  defp ensure_cve_template! do
    case PromptTemplates.get_template_by_slug(@cve_slug) do
      nil ->
        :ok

      existing ->
        {:ok, _} = PromptTemplates.delete_template(existing)
    end

    {:ok, _} =
      PromptTemplates.create_template(%{
        slug: @cve_slug,
        name: "Security: CVE Scan (test)",
        description: "test seeded",
        variables: [
          "finding",
          "cve_id",
          "severity",
          "package",
          "version",
          "ecosystem",
          "fixed_version"
        ],
        content: """
        Security Guard CVE enrichment for CVE {{cve_id}}.
        Package: {{package}} {{version}} ({{ecosystem}})
        Fixed in: {{fixed_version}}
        Raw severity: {{severity}}
        Raw finding: {{finding}}
        """
      })

    :ok
  end

  defp create_agent!(overrides) do
    attrs =
      Map.merge(
        %{
          slug: "sec-agent-#{System.unique_integer([:positive])}",
          name: "Security Agent",
          status: "active",
          kind: "native",
          runtime_type: "built_in"
        },
        overrides
      )

    %Agent{}
    |> Agent.changeset(attrs)
    |> Repo.insert!()
  end

  defp assign_override!(responsibility_key, agent) do
    {:ok, _} = Roles.set_override(responsibility_key, agent.id)
    :ok
  end

  defp cve_finding(overrides \\ %{}) do
    Map.merge(
      %{
        scanner_key: @cve_key,
        severity: :high,
        title: "CVE CVE-2024-99999 in plug 1.14.0 (severity: high)",
        description: "raw scanner description",
        fingerprint: "cve:CVE-2024-99999:plug:1.14.0",
        project_id: "00000000-0000-0000-0000-000000000000",
        metadata: %{
          "cve_id" => "CVE-2024-99999",
          "ecosystem" => "Hex",
          "package" => "plug",
          "installed_version" => "1.14.0",
          "fixed_version" => "1.14.1"
        }
      },
      overrides
    )
  end

  defp plant_stub!(fun) when is_function(fun, 3) do
    Process.put(:security_llm_enrichment_stub_fun, fun)
    :ok
  end

  defp call_count, do: Process.get(:security_llm_enrichment_call_count) || 0

  defp encode_ok(map), do: {:ok, %{content: Jason.encode!(map)}}

  # ── Tests ──────────────────────────────────────────────────────────────

  describe "enrich_finding/2 — no assignee" do
    test "returns {:noop, finding} unchanged when no agent is pinned" do
      finding = cve_finding()

      assert {:noop, ^finding} = LlmEnrichment.enrich_finding(finding, @cve_key)

      # Progressive-enhancement guarantee: zero LLM calls.
      assert call_count() == 0
    end
  end

  describe "enrich_finding/2 — native-runtime assignee" do
    test "returns {:noop, finding} when the pinned agent has runtime_type != external" do
      agent = create_agent!(%{runtime_type: "built_in"})
      assign_override!(@cve_key, agent)

      finding = cve_finding()

      assert {:noop, ^finding} = LlmEnrichment.enrich_finding(finding, @cve_key)

      # External-only gate: no provider dispatch.
      assert call_count() == 0
    end
  end

  describe "enrich_finding/2 — external-runtime assignee (happy path)" do
    setup do
      agent =
        create_agent!(%{
          runtime_type: "external",
          kind: "external",
          endpoint_kind: "openai_compat",
          base_url: "http://stub.example.local/v1",
          model: "stub-model",
          vault_key: nil
        })

      assign_override!(@cve_key, agent)

      %{agent: agent}
    end

    test "calls the LLM once and merges the closed-shape JSON into the finding" do
      plant_stub!(fn _creds, _messages, _opts ->
        encode_ok(%{
          "summary" => "Critical RCE in plug 1.14.0; upgrade to 1.14.1.",
          "priority" => "critical",
          "remediation_steps" => [
            "mix deps.update plug",
            "run mix test",
            "redeploy"
          ]
        })
      end)

      finding = cve_finding()

      assert {:enriched, enriched} = LlmEnrichment.enrich_finding(finding, @cve_key)

      # Merged fields:
      assert enriched.severity == :critical

      # Case-3 review fix: title now carries the LLM's summary
      # verbatim as a substring, tagged with the short scanner key.
      # This is what lands in FindingFiler's Suite task headline.
      assert enriched.title =~ "Critical RCE in plug 1.14.0; upgrade to 1.14.1."
      assert enriched.title =~ "[security:cve_scan]"
      # Original static scanner title is replaced (not appended).
      refute enriched.title == finding.title

      assert enriched.description =~ "Security Guard summary"
      assert enriched.description =~ "Critical RCE in plug"
      assert enriched.description =~ "Suggested remediation"
      assert enriched.description =~ "mix deps.update plug"
      # Original description preserved.
      assert enriched.description =~ "raw scanner description"

      # Dedup-stability guarantee: the fingerprint MUST NOT change
      # when the enrichment path runs, otherwise the same underlying
      # scanner finding would file as a new Suite task on every
      # enriched cron tick. Same rule for project_id — that's the
      # cross-run tenancy key.
      assert enriched.fingerprint == finding.fingerprint
      assert enriched.project_id == finding.project_id

      # Metadata flag + LLM output stashed for downstream inspection.
      assert enriched.metadata["security_enriched"] == true

      assert enriched.metadata["security_enrichment_summary"] ==
               "Critical RCE in plug 1.14.0; upgrade to 1.14.1."

      assert enriched.metadata["security_enrichment_priority"] == "critical"

      assert enriched.metadata["security_enrichment_remediation_steps"] == [
               "mix deps.update plug",
               "run mix test",
               "redeploy"
             ]

      # Original metadata retained.
      assert enriched.metadata["cve_id"] == "CVE-2024-99999"

      # Exactly one LLM call.
      assert call_count() == 1
    end

    test "passes the rendered prompt as the system message + finding JSON as user message" do
      plant_stub!(fn _c, _m, _o ->
        encode_ok(%{
          "summary" => "s",
          "priority" => "high",
          "remediation_steps" => ["a"]
        })
      end)

      _ = LlmEnrichment.enrich_finding(cve_finding(), @cve_key)

      [system, user] = Process.get(:security_llm_enrichment_last_messages)
      assert system.role == "system"
      # Prompt template interpolated with finding values.
      assert system.content =~ "CVE-2024-99999"
      assert system.content =~ "plug"
      assert system.content =~ "1.14.0"

      assert user.role == "user"
      # User message carries the raw finding JSON for cross-reference.
      assert user.content =~ "CVE-2024-99999"
    end

    test "invalid priority in the response falls back to :noop" do
      plant_stub!(fn _c, _m, _o ->
        encode_ok(%{
          "summary" => "s",
          "priority" => "extreme",
          "remediation_steps" => ["a"]
        })
      end)

      log =
        capture_log(fn ->
          finding = cve_finding()
          assert {:noop, ^finding} = LlmEnrichment.enrich_finding(finding, @cve_key)
        end)

      assert log =~ "invalid priority"
    end

    test "malformed JSON in the response falls back to :noop" do
      plant_stub!(fn _c, _m, _o -> {:ok, %{content: "not-json{{"}} end)

      log =
        capture_log(fn ->
          finding = cve_finding()
          assert {:noop, ^finding} = LlmEnrichment.enrich_finding(finding, @cve_key)
        end)

      assert log =~ "not JSON" or log =~ "missing required keys"
    end

    test "missing required response keys falls back to :noop" do
      plant_stub!(fn _c, _m, _o ->
        encode_ok(%{"summary" => "s", "priority" => "high"})
      end)

      log =
        capture_log(fn ->
          finding = cve_finding()
          assert {:noop, ^finding} = LlmEnrichment.enrich_finding(finding, @cve_key)
        end)

      assert log =~ "missing required keys"
    end
  end

  describe "enrich_finding/2 — crash-safe fallback" do
    setup do
      agent =
        create_agent!(%{
          runtime_type: "external",
          kind: "external",
          endpoint_kind: "openai_compat",
          base_url: "http://stub.example.local/v1",
          model: "stub-model"
        })

      assign_override!(@cve_key, agent)

      :ok
    end

    test "provider raise → {:noop, finding} + Logger.warning emitted" do
      plant_stub!(fn _c, _m, _o -> raise "boom" end)

      finding = cve_finding()

      log =
        capture_log(fn ->
          assert {:noop, ^finding} = LlmEnrichment.enrich_finding(finding, @cve_key)
        end)

      assert log =~ "provider raised" or log =~ "enrichment crashed"
    end

    test "provider returns {:error, ...} → {:noop, finding}" do
      plant_stub!(fn _c, _m, _o -> {:error, :timeout} end)

      finding = cve_finding()

      log =
        capture_log(fn ->
          assert {:noop, ^finding} = LlmEnrichment.enrich_finding(finding, @cve_key)
        end)

      assert log =~ "provider call failed"
    end

    test "provider returns unexpected shape → {:noop, finding}" do
      plant_stub!(fn _c, _m, _o -> {:ok, %{unexpected: :shape}} end)

      finding = cve_finding()

      log =
        capture_log(fn ->
          assert {:noop, ^finding} = LlmEnrichment.enrich_finding(finding, @cve_key)
        end)

      assert log =~ "unexpected shape"
    end
  end

  describe "enrich_finding/2 — missing template" do
    setup do
      # An external agent is pinned, but for a key with no template row.
      agent =
        create_agent!(%{
          runtime_type: "external",
          kind: "external",
          endpoint_kind: "openai_compat",
          base_url: "http://stub.example.local/v1",
          model: "stub-model"
        })

      unknown_key = "security.unmapped_scanner"
      assign_override!(unknown_key, agent)

      %{unknown_key: unknown_key}
    end

    test "unknown template slug falls back to :noop without hitting the LLM",
         %{unknown_key: key} do
      plant_stub!(fn _c, _m, _o ->
        flunk("provider must not be called when template is missing")
      end)

      finding = cve_finding(%{scanner_key: key, fingerprint: "unmapped:foo"})

      assert {:noop, ^finding} = LlmEnrichment.enrich_finding(finding, key)
      assert call_count() == 0
    end
  end

  describe "enrich_finding/2 — assigns extraction" do
    setup do
      agent =
        create_agent!(%{
          runtime_type: "external",
          kind: "external",
          endpoint_kind: "openai_compat",
          base_url: "http://stub.example.local/v1",
          model: "stub-model"
        })

      %{agent: agent}
    end

    test "CVE scanner assigns include cve_id / package / version / ecosystem / fixed_version",
         %{agent: agent} do
      assign_override!(@cve_key, agent)

      plant_stub!(fn _c, messages, _o ->
        Process.put(:security_llm_enrichment_last_system, hd(messages).content)

        encode_ok(%{
          "summary" => "s",
          "priority" => "medium",
          "remediation_steps" => []
        })
      end)

      _ = LlmEnrichment.enrich_finding(cve_finding(), @cve_key)

      prompt = Process.get(:security_llm_enrichment_last_system)
      # Interpolation ran across the CVE-specific assigns.
      assert prompt =~ "CVE-2024-99999"
      assert prompt =~ "plug"
      assert prompt =~ "1.14.0"
    end
  end
end
