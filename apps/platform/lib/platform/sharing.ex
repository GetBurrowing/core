defmodule Platform.Sharing do
  @moduledoc """
  What this install shares with Burrow, and the owner's switch for each part
  (task 01a1b678 stage 1).

  ## The registry is data

  `registry/0` is a plain list of entries:

      %{key, title, description, exactly_sent, default_for_new_installs}

  Settings → Help → "Sharing with Burrow", the setup disclosure and the
  installer all read this one list, so a part cannot be shown without its
  switch or switched without being shown. Owner-facing copy never says
  "telemetry" or "analytics"; `Platform.SharingTest` pins that.

  Four entries ship today: `feedback`, `usage_counts`, `friction_reports` and
  `help_channel_reports`. More are expected, each added as ONE entry here
  plus ONE boolean column on `install_sharing` and ONE env name for the seed:

    * support access (task 01a1b362) adds an entry when it lands;
    * automatic updates (task 01a1b35d) adds an entry when it lands.

  `default_for_new_installs` is what the self-host installer's setup flow
  writes into a NEW manifest (`deployment/installer`, `[sharing]` table). It
  is never applied to an existing install.

  ## Per-install state

  The `install_sharing` singleton row (`Platform.Sharing.InstallSharing`)
  holds one boolean per key and a random `sharing_install_id` (UUIDv4, not
  the federation install id, linked to no account).

  The row is seeded ONCE, by the first `get/0` after first boot, from the
  environment `config/runtime.exs` reads:

    * `feedback` from `FEEDBACK_POLICY` (on exactly when the policy is
      `quarantined` or `trusted`);
    * `usage_counts` from `USAGE_COUNTS`;
    * `friction_reports` from `FRICTION_REPORTS`;
    * `help_channel_reports` from `HELP_CHANNEL_REPORTS`.

  Unset means off. After the seed the ROW wins: re-rendering an install with
  different env never flips a switch, on or off. Only `set/3` changes a
  switch, and every change writes a `Platform.Audit` row naming the actor.

  ## No cache

  `enabled?/1` reads the row on every call, like `Platform.Branding.get/0`,
  so an owner's switch takes effect on the next call without a restart.
  """

  import Ecto.Query, only: [from: 2]

  alias Platform.Audit
  alias Platform.Feedback.Policy
  alias Platform.Repo
  alias Platform.Sharing.InstallSharing

  @type key :: :feedback | :usage_counts | :friction_reports | :help_channel_reports

  @type entry :: %{
          key: key(),
          title: String.t(),
          description: String.t(),
          exactly_sent: [String.t()],
          default_for_new_installs: boolean()
        }

  @type actor :: :system | {:user, Ecto.UUID.t()} | {:agent, Ecto.UUID.t()}

  @registry [
    %{
      key: :feedback,
      title: "Feedback you send",
      description:
        "When you or an agent use Send feedback, it becomes an issue Burrow's team can see.",
      exactly_sent: [
        "The title, what was expected, what happened, the steps, the version and the area you or an agent write, after emails and secrets are removed",
        "Whether it is a bug or a suggested change"
      ],
      default_for_new_installs: true
    },
    %{
      key: :usage_counts,
      title: "Anonymous usage counts",
      description:
        "How often features are used and where people stop. No messages, names or emails.",
      exactly_sent: [
        "A count per named event, for example meeting.started or composer.sent",
        "Your random install id"
      ],
      default_for_new_installs: true
    },
    %{
      key: :friction_reports,
      title: "Agent friction reports",
      description:
        "If an agent hits the same problem 3 or more times in a week, it reports it for you.",
      exactly_sent: [
        "A short description of the problem the agent kept hitting, after emails and secrets are removed",
        "How many times it happened that week",
        "For a question asked again and again, only a hash of it and the count, never the words"
      ],
      default_for_new_installs: true
    },
    %{
      key: :help_channel_reports,
      title: "Help channel bug reports",
      description: "Bug reports you post in Help & feedback are sent to Burrow",
      exactly_sent: [
        "The bug report text posted in Help & feedback, after emails and secrets are removed"
      ],
      default_for_new_installs: true
    }
  ]

  @never_sent ["message text", "names", "emails", "space or agent names"]

  @seed_env %{
    usage_counts: "USAGE_COUNTS",
    friction_reports: "FRICTION_REPORTS",
    help_channel_reports: "HELP_CHANNEL_REPORTS"
  }

  @doc "The registry, in display order."
  @spec registry() :: [entry()]
  def registry, do: @registry

  @doc "Every registry key, in display order."
  @spec keys() :: [key()]
  def keys, do: Enum.map(@registry, & &1.key)

  @doc "The registry entry for `key`, or nil."
  @spec entry(atom()) :: entry() | nil
  def entry(key), do: Enum.find(@registry, &(&1.key == key))

  @doc "What is never sent, for the \"Exactly what's sent\" panel."
  @spec never_sent() :: [String.t()]
  def never_sent, do: @never_sent

  @doc """
  The env names that seed each non-feedback switch. `feedback` is seeded
  from `FEEDBACK_POLICY`. The hosted renderer (task 01a1b67c) consumes these.
  """
  @spec seed_env_names() :: %{key() => String.t()}
  def seed_env_names, do: Map.put(@seed_env, :feedback, "FEEDBACK_POLICY")

  @doc """
  The singleton row, seeding it from the environment if it does not exist
  yet. An existing row is returned untouched.
  """
  @spec get() :: InstallSharing.t()
  def get do
    case read() do
      %InstallSharing{} = row ->
        row

      nil ->
        %InstallSharing{}
        |> InstallSharing.seed_changeset(seed_attrs())
        |> Repo.insert!(on_conflict: :nothing, conflict_target: :singleton)

        # A concurrent first read may have won the insert; read whichever
        # row storage kept.
        read() || raise "install_sharing row missing after seed"
    end
  end

  @doc """
  Every switch as `%{key => boolean}`, in one read of the row. The owner UI
  (`PlatformWeb.Components.SharingCard`) renders from this and `registry/0`.
  """
  @spec switches() :: %{key() => boolean()}
  def switches do
    row = get()
    Map.new(keys(), fn key -> {key, Map.fetch!(row, key) == true} end)
  end

  @doc """
  Whether `user` may change a switch: an admin of the root org, the same
  rule the `sharing_set` agent tool applies to the person who asked. Anyone
  else sees the switches read-only.
  """
  @spec admin?(term()) :: boolean()
  def admin?(%{id: user_id} = user) when is_binary(user_id) do
    case Platform.Tenancy.get_root_org() do
      %{id: root_id} -> Platform.Tenancy.org_admin?(user, root_id)
      _ -> false
    end
  end

  def admin?(_user), do: false

  @doc """
  Whether the owner's switch for `key` is on. Reads the row.

  Before `Platform.Repo` has started there is no row to read, and the answer
  is `false`. Boot needs this: `Platform.Extensions.validate!/0` lists every
  tool name in `Platform.Application.start/2`, ahead of the Repo, and the
  feedback tool is listed through `Platform.Feedback.Policy.enabled?/0`,
  which reads this switch. Without the guard, every install with
  `FEEDBACK_POLICY` on refused to boot.
  """
  @spec enabled?(key()) :: boolean()
  def enabled?(key), do: read_switch(key, Platform.Repo)

  @doc false
  # `enabled?/1` against a named repo process, so the not-started case is
  # testable without stopping the real Repo.
  @spec read_switch(key(), atom()) :: boolean()
  def read_switch(key, repo) do
    ensure_key!(key)

    case Process.whereis(repo) do
      nil -> false
      _pid -> Map.fetch!(get(), key) == true
    end
  end

  @doc """
  Turn the switch for `key` on or off and record an audit row naming
  `actor` (`:system`, `{:user, id}` or `{:agent, id}`). `opts[:via_agent_id]`
  adds the agent a person asked (`sharing_set`, task 01a1b678 stage 4) to
  the row's metadata.
  """
  @spec set(key(), boolean(), actor(), keyword()) :: {:ok, InstallSharing.t()} | {:error, term()}
  def set(key, value, actor, opts \\ []) when is_boolean(value) do
    ensure_key!(key)
    {actor_type, actor_id} = actor_fields(actor)
    row = get()
    previous = Map.fetch!(row, key)

    result =
      Repo.transaction(fn ->
        with {:ok, updated} <- Repo.update(InstallSharing.switch_changeset(row, key, value)),
             {:ok, _event} <-
               Audit.record(%{
                 event_type: "platform.sharing.switch_set",
                 actor_type: actor_type,
                 actor_id: actor_id,
                 resource_type: "install_sharing",
                 resource_id: to_string(updated.id),
                 action: "switch_set",
                 metadata:
                   maybe_via_agent(
                     %{
                       "key" => Atom.to_string(key),
                       "value" => value,
                       "previous" => previous
                     },
                     Keyword.get(opts, :via_agent_id)
                   )
               }) do
          updated
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    # The usage-counts collector reads a node-local flag, never the row
    # (stage 2). Turning the switch off also drops what is pending.
    with {:ok, _} <- result, :usage_counts <- key do
      Platform.Sharing.UsageEvents.set_counting(value)
    end

    result
  end

  @doc """
  The seed attributes, from the environment `config/runtime.exs` read.
  Public so the seed rule is testable without inserting.
  """
  @spec seed_attrs() :: map()
  def seed_attrs do
    seed = Application.get_env(:platform, :sharing_seed, [])

    switches =
      Map.new(@seed_env, fn {key, _name} -> {key, Keyword.get(seed, key, false) == true} end)

    switches
    |> Map.put(:feedback, Policy.mode() != :disabled)
    |> Map.put(:sharing_install_id, Ecto.UUID.generate())
  end

  @doc """
  Parse a seed env value. `true`, `1`, `yes` and `on` (trimmed, any case)
  are on; everything else, including unset, is off.
  """
  @spec parse_env(String.t() | nil) :: boolean()
  def parse_env(value) when is_binary(value),
    do: String.downcase(String.trim(value)) in ~w(true 1 yes on)

  def parse_env(_value), do: false

  @friction_defaults [threshold: 3, window_days: 7, max_reports_per_install_per_week: 5]

  @doc """
  The friction-report knobs (`config :platform, :friction_reports`):
  `threshold` repeats of one problem within `window_days` files a report, and
  an install files at most `max_reports_per_install_per_week`. A missing or
  non-positive value falls back to the default (3, 7, 5).
  """
  @spec friction_settings() :: %{
          threshold: pos_integer(),
          window_days: pos_integer(),
          max_reports_per_install_per_week: pos_integer()
        }
  def friction_settings do
    configured = Application.get_env(:platform, :friction_reports, [])

    Map.new(@friction_defaults, fn {key, default} ->
      case Keyword.get(configured, key) do
        n when is_integer(n) and n > 0 -> {key, n}
        _ -> {key, default}
      end
    end)
  end

  defp read, do: Repo.one(from(s in InstallSharing, limit: 1))

  defp maybe_via_agent(metadata, agent_id) when is_binary(agent_id),
    do: Map.put(metadata, "via_agent_id", agent_id)

  defp maybe_via_agent(metadata, _agent_id), do: metadata

  defp ensure_key!(key) do
    unless key in InstallSharing.switches() do
      raise ArgumentError, "unknown sharing key #{inspect(key)}"
    end
  end

  defp actor_fields(:system), do: {"system", nil}
  defp actor_fields({:user, id}) when is_binary(id), do: {"user", id}
  defp actor_fields({:agent, id}) when is_binary(id), do: {"agent", id}
end
