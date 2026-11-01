defmodule Platform.Onboarding.FirstRunGoal do
  @moduledoc """
  The first-run "What do you want to do?" goal box (task 01a19554-fd07,
  stage 1). A new member types a goal once; it opens a new channel with the
  install's Burrow agent and is posted there as the first message, and
  Burrow takes it from there (task 01a19948-d342 stage 1).

  ## A visible channel, not a DM

  The goal used to go into the member's DM with Burrow. It now opens an
  ordinary `kind: "channel"` space in the member's org, with the member as
  its admin, Burrow as its principal agent and the `"directed"` attention
  policy, named by `placeholder_name/1` until Burrow helps rename it. Ryan,
  #hosted-install 2026-11-01: "Perhaps instead of a DM it could be in a
  channel style space? Perhaps the burrow agent could help with the naming
  of that space", then "No, it's not private by default", then "we need to
  give users the control to disable DM with agents if needed. That shouldn't
  break things but the want in that case is improved observability, not a
  different type of privacy".

  So the channel is VISIBLE ON PURPOSE: this module never calls
  `Chat.find_or_create_dm/4`, `Chat.create_group_conversation/3` or
  `Platform.Access.Restrictions.restrict_space/3`, and never makes a
  `kind: "group"` space. Barring a member from DMing agents cannot break it.

  `"directed"` because a channel defaults to `on_mention`: without it
  Burrow would hear neither the goal nor the member's un-mentioned replies.
  `"directed"` routes un-mentioned human lines to the principal only, so it
  keeps working once the Historian or other people join.

  ## State

  One key in `users.preferences`: `"first_run_goal"`. Its values:

    * `"submitted"` — the goal was posted into its channel with Burrow.
    * `"skipped"` — the member dismissed the box.
    * `"existing"` — the member predates this feature (backfilled by
      migration `20261101050000_backfill_first_run_goal_for_existing_users`).
    * `"submitting"` — a submit is in flight. It is the claim that makes a
      double submit post once; a failed post removes it again.

  A member is pending only while the key is ABSENT. Any value, including one
  this module does not know, means "not pending".

  ## Writes are single-key and atomic

  `users.preferences` is shared JSONB: the theme preference lives in the same
  map. `Platform.Accounts.update_user_preference/3` reads the user and writes
  back the WHOLE map, so two concurrent writers of different keys can clobber
  each other. Every write here is one `UPDATE ... SET preferences =
  COALESCE(preferences, '{}') || jsonb_build_object(key, value)` (or `- key`),
  which touches only this key and never reads the map into the BEAM.

  ## Burrow

  This module only FINDS the Burrow agent (`Platform.Agents.Burrow.get/0`) and
  requires the agent host to report it `:running`. It never creates, renames
  or starts an agent. It checks that BEFORE claiming or writing anything, so
  `:no_agent` leaves no channel behind.

  The example chips live in `@example_goals` so a later surface (e.g. an
  experiment) can wrap the list without touching templates.
  """

  import Ecto.Query, only: [from: 2]

  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Agents.Burrow
  alias Platform.Chat
  alias Platform.Chat.Participant
  alias Platform.Repo
  alias Platform.Tenancy

  @pref_key "first_run_goal"
  @submitting "submitting"
  @name_max 40
  @fallback_name "New goal"

  @example_goals [
    "Plan this week's work",
    "Start a project with my team",
    "Turn my to-do list into tasks"
  ]

  @doc "The `users.preferences` key this feature stores its state under."
  def pref_key, do: @pref_key

  @doc "The example goals offered as chips under the box."
  @spec example_goals() :: [String.t()]
  def example_goals, do: @example_goals

  @doc """
  True when `user` should see the goal box: a real, non-external user whose
  stored preferences have no `"first_run_goal"` key. Reads the preferences
  from the database, not from the struct, so a stale struct cannot re-show
  the box after a submit.
  """
  @spec pending?(User.t() | map() | nil) :: boolean()
  def pending?(%{id: user_id} = user) when is_binary(user_id) do
    Platform.UUID.valid?(user_id) and not Tenancy.external_user?(user) and
      not Map.has_key?(Accounts.get_user_preferences(user_id), @pref_key)
  end

  def pending?(_), do: false

  @doc """
  The Burrow agent when it exists AND the agent host reports it running.
  """
  @spec burrow() :: {:ok, Platform.Agents.Agent.t()} | {:error, :no_agent}
  def burrow do
    with %{} = agent <- Burrow.get(),
         true <- match?(%{state: :running}, Platform.AgentHost.status(agent)) do
      {:ok, agent}
    else
      _ -> {:error, :no_agent}
    end
  end

  @doc """
  Open a new channel with Burrow and post the member's goal into it.

  Returns `{:ok, space, message}`, where `space` is the new `kind: "channel"`
  space (see the moduledoc for why a channel and not a DM). On any error
  returns `{:error, reason}`, leaves the member pending, so they keep the
  box and their text, and leaves no channel behind:

    * `:blank` — nothing but whitespace was typed (nothing is written).
    * `:not_pending` — the member is external, or already submitted, skipped
      or is mid-submit. A second click of the same submit lands here, so one
      channel is created and the goal is posted once.
    * `:no_agent` — no Burrow, or Burrow is not running (nothing is written).
    * anything `Chat.create_channel/1`, `Chat.ensure_space_agent/3`,
      `Chat.set_agent_attention_policy/3` or `Chat.post_message/1` returns.
      A channel already created is deleted again
      (`Chat.delete_abandoned_channel/1`), also when the post raises.

  `opts[:post]` replaces `Chat.post_message/1` (a test seam for a failing post).
  """
  @spec submit(User.t(), String.t() | nil, keyword()) ::
          {:ok, Chat.Space.t(), Chat.Message.t()} | {:error, term()}
  def submit(%{id: user_id} = user, text, opts \\ []) when is_binary(user_id) do
    post = Keyword.get(opts, :post, &Chat.post_message/1)
    trimmed = String.trim(text || "")

    cond do
      trimmed == "" ->
        {:error, :blank}

      # Every id this function pins in a `where:` (the member's own
      # participant row, the preference UPDATEs) is this one or a row id
      # read back from the database, so one guard here covers them all.
      not Platform.UUID.valid?(user_id) ->
        {:error, :not_pending}

      Tenancy.external_user?(user) ->
        {:error, :not_pending}

      true ->
        with {:ok, agent} <- burrow(),
             :ok <- claim(user_id) do
          case safe_post_goal(user_id, agent, trimmed, post) do
            {:ok, space, msg} ->
              put_pref(user_id, "submitted")
              {:ok, space, msg}

            {:error, reason} ->
              release_claim(user_id)
              {:error, reason}
          end
        end
    end
  end

  @doc "Record that the member dismissed the box. Idempotent."
  @spec skip(User.t() | map()) :: :ok | {:error, :not_found}
  def skip(%{id: user_id}) when is_binary(user_id) do
    if Platform.UUID.valid?(user_id), do: put_pref(user_id, "skipped"), else: {:error, :not_found}
  end

  # A raise must not strand the "submitting" claim: release it, then re-raise.
  defp safe_post_goal(user_id, agent, content, post) do
    post_goal(user_id, agent, content, post)
  rescue
    e ->
      release_claim(user_id)
      reraise e, __STACKTRACE__
  end

  defp post_goal(user_id, agent, content, post) do
    with {:ok, space} <- create_goal_channel(user_id, content) do
      try do
        case fill_goal_channel(space, user_id, agent, content, post) do
          {:ok, _space, _msg} = ok ->
            ok

          {:error, reason} ->
            Chat.delete_abandoned_channel(space)
            {:error, reason}
        end
      rescue
        e ->
          Chat.delete_abandoned_channel(space)
          reraise e, __STACKTRACE__
      end
    end
  end

  # An ordinary org channel: `created_by` seats the member as its admin
  # (`Chat.create_space/1`), so they can rename it and add people. No
  # restriction rows: it is visible to the org on purpose (see moduledoc).
  defp create_goal_channel(user_id, content) do
    name = placeholder_name(content)

    Chat.create_channel(%{
      name: name,
      slug: goal_slug(name),
      org_id: member_org_id(user_id),
      created_by: user_id,
      metadata: %{"origin" => "first_run_goal"}
    })
  end

  defp fill_goal_channel(space, user_id, agent, content, post) do
    with {:ok, _roster} <- Chat.ensure_space_agent(space.id, agent.id, role: "principal"),
         {:ok, space} <-
           Chat.set_agent_attention_policy({:user, user_id}, space.id, "directed"),
         {:ok, participant} <- own_participant(space.id, user_id),
         {:ok, msg} <-
           post.(%{
             space_id: space.id,
             participant_id: participant.id,
             content_type: "text",
             content: content,
             metadata: %{"source" => "first_run_goal"}
           }) do
      {:ok, space, msg}
    end
  end

  # The member's first internal org, else the root org.
  defp member_org_id(user_id) do
    %{id: user_id}
    |> Tenancy.list_user_memberships()
    |> Enum.find(&(&1.external != true))
    |> case do
      %{org_id: org_id} when is_binary(org_id) ->
        org_id

      _ ->
        case Tenancy.get_root_org() do
          %{id: id} -> id
          nil -> nil
        end
    end
  end

  @doc """
  The channel name a goal opens with, until Burrow helps the member pick a
  better one: the first line of the trimmed goal, whitespace collapsed, cut
  at a word boundary to at most #{@name_max} characters, first letter
  upcased, no trailing punctuation or emoji. A goal with no letter or digit in it
  (e.g. only emoji) is `"New goal"`.

      iex> Platform.Onboarding.FirstRunGoal.placeholder_name("  plan   this week's work!  ")
      "Plan this week's work"
  """
  @spec placeholder_name(String.t() | nil) :: String.t()
  def placeholder_name(goal) when is_binary(goal) do
    name =
      goal
      |> String.trim()
      |> String.split(~r/\R/u, parts: 2)
      |> hd()
      |> String.split(~r/\s+/u, trim: true)
      |> cut_words(@name_max)
      |> String.replace(trailing_junk(), "")
      |> upcase_first()

    if name =~ ~r/[\p{L}\p{N}]/u, do: name, else: @fallback_name
  end

  def placeholder_name(_goal), do: @fallback_name

  # Trailing punctuation, emoji and their joiners/selectors/skin tones. Closing
  # brackets and quotes stay ("Fix the login bug (urgent)"), as do maths
  # symbols ("Learn C++"). A function, not an attribute: a compiled regex
  # cannot be stored in a module attribute on OTP 28.
  defp trailing_junk,
    do: ~r/[\p{Po}\p{Pd}\p{Ps}\p{Pi}\p{Pc}\p{So}\p{Sk}\x{FE0F}\x{200D}\s]+$/u

  # Whole words while they fit; a single first word longer than `max` is cut.
  defp cut_words([], _max), do: ""

  defp cut_words([first | rest], max) do
    if String.length(first) > max do
      String.slice(first, 0, max)
    else
      Enum.reduce_while(rest, first, fn word, acc ->
        next = acc <> " " <> word
        if String.length(next) <= max, do: {:cont, next}, else: {:halt, acc}
      end)
    end
  end

  defp upcase_first(""), do: ""

  defp upcase_first(name) do
    {first, rest} = String.split_at(name, 1)
    String.upcase(first) <> rest
  end

  # The settings form's slug rule (settings_component.ex `settings_save`), plus
  # a random suffix so two members with the same chip goal never collide on
  # `chat_spaces_unique_org_slug`, and never a system-reserved prefix.
  defp goal_slug(name) do
    base =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9\s-]/, "")
      |> String.replace(~r/[\s-]+/, "-")
      |> String.trim("-")

    base =
      cond do
        base == "" -> "goal"
        Chat.reserved_slug_prefix?(base <> "-") -> "goal-" <> base
        true -> base
      end

    base <> "-" <> Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)
  end

  defp own_participant(space_id, user_id) do
    from(p in Participant,
      where:
        p.space_id == ^space_id and p.participant_type == "user" and
          p.participant_id == ^user_id,
      limit: 1
    )
    |> Repo.one()
    |> case do
      %Participant{} = p -> {:ok, p}
      nil -> {:error, :no_participant}
    end
  end

  # ── Single-key atomic writes on users.preferences ───────────────────────

  # Take the submit: set the key to "submitting" only while it is absent. One
  # statement, so of two concurrent submits exactly one updates a row.
  defp claim(user_id) do
    {count, _} =
      from(u in User,
        where:
          u.id == ^user_id and
            not fragment("COALESCE(?, '{}'::jsonb) \\? ?", u.preferences, ^@pref_key),
        update: [
          set: [
            preferences:
              fragment(
                "COALESCE(?, '{}'::jsonb) || jsonb_build_object(?::text, ?::text)",
                u.preferences,
                ^@pref_key,
                ^@submitting
              ),
            updated_at: ^now()
          ]
        ]
      )
      |> Repo.update_all([])

    if count == 1, do: :ok, else: {:error, :not_pending}
  end

  # Undo a claim after a failed post. Only removes OUR in-flight value, so a
  # concurrent skip (or anything else written meanwhile) stays.
  defp release_claim(user_id) do
    from(u in User,
      where:
        u.id == ^user_id and
          fragment("?->>? = ?", u.preferences, ^@pref_key, ^@submitting),
      update: [
        set: [
          preferences: fragment("? - ?", u.preferences, ^@pref_key),
          updated_at: ^now()
        ]
      ]
    )
    |> Repo.update_all([])

    :ok
  end

  defp put_pref(user_id, value) do
    from(u in User,
      where: u.id == ^user_id,
      update: [
        set: [
          preferences:
            fragment(
              "COALESCE(?, '{}'::jsonb) || jsonb_build_object(?::text, ?::text)",
              u.preferences,
              ^@pref_key,
              ^value
            ),
          updated_at: ^now()
        ]
      ]
    )
    |> Repo.update_all([])
    |> case do
      {1, _} -> :ok
      {0, _} -> {:error, :not_found}
    end
  end

  defp now, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
end
