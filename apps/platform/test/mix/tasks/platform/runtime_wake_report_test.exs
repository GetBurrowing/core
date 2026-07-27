defmodule Mix.Tasks.Platform.RuntimeWakeReportTest do
  @moduledoc """
  Tests for the `claude_channel` wake-delivery report.

  Async: false because the report reads every `agent_runtimes` row in the
  database and asserts exact footer counts — an async sibling inserting a
  runtime would be invisible across sandbox connections today, but the
  count assertions are the point of the report and are not worth making
  order-dependent. `Mix.shell/0` is also process-global.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Platform.RuntimeWakeReport
  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Repo

  @feature AgentRuntime.system_event_prompt_feature()

  setup do
    user = create_user()

    # ---------------------------------------------------------------
    # The four shapes named by the plan, plus the two exclusions.
    #
    # Every one of these carries a distinct runtime_id so an assertion
    # can name the row it means; nothing here is asserted by position.
    # ---------------------------------------------------------------

    # (1) proven — declared the capability on its most recent join.
    proven =
      create_runtime!(user, "wr-proven",
        slug: "wr-proven-agent",
        status: "active",
        client_info: %{
          "product" => "claude_channel",
          "version" => "0.3.0",
          "features" => [@feature]
        }
      )

    # (2) unproven, old build — the exact production shape of every row on
    # the ticket's table: a version string, and `features` written as the
    # empty list by a post-stage-2 server because the client sent none.
    old_build =
      create_runtime!(user, "wr-old-build",
        slug: "wr-old-agent",
        status: "active",
        client_info: %{
          "product" => "claude_channel",
          "version" => "0.2.0",
          "features" => []
        }
      )

    # (3) never-declared — joined before the server recorded features at
    # all, so there is no `features` KEY, not merely an empty one. This is
    # what every existing production row looks like right now.
    never_declared =
      create_runtime!(user, "wr-never-declared",
        slug: "wr-never-agent",
        status: "active",
        client_info: %{"product" => "claude_channel", "version" => "0.2.0"},
        last_connected_at: nil
      )

    # (4) revoked — cannot authenticate, cannot join, cannot receive a
    # dispatch. Separate section, and NOT part of the unproven count.
    revoked =
      create_runtime!(user, "wr-revoked",
        slug: "wr-revoked-agent",
        status: "revoked",
        client_info: %{"product" => "claude_channel", "version" => "0.2.0"}
      )

    # (5) EXCLUSION: an openclaw runtime that DECLARES the feature. If the
    # report ever filtered on the capability instead of the product this row
    # would show up as `proven` and inflate the total.
    openclaw =
      create_runtime!(user, "wr-openclaw",
        slug: "wr-openclaw-agent",
        status: "active",
        client_info: %{
          "product" => "openclaw",
          "version" => "1.4.0",
          "features" => [@feature]
        }
      )

    # (6) EXCLUSION: empty metadata. `client_product/1` reads "unknown"; the
    # server has no basis to call this a claude_channel runtime, so it is out
    # of scope rather than silently counted as unproven.
    unknown = create_runtime!(user, "wr-unknown", slug: "wr-unknown-agent", status: "active")

    %{
      proven: proven,
      old_build: old_build,
      never_declared: never_declared,
      revoked: revoked,
      openclaw: openclaw,
      unknown: unknown
    }
  end

  describe "verdicts" do
    test "renders proven AND unproven in the same run" do
      output = capture_io(fn -> assert RuntimeWakeReport.run([]) == :ok end)

      # Both directions, one run. A report that classified every row
      # identically would satisfy only one of these two assertions.
      assert verdict_for(output, "wr-proven") == "proven"
      assert verdict_for(output, "wr-old-build") == "unproven"
    end

    test "a runtime that never declared anything is unproven, not proven" do
      output = capture_io(fn -> RuntimeWakeReport.run([]) end)

      # No `features` key at all — fails closed.
      assert verdict_for(output, "wr-never-declared") == "unproven"
    end

    test "the verdict is not read off the version string" do
      output = capture_io(fn -> RuntimeWakeReport.run([]) end)

      # `wr-old-build` and `wr-never-declared` both report version 0.2.0 and
      # both read unproven; `wr-proven` reports 0.3.0. That alone is
      # consistent with a version check, so pin the discriminator directly:
      # flip ONLY the features list on the old-build row and the verdict
      # moves while its version string stays put.
      assert verdict_for(output, "wr-old-build") == "unproven"
      assert row_for(output, "wr-old-build") =~ "0.2.0"

      declare_feature!("wr-old-build")

      after_output = capture_io(fn -> RuntimeWakeReport.run([]) end)

      assert verdict_for(after_output, "wr-old-build") == "proven"
      assert row_for(after_output, "wr-old-build") =~ "0.2.0"
    end

    test "never prints the word broken" do
      output = capture_io(fn -> RuntimeWakeReport.run([]) end)

      # Absence of a declaration is not evidence of a defect. A report that
      # said "broken" would get quoted back as a defect count.
      refute output =~ "broken"
      refute output =~ "BROKEN"
    end
  end

  describe "scope" do
    test "an openclaw runtime is excluded entirely, even though it declares the feature" do
      output = capture_io(fn -> RuntimeWakeReport.run([]) end)

      refute output =~ "wr-openclaw"
      refute output =~ "wr-openclaw-agent"
    end

    test "a runtime with no client_info at all is excluded (product is unknown)" do
      output = capture_io(fn -> RuntimeWakeReport.run([]) end)

      refute output =~ "wr-unknown"
    end

    test "included rows carry the agent slug, status, last-connected and version" do
      output = capture_io(fn -> RuntimeWakeReport.run([]) end)

      row = row_for(output, "wr-proven")
      assert row =~ "wr-proven-agent"
      assert row =~ "active"
      assert row =~ "0.3.0"
      assert row =~ "2026-01-02T03:04:05"

      # A runtime that has never connected says so rather than rendering a
      # blank column an operator would read as a formatting bug.
      assert row_for(output, "wr-never-declared") =~ "never"
    end

    test "a long runtime_id and slug still leave the columns separated", %{proven: _} do
      user = create_user()

      # `neven-home-claude-code` is already 22 characters in production; a
      # fixed-width column that a value exactly fills runs into the next one
      # with no separator, which renders as `...agent-1234active` and silently
      # corrupts anything (operator or script) splitting on whitespace.
      long_id = "wr-a-very-long-runtime-identifier-indeed"

      create_runtime!(user, long_id,
        slug: "wr-an-extremely-long-agent-slug-for-columns",
        status: "active",
        client_info: %{"product" => "claude_channel", "version" => "0.2.0"}
      )

      output = capture_io(fn -> RuntimeWakeReport.run([]) end)

      cells = output |> row_for(long_id) |> String.split()

      # runtime_id, slug, status, last connected, version, verdict — six
      # whitespace-separated cells, none of them fused together.
      assert length(cells) == 6
      assert Enum.at(cells, 0) == long_id
      assert Enum.at(cells, 2) == "active"
      assert List.last(cells) == "unproven"

      # The short rows are still aligned under the same header.
      assert verdict_for(output, "wr-proven") == "proven"
    end
  end

  describe "revoked handling" do
    test "revoked rows sit in their own section with the not-a-delivery-risk note" do
      output = capture_io(fn -> RuntimeWakeReport.run([]) end)

      assert output =~ "REVOKED"

      # The note has to be on the SECTION, not merely somewhere in the output
      # — the legend also carries the phrase, so a bare `output =~` here would
      # stay green with the section header stripped back to "REVOKED".
      {live_section, revoked_section} = split_sections(output)
      assert revoked_section =~ "cannot join — not a delivery risk"

      # The revoked row is in the revoked section and nowhere else.
      refute live_section =~ "wr-revoked"
      assert revoked_section =~ "wr-revoked"
    end

    test "the revoked row is absent from the unproven count" do
      output = capture_io(fn -> RuntimeWakeReport.run([]) end)

      %{total: total, proven: proven, unproven: unproven, revoked: revoked} = footer(output)

      # Three claude_channel rows can join (proven, old-build,
      # never-declared) and one cannot.
      assert proven == 1
      assert unproven == 2
      assert revoked == 1
      assert total == 4

      # The arithmetic an operator actually reads.
      assert total == proven + unproven + revoked

      # And the load-bearing exclusion: had the revoked row been folded into
      # the unproven list, unproven would read 3.
      refute unproven == 3
    end

    test "revoking a live unproven runtime moves it out of the unproven count" do
      before_counts = footer(capture_io(fn -> RuntimeWakeReport.run([]) end))
      assert before_counts.unproven == 2
      assert before_counts.revoked == 1

      revoke!("wr-never-declared")

      after_counts = footer(capture_io(fn -> RuntimeWakeReport.run([]) end))

      # Total is unchanged — the row did not vanish, it moved sections.
      assert after_counts.total == before_counts.total
      assert after_counts.unproven == 1
      assert after_counts.revoked == 2

      assert after_counts.total ==
               after_counts.proven + after_counts.unproven + after_counts.revoked
    end
  end

  describe "legend" do
    test "glosses unproven as both an old build and one that has not reconnected" do
      output = capture_io(fn -> RuntimeWakeReport.run([]) end)

      legend = legend_section(output)

      assert legend =~ "proven"
      assert legend =~ "unproven"
      assert legend =~ "running an old build"
      assert legend =~ "has not reconnected since the server started recording"
      assert legend =~ "not evidence of a defect"
    end

    test "names the capability from the AgentRuntime constant, not a restated literal" do
      output = capture_io(fn -> RuntimeWakeReport.run([]) end)

      assert output =~ AgentRuntime.system_event_prompt_feature()
    end
  end

  describe "run/1 with no claude_channel runtimes" do
    test "reports zeroes rather than an empty table", %{
      proven: proven,
      old_build: old_build,
      never_declared: never_declared,
      revoked: revoked
    } do
      for rt <- [proven, old_build, never_declared, revoked], do: Repo.delete!(rt)

      output = capture_io(fn -> assert RuntimeWakeReport.run([]) == :ok end)

      assert footer(output) == %{total: 0, proven: 0, unproven: 0, revoked: 0}
      # The openclaw and unknown rows still exist, so a zero total here is
      # also a second, independent pin on the product filter.
      assert output =~ "no claude_channel runtimes"
    end
  end

  # ------------------------------------------------------------------
  # helpers
  # ------------------------------------------------------------------

  defp create_user do
    Repo.insert!(%User{
      email: "wake_report_#{System.unique_integer([:positive])}@example.com",
      name: "Wake Report Test User",
      oidc_sub: "oidc-wake-report-#{System.unique_integer([:positive])}"
    })
  end

  defp create_runtime!(user, runtime_id, opts) do
    slug = Keyword.fetch!(opts, :slug)

    agent =
      Repo.insert!(%Agent{
        slug: "#{slug}-#{System.unique_integer([:positive])}",
        name: slug,
        status: "active"
      })

    metadata =
      case Keyword.get(opts, :client_info) do
        nil -> %{}
        ci -> %{"client_info" => ci}
      end

    Repo.insert!(%AgentRuntime{
      runtime_id: runtime_id,
      owner_user_id: user.id,
      agent_id: agent.id,
      display_name: slug,
      status: Keyword.get(opts, :status, "active"),
      last_connected_at: Keyword.get(opts, :last_connected_at, ~U[2026-01-02 03:04:05.000000Z]),
      metadata: metadata
    })
  end

  defp declare_feature!(runtime_id) do
    runtime = Repo.get_by!(AgentRuntime, runtime_id: runtime_id)
    ci = Map.get(runtime.metadata, "client_info", %{})

    runtime
    |> Ecto.Changeset.change(%{
      metadata: Map.put(runtime.metadata, "client_info", Map.put(ci, "features", [@feature]))
    })
    |> Repo.update!()
  end

  defp revoke!(runtime_id) do
    AgentRuntime
    |> Repo.get_by!(runtime_id: runtime_id)
    |> Ecto.Changeset.change(%{status: "revoked", auth_token_hash: nil})
    |> Repo.update!()
  end

  # The line of the report that mentions `runtime_id`, from the live table.
  defp row_for(output, runtime_id) do
    output
    |> String.split("\n")
    |> Enum.find(&String.contains?(&1, runtime_id))
    |> case do
      nil -> flunk("no report row for #{runtime_id} in:\n#{output}")
      line -> line
    end
  end

  defp verdict_for(output, runtime_id) do
    output
    |> row_for(runtime_id)
    |> String.split()
    |> List.last()
  end

  # The revoked half is cut at LEGEND so a legend line can never stand in for
  # something the revoked section itself was supposed to print.
  defp split_sections(output) do
    case String.split(output, "REVOKED", parts: 2) do
      [live, revoked] -> {live, revoked |> String.split("LEGEND", parts: 2) |> List.first()}
      [live] -> {live, ""}
    end
  end

  defp legend_section(output) do
    case String.split(output, "LEGEND", parts: 2) do
      [_pre, legend] -> legend
      [_] -> flunk("report printed no LEGEND section:\n#{output}")
    end
  end

  defp footer(output) do
    regex = ~r/total=(\d+)\s+proven=(\d+)\s+unproven=(\d+)\s+revoked=(\d+)/

    case Regex.run(regex, output) do
      [_, total, proven, unproven, revoked] ->
        %{
          total: String.to_integer(total),
          proven: String.to_integer(proven),
          unproven: String.to_integer(unproven),
          revoked: String.to_integer(revoked)
        }

      nil ->
        flunk("report printed no footer counts line in:\n#{output}")
    end
  end
end
