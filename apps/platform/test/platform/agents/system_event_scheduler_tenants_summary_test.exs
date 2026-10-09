defmodule Platform.Agents.SystemEventSchedulerTenantsSummaryTest do
  @moduledoc """
  Tests for the ADR 0042 Stage 3 weekly TENANTS_SUMMARY heartbeat wired
  into `Platform.Agents.SystemEventScheduler`.

  The pure cadence predicate (`should_fire_tenants_summary?/5`) is
  exercised without a DB, then the GenServer integration is exercised
  with a stubbed `:llm_fun` so the scheduler call goes through the
  curator end-to-end without a real LLM round-trip.
  """

  # ── Pure cadence predicate ─────────────────────────────────────────────

  defmodule PredicateTest do
    use ExUnit.Case, async: true

    alias Platform.Agents.SystemEventScheduler

    @sunday_04_30 ~U[2026-06-14 04:30:00.000000Z]
    @sunday_03_59 ~U[2026-06-14 03:59:00.000000Z]
    @monday_04_30 ~U[2026-06-15 04:30:00.000000Z]

    describe "should_fire_tenants_summary?/5" do
      test "fires on Sunday at/after the anchor hour with no prior run" do
        assert SystemEventScheduler.should_fire_tenants_summary?(@sunday_04_30, nil)
      end

      test "does not fire before the anchor hour" do
        refute SystemEventScheduler.should_fire_tenants_summary?(@sunday_03_59, nil)
      end

      test "does not fire on a non-Sunday weekday" do
        refute SystemEventScheduler.should_fire_tenants_summary?(@monday_04_30, nil)
      end

      test "respects the debounce window even when the anchor is current" do
        # Last run six hours ago — well inside the default ~6-day debounce.
        last_run = DateTime.add(@sunday_04_30, -6 * 3600, :second)
        refute SystemEventScheduler.should_fire_tenants_summary?(@sunday_04_30, last_run)
      end

      test "fires after the debounce window elapses (e.g. next week's anchor)" do
        # Last run was last Sunday's anchor — eight days ago, past the
        # default ~6-day debounce.
        last_run = DateTime.add(@sunday_04_30, -8 * 24 * 3600, :second)
        assert SystemEventScheduler.should_fire_tenants_summary?(@sunday_04_30, last_run)
      end
    end
  end

  # ── GenServer integration with the curator ─────────────────────────────

  defmodule IntegrationTest do
    use Platform.DataCase, async: false

    import Ecto.Query, only: [from: 2]

    alias Platform.Agents.SystemEventScheduler
    alias Platform.Org.WikiPage
    alias Platform.Repo

    defp summary_page do
      from(p in WikiPage,
        where: p.file_key == "org/acme/TENANTS_SUMMARY.md" and is_nil(p.workspace_id),
        limit: 1
      )
      |> Repo.one()
    end

    setup do
      # Application supervision leaves SystemEventScheduler unstarted in
      # the test env (see `config :platform, :start_system_event_scheduler, false`).
      # Start one with a long check interval so its periodic tick never
      # races our manual recompute call.
      {:ok, pid} =
        start_supervised({SystemEventScheduler, check_interval_ms: :timer.hours(24)})

      # The scheduler runs in its own process and needs explicit access
      # to the test's sandboxed DB connection.
      :ok = Ecto.Adapters.SQL.Sandbox.allow(Platform.Repo, self(), pid)

      # Clean any pre-existing summary page so the assertion observes
      # only what this test wrote.
      Repo.delete_all(WikiPage)

      :ok
    end

    test "recompute_tenants_summary_now/1 runs the curator end-to-end with a stub" do
      stub = fn name, _raw -> {:ok, "Stub paragraph for #{name}."} end

      assert {:ok, %WikiPage{file_key: "org/acme/TENANTS_SUMMARY.md"}} =
               SystemEventScheduler.recompute_tenants_summary_now(llm_fun: stub)

      page = summary_page()
      assert page
      assert page.content =~ "# Tenants Summary"
    end

    test "recompute_tenants_summary_now/1 surfaces curator errors verbatim" do
      # Seed an identity page so the LLM stub actually gets called for at
      # least one tenant (placeholder paragraphs never hit the LLM).
      [first | _] = Platform.Tenancy.list_tenants() |> Enum.sort_by(& &1.slug)

      {:ok, _} =
        Platform.Org.Wiki.upsert_page(
          "org/#{first.slug}/IDENTITY.md",
          %{content: "Some identity content to summarize."},
          workspace_id: nil
        )

      llm_fun = fn _name, _raw -> {:error, :stubbed_failure} end

      assert {:error, {:llm_failed, _slug, :stubbed_failure}} =
               SystemEventScheduler.recompute_tenants_summary_now(llm_fun: llm_fun)

      # And no partial write landed.
      refute summary_page()
    end
  end
end
