defmodule Platform.SharingTest do
  @moduledoc """
  Task 01a1b678 stage 1: the sharing registry is data, the `install_sharing`
  singleton is seeded once from env and then wins, `set/3` audits, and the
  feedback policy follows the owner's switch.

  async: false: flips `:sharing_seed` and `:feedback_policy` and restores them.
  """
  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Platform.Audit.Event
  alias Platform.Feedback.Policy
  alias Platform.Repo
  alias Platform.Sharing
  alias Platform.Sharing.InstallSharing

  setup do
    saved =
      for key <- [:sharing_seed, :feedback_policy, :friction_reports],
          do: {key, Application.fetch_env(:platform, key)}

    on_exit(fn ->
      for {key, value} <- saved do
        case value do
          {:ok, v} -> Application.put_env(:platform, key, v)
          :error -> Application.delete_env(:platform, key)
        end
      end
    end)

    :ok
  end

  defp seed_env(seed, policy) do
    Application.put_env(:platform, :sharing_seed, seed)
    Application.put_env(:platform, :feedback_policy, policy)
  end

  defp row_count, do: Repo.aggregate(InstallSharing, :count)

  describe "registry/0" do
    test "is four entries of exactly the documented shape, in display order" do
      assert Sharing.keys() == [
               :feedback,
               :usage_counts,
               :friction_reports,
               :help_channel_reports
             ]

      for entry <- Sharing.registry() do
        assert Map.keys(entry) |> Enum.sort() ==
                 [:default_for_new_installs, :description, :exactly_sent, :key, :title]

        assert is_binary(entry.title) and entry.title != ""
        assert is_binary(entry.description) and entry.description != ""
        assert [_ | _] = entry.exactly_sent
        assert Enum.all?(entry.exactly_sent, &is_binary/1)
        assert entry.default_for_new_installs == true
      end
    end

    test "carries the design canvas copy verbatim" do
      assert %{
               title: "Feedback you send",
               description:
                 "When you or an agent use Send feedback, it becomes an issue Burrow's team can see."
             } = Sharing.entry(:feedback)

      assert %{
               title: "Anonymous usage counts",
               description:
                 "How often features are used and where people stop. No messages, names or emails."
             } = Sharing.entry(:usage_counts)

      assert %{
               title: "Agent friction reports",
               description:
                 "If an agent hits the same problem 3 or more times in a week, it reports it for you."
             } = Sharing.entry(:friction_reports)

      assert Sharing.entry(:help_channel_reports).description ==
               "Bug reports you post in Help & feedback are sent to Burrow"
    end

    test "owner-facing copy never says telemetry or analytics" do
      copy =
        Enum.flat_map(Sharing.registry(), fn e -> [e.title, e.description | e.exactly_sent] end) ++
          Sharing.never_sent()

      for text <- copy do
        refute text =~ ~r/telemetry|analytics/i, "owner copy says #{inspect(text)}"
      end
    end

    test "every key has a switch column and a seed env name" do
      assert Sharing.keys() == InstallSharing.switches()

      assert Sharing.seed_env_names() == %{
               feedback: "FEEDBACK_POLICY",
               usage_counts: "USAGE_COUNTS",
               friction_reports: "FRICTION_REPORTS",
               help_channel_reports: "HELP_CHANNEL_REPORTS"
             }
    end
  end

  describe "seeding" do
    test "with no env every switch is off and a random v4 id is written" do
      Application.delete_env(:platform, :sharing_seed)
      Application.put_env(:platform, :feedback_policy, "disabled")

      assert row_count() == 0
      row = Sharing.get()
      assert row_count() == 1

      for key <- Sharing.keys(), do: refute(Map.fetch!(row, key), "#{key} seeded on")

      assert {:ok, _} = Ecto.UUID.cast(row.sharing_install_id)
      assert String.at(row.sharing_install_id, 14) == "4"
    end

    test "env present seeds each switch from its own name" do
      seed_env(
        [usage_counts: true, friction_reports: false, help_channel_reports: true],
        "quarantined"
      )

      row = Sharing.get()
      assert row.feedback
      assert row.usage_counts
      refute row.friction_reports
      assert row.help_channel_reports
    end

    test "an unknown FEEDBACK_POLICY seeds feedback off" do
      seed_env([], "enabeld")
      refute Sharing.get().feedback
    end

    test "an existing row is never overwritten by later env" do
      seed_env([], "disabled")
      first = Sharing.get()
      refute first.usage_counts

      # The install is re-rendered with everything on and restarted.
      seed_env(
        [usage_counts: true, friction_reports: true, help_channel_reports: true],
        "trusted"
      )

      again = Sharing.get()
      assert again.id == first.id
      assert again.sharing_install_id == first.sharing_install_id
      for key <- Sharing.keys(), do: refute(Sharing.enabled?(key), "#{key} flipped on")
      assert row_count() == 1
    end

    test "the sharing id is freshly random per seed, never derived from the install" do
      ids = for _ <- 1..3, do: Sharing.seed_attrs().sharing_install_id
      assert length(Enum.uniq(ids)) == 3
    end

    test "storage refuses a second row" do
      Sharing.get()

      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(
          InstallSharing.seed_changeset(%InstallSharing{}, Sharing.seed_attrs()),
          []
        )
      end
    end

    test "parse_env/1 is on only for explicit truthy words" do
      for v <- ["true", " TRUE ", "1", "yes", "on"], do: assert(Sharing.parse_env(v))
      for v <- [nil, "", "false", "0", "no", "off", "ture"], do: refute(Sharing.parse_env(v))
    end
  end

  describe "set/3" do
    test "writes the switch and an audit row naming the actor" do
      seed_env([], "disabled")
      user_id = Ecto.UUID.generate()

      assert {:ok, row} = Sharing.set(:usage_counts, true, {:user, user_id})
      assert row.usage_counts
      assert Sharing.enabled?(:usage_counts)

      [event] =
        Repo.all(from(e in Event, where: e.event_type == "platform.sharing.switch_set"))

      assert event.actor_type == "user"
      assert event.actor_id == user_id
      assert event.resource_type == "install_sharing"
      assert event.resource_id == to_string(row.id)
      assert event.metadata == %{"key" => "usage_counts", "value" => true, "previous" => false}
    end

    test "an agent and the system are named too" do
      agent_id = Ecto.UUID.generate()
      assert {:ok, _} = Sharing.set(:friction_reports, true, {:agent, agent_id})
      assert {:ok, _} = Sharing.set(:friction_reports, false, :system)

      events =
        Repo.all(
          from(e in Event,
            where: e.event_type == "platform.sharing.switch_set",
            order_by: e.id
          )
        )

      assert Enum.map(events, &{&1.actor_type, &1.actor_id}) == [
               {"agent", agent_id},
               {"system", nil}
             ]

      refute Sharing.enabled?(:friction_reports)
    end

    test "an unknown key is refused" do
      assert_raise ArgumentError, fn -> Sharing.set(:support_access, true, :system) end
      assert_raise ArgumentError, fn -> Sharing.enabled?(:support_access) end
    end
  end

  describe "Feedback.Policy follows the switch" do
    test "an enabled policy is off once the owner turns feedback off, and back on" do
      seed_env([], "quarantined")
      assert Policy.enabled?()

      {:ok, _} = Sharing.set(:feedback, false, :system)
      refute Policy.enabled?()
      assert Policy.mode() == :quarantined

      {:ok, _} = Sharing.set(:feedback, true, :system)
      assert Policy.enabled?()
    end

    test "the switch alone never enables a disabled policy" do
      seed_env([], "disabled")
      {:ok, _} = Sharing.set(:feedback, true, :system)
      refute Policy.enabled?()
    end

    test "a disabled policy never reads or seeds the row" do
      seed_env([], "disabled")
      refute Policy.enabled?()
      assert row_count() == 0
    end
  end

  describe "friction_settings/0" do
    test "defaults are 3 in 7 days, 5 per install per week" do
      assert Sharing.friction_settings() ==
               %{threshold: 3, window_days: 7, max_reports_per_install_per_week: 5}
    end

    test "configured values are data and bad ones fall back" do
      Application.put_env(:platform, :friction_reports,
        threshold: 4,
        window_days: 0,
        max_reports_per_install_per_week: 2
      )

      assert Sharing.friction_settings() ==
               %{threshold: 4, window_days: 7, max_reports_per_install_per_week: 2}
    end
  end
end
