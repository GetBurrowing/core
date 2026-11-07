defmodule Platform.Onboarding.PersonSetup do
  @moduledoc """
  The person setup checklist (task 01a1b6de stage 2): for one member, which
  setup steps are done, which are still to do, and which are stuck.

  Every step is computed from the install's own rows, never from anything the
  person says about themself:

  | step             | done when                                                     |
  | ---------------- | ------------------------------------------------------------- |
  | `:signed_in`     | a login record exists (`Accounts.first_sign_in_at/1`)         |
  | `:notifications` | a web push subscription row (`Push.web_subscribed?/1`)        |
  | `:phone_app`     | a native push token row (`Push.native_platforms/1`)           |
  | `:ai_login`      | an owned agent on a subscription login (`NativeLogin.subscription_logged_in?/1`) |
  | `:channels`      | a participant row in a channel (`Chat.list_member_space_ids/2`, `kind: "channel"`) |
  | `:who_to_ask`    | the welcome naming the owner and admins was posted (`MemberWelcome.shown?/1`) |

  A `users` row alone is not a sign-in: an invite creates it first.

  An API-key connection never counts as the AI login:
  `NativeLogin.subscription_logged_in?/1` refuses any agent with a saved key.

  `:phone_app` is `:done` or `:unknown`, never `:todo` or `:stuck`: no token
  row says nothing about whether the app is installed (push may simply be
  off), so its absence is not evidence of a missing step.

  ## States

  Each step is `:done`, `:todo` or `:stuck` (`:phone_app` aside). A `:todo`
  step is `:stuck` once more than `stuck_after_seconds` have passed since the
  person's first sign-in. Before a first sign-in nothing is stuck.

  The threshold is data: `config :platform, Platform.Onboarding.PersonSetup,
  stuck_after_seconds:` (config/config.exs), or `opts[:stuck_after_seconds]`.
  When neither is set nothing is ever stuck; there is no constant fallback.

  ## Shape

  `status/2` reads the rows (`facts/1`) and hands them to `evaluate/2`, which
  is pure: the same facts, `now` and threshold give the same answer.

  ## Boundaries

  Other contexts are read only through their public functions
  (`Platform.Accounts`, `Platform.Push`, `Platform.Agents.NativeLogin`,
  `Platform.Chat`, and `Platform.Onboarding.MemberWelcome` for the welcome
  posted with `Platform.Agents.Burrow.admins/0`). No `Repo` call here.
  """

  alias Platform.Accounts
  alias Platform.Agents.NativeLogin
  alias Platform.Chat
  alias Platform.Onboarding.MemberWelcome
  alias Platform.Push

  @steps [:signed_in, :notifications, :phone_app, :ai_login, :channels, :who_to_ask]

  @type step :: :signed_in | :notifications | :phone_app | :ai_login | :channels | :who_to_ask
  @type state :: :done | :todo | :stuck | :unknown

  @type facts :: %{
          user_id: binary(),
          first_sign_in_at: DateTime.t() | nil,
          notifications: boolean(),
          phone_app: boolean(),
          ai_login: boolean(),
          channels: boolean(),
          who_to_ask: boolean()
        }

  @type t :: %{
          user_id: binary(),
          first_sign_in_at: DateTime.t() | nil,
          steps: [%{step: step(), state: state()}],
          next: step() | nil,
          stuck: [step()],
          complete?: boolean()
        }

  @doc "The steps, in the order Burrow walks a person through them."
  @spec steps() :: [step()]
  def steps, do: @steps

  @doc """
  The configured stuck threshold in seconds, or nil when unset (then nothing
  is stuck).
  """
  @spec stuck_after_seconds() :: pos_integer() | nil
  def stuck_after_seconds do
    case Keyword.get(Application.get_env(:platform, __MODULE__, []), :stuck_after_seconds) do
      seconds when is_integer(seconds) and seconds > 0 -> seconds
      _ -> nil
    end
  end

  @doc """
  The checklist for `member` (a user struct or map with `:id`, or a user id),
  or nil for an unknown user.

  `opts`: `:now` (default `DateTime.utc_now/0`) and `:stuck_after_seconds`
  (default `stuck_after_seconds/0`).
  """
  @spec status(map() | binary() | nil, keyword()) :: t() | nil
  def status(member, opts \\ [])

  def status(%{id: user_id}, opts) when is_binary(user_id), do: status(user_id, opts)

  def status(user_id, opts) when is_binary(user_id) do
    case facts(user_id) do
      nil -> nil
      facts -> evaluate(facts, opts)
    end
  end

  def status(_member, _opts), do: nil

  @doc """
  The rows behind the checklist for `user_id`, or nil for an unknown user.
  """
  @spec facts(binary()) :: facts() | nil
  def facts(user_id) when is_binary(user_id) do
    case Accounts.get_user(user_id) do
      nil ->
        nil

      user ->
        %{
          user_id: user.id,
          first_sign_in_at: Accounts.first_sign_in_at(user.id),
          notifications: Push.web_subscribed?(user.id),
          phone_app: Push.native_platforms(user.id) != [],
          ai_login: NativeLogin.subscription_logged_in?(user.id),
          channels: Chat.list_member_space_ids(user.id, kind: "channel") != [],
          who_to_ask: MemberWelcome.shown?(user.id)
        }
    end
  end

  @doc """
  The checklist from `facts`. Pure and deterministic.

  `opts`: `:now` (default `DateTime.utc_now/0`) and `:stuck_after_seconds`
  (default `stuck_after_seconds/0`; nil means nothing is stuck).
  """
  @spec evaluate(facts(), keyword()) :: t()
  def evaluate(%{user_id: user_id, first_sign_in_at: signed_in_at} = facts, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    threshold = Keyword.get_lazy(opts, :stuck_after_seconds, &stuck_after_seconds/0)
    late? = late?(signed_in_at, now, threshold)

    steps =
      Enum.map(@steps, fn step ->
        %{step: step, state: state(step, facts, late?)}
      end)

    open = for %{step: step, state: state} <- steps, state in [:todo, :stuck], do: step

    %{
      user_id: user_id,
      first_sign_in_at: signed_in_at,
      steps: steps,
      next: List.first(open),
      stuck: for(%{step: step, state: :stuck} <- steps, do: step),
      complete?: open == []
    }
  end

  defp state(:signed_in, %{first_sign_in_at: nil}, _late?), do: :todo
  defp state(:signed_in, _facts, _late?), do: :done
  defp state(:phone_app, %{phone_app: true}, _late?), do: :done
  defp state(:phone_app, _facts, _late?), do: :unknown

  defp state(step, facts, late?) do
    cond do
      Map.fetch!(facts, step) == true -> :done
      late? -> :stuck
      true -> :todo
    end
  end

  # Stuck only AFTER a first sign-in, and only strictly past the threshold.
  defp late?(nil, _now, _threshold), do: false
  defp late?(_signed_in_at, _now, nil), do: false

  defp late?(%DateTime{} = signed_in_at, %DateTime{} = now, threshold)
       when is_integer(threshold) do
    DateTime.diff(now, signed_in_at, :second) > threshold
  end
end
