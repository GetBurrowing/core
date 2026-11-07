defmodule Platform.Onboarding.MemberWelcome do
  @moduledoc """
  The welcome the install's Burrow agent gives each new person (task
  01a1b6de stage 2): one message in the person's direct conversation with
  Burrow, listing the setup steps in order and who to ask.

  ## Once per person, keyed on the user id

  `ensure/1` runs when a person signs in (`PlatformWeb.AuthController`, for a
  full internal admission) and may run again from anywhere; it posts at most
  once per user. The claim is one key in `users.preferences`,
  `"burrow_welcome"`, written with `Platform.Accounts.claim_preference/3`
  (one UPDATE, only while the key is absent), so of two concurrent calls one
  posts. Its values:

    * `"posting"`: a post is in flight. A failed post removes it again
      (`Platform.Accounts.release_preference/3`), so the next sign-in retries.
    * the welcome message's id, once posted.

  ## The record of "shown who to ask"

  The welcome carries the owner and admins (`Platform.Agents.Burrow.admins/0`,
  the list `Burrow.admins_section/0` renders into Burrow's instructions).
  `shown?/1` is true only when the stored id names a real, undeleted message
  with `metadata["source"] == "member_welcome"`, so the checklist's "knows who
  to ask" step reads a row, never a flag the person set.

  ## Boundaries

  Reads and writes go through public functions of `Platform.Accounts`,
  `Platform.Agents.Burrow` and `Platform.Chat` only; this module makes no
  `Repo` call. It never creates or starts an agent: without a Burrow agent it
  returns `{:error, :no_agent}` and claims nothing. An external user gets no
  welcome (`Chat.find_or_create_agent_dm/2` refuses them).
  """

  require Logger

  alias Platform.Accounts
  alias Platform.Agents.Burrow
  alias Platform.Chat

  @pref_key "burrow_welcome"
  @posting "posting"
  @source "member_welcome"

  @doc "The `users.preferences` key the welcome claim is stored under."
  def pref_key, do: @pref_key

  @doc "The `metadata[\"source\"]` of a welcome message."
  def source, do: @source

  @doc """
  Post the welcome for `user` (a user struct or map with `:id`, or an id)
  unless it was already posted.

    * `{:ok, message}` when this call posted it.
    * `{:ok, :already}` when it was posted, or is being posted, already.
    * `{:error, :not_found}` for an unknown user.
    * `{:error, :no_agent}` when the install has no Burrow agent yet.
    * `{:error, reason}` from `Chat.find_or_create_agent_dm/2` or
      `Chat.post_message/2`; the claim is released.
  """
  @spec ensure(map() | binary() | nil) ::
          {:ok, Chat.Message.t() | :already} | {:error, term()}
  def ensure(%{id: user_id}) when is_binary(user_id), do: ensure(user_id)

  def ensure(user_id) when is_binary(user_id) do
    with %{} = user <- Accounts.get_user(user_id) || {:error, :not_found},
         %{} = agent <- Burrow.get() || {:error, :no_agent} do
      case Accounts.claim_preference(user.id, @pref_key, @posting) do
        :ok -> post_claimed(user, agent)
        {:error, :taken} -> {:ok, :already}
      end
    end
  end

  def ensure(_), do: {:error, :not_found}

  defp post_claimed(user, agent) do
    result =
      try do
        post(user, agent)
      rescue
        error ->
          _ = Accounts.release_preference(user.id, @pref_key, @posting)
          reraise error, __STACKTRACE__
      end

    case result do
      {:ok, message} ->
        _ = Accounts.swap_preference(user.id, @pref_key, @posting, message.id)
        {:ok, message}

      {:error, reason} ->
        _ = Accounts.release_preference(user.id, @pref_key, @posting)
        Logger.warning("[MemberWelcome] welcome not posted: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp post(user, agent) do
    with {:ok, space} <- Chat.find_or_create_agent_dm(agent.id, user.id),
         %{} = participant <-
           Chat.get_agent_participant(space.id, agent) || {:error, :no_participant} do
      admins = Burrow.admins()

      Chat.post_message(%{
        space_id: space.id,
        participant_id: participant.id,
        content_type: "text",
        content: welcome_text(user, agent.name, admins),
        metadata: %{
          "source" => @source,
          "welcome_user_id" => user.id,
          "admin_ids" => Enum.map(admins, & &1.id)
        }
      })
    end
  end

  @doc """
  True when `user`'s welcome was posted and is still a real message: the
  stored id names an undeleted message whose `metadata["source"]` is
  `"member_welcome"` and whose `metadata["welcome_user_id"]` is this user.
  """
  @spec shown?(map() | binary() | nil) :: boolean()
  def shown?(%{id: user_id}) when is_binary(user_id), do: shown?(user_id)

  def shown?(user_id) when is_binary(user_id) do
    with message_id when is_binary(message_id) and message_id != @posting <-
           Map.get(Accounts.get_user_preferences(user_id), @pref_key),
         %{deleted_at: nil, metadata: %{"source" => @source, "welcome_user_id" => ^user_id}} <-
           Chat.get_message(message_id) do
      true
    else
      _ -> false
    end
  end

  def shown?(_), do: false

  @doc """
  The welcome text for `user`, from `agent_name`, naming `admins` (owner
  first, as `Burrow.admins/0` returns them). The person themself is left out
  of who to ask. Plain words, no terminal, and no API key: a member's AI
  login is their own subscription.
  """
  @spec welcome_text(map(), String.t(), [%{id: String.t(), name: String.t()}]) :: String.t()
  def welcome_text(user, agent_name, admins) do
    first_name =
      case String.split(Map.get(user, :name) || "", " ", trim: true) do
        [first | _] -> " " <> first
        [] -> ""
      end

    """
    Welcome to Burrow#{first_name}. I'm #{agent_name}, the agent for everyone here. I'll help you get set up, one step at a time:

    1. Turn on notifications, so you hear when someone needs you.
    2. Get the Burrow app on your phone and sign in with the same account.
    3. Connect your AI with your own ChatGPT or Claude subscription.
    4. Join a channel your team uses.

    #{who_to_ask(user, admins)}

    Reply here when you're ready and we'll start with the first step. You can ask me "how do I..." about anything in Burrow, here, any time.
    """
    |> String.trim_trailing()
  end

  defp who_to_ask(user, admins) do
    user_id = Map.get(user, :id)

    {owner, others} =
      case admins do
        [owner | rest] -> {owner, rest}
        [] -> {nil, []}
      end

    others = Enum.reject(others, &(&1.id == user_id))

    parts =
      [
        owner && owner.id != user_id && "#{owner.name} (owner)",
        others != [] && "#{Enum.map_join(others, ", ", & &1.name)} (#{admin_word(others)})"
      ]
      |> Enum.filter(& &1)

    case parts do
      [] -> "You run this install, so people will come to you with questions."
      parts -> "Who to ask on this install: " <> Enum.join(parts, "; ") <> "."
    end
  end

  defp admin_word([_]), do: "admin"
  defp admin_word(_), do: "admins"
end
