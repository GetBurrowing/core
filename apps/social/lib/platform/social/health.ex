defmodule Platform.Social.Health do
  @moduledoc """
  Account health (Social authoring 9/11, task 01a16c51-9cc5). Deterministic:
  it lists reasons and never computes a score. ONE computation feeds both
  the top bar's health dot (`PlatformWeb.SocialTopBar.health/2`) and the
  Connections rows (`PlatformWeb.SocialConnectionsTab`), so the two always
  agree.

  ## States and reasons

  `account/2` answers `%{state, reasons, last_published_at,
  last_published_url, last_failure, failure_count}`. Each reason is `%{code, tone, text,
  fix}`; `tone` is `:down`, `:warn` or `:info` and `fix` is at most ONE
  action, `:connect` (Connect/Reconnect), `{:retry, post_id}` (retry a
  refused publish) or nil. The state is the worst tone; `:info` reasons
  (draft-only) never make an account unhealthy.

    * `:down`: removed (archived) here, never connected (pending connect),
      or disconnected at the platform (`status` `"reauth_needed"`).
    * `:warn`: a publish failed at the vendor or was refused before it in
      the last 7 days (with its plain reason), or an Instagram account
      whose type is known to be `"personal"` (`Platform.Social.MediaRules`
      refuses Reels there).
    * `:info`: draft-only.

  `profile/1` rolls a list of `{account, health}` up: rows ordered down,
  then warn, then ok, then by name, and the worst state. An empty profile
  is `:ok`.

  ## The disconnect alert

  `account_disconnected/2` is the ONE writer of `disconnect_alerted_at`: a
  single conditional `UPDATE ... WHERE disconnect_alerted_at IS NULL` sets
  the marker and `status = "reauth_needed"` together, so exactly one caller
  wins and alerts, whatever races it. The winner emits one inbox row per
  recipient (`recipients/2`: the profile's `notify_user_ids` when set, else
  its approvers, each re-checked through `Platform.Social.approver_check/3`),
  kind `social_account_disconnected`, linking to Connections for that
  profile. A second failure, a replayed webhook or a sweep finds the marker
  set and alerts nobody. A move back to `"connected"` clears the marker
  (`Platform.Social.Account.changeset/2`, `account_reconnected/1`), which
  re-arms it.

  Triggers: Zernio's `account.disconnected` webhook and a `post.failed`
  entry with `errorCategory` `auth_expired`
  (https://zernio.com/openapi.json v1.350.1, `WebhookPayloadAccountDisconnected`),
  and a publish the adapter answers with `{:error, :account_disconnected}`
  or `{:error, {:account_disconnected, message}}` (`auth_failure?/1`).
  """

  import Ecto.Query, only: [from: 2]

  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{Account, Post, Profile}

  @window_days 7
  @rank %{down: 0, warn: 1, ok: 2}

  @platform_labels %{
    "x" => "X",
    "linkedin" => "LinkedIn",
    "tiktok" => "TikTok",
    "instagram" => "Instagram",
    "youtube" => "YouTube"
  }

  @kind "social_account_disconnected"
  @source_type "social_account"

  @type state :: :ok | :warn | :down
  @type reason :: %{code: atom(), tone: :down | :warn | :info, text: String.t(), fix: term()}
  @type t :: %{
          state: state(),
          reasons: [reason()],
          last_published_at: DateTime.t() | nil,
          last_published_url: String.t() | nil,
          last_failure: Post.t() | nil,
          failure_count: non_neg_integer()
        }

  @doc "The inbox kind of the disconnect alert."
  def inbox_kind, do: @kind

  @doc "The inbox source type of the disconnect alert (the account)."
  def source_type, do: @source_type

  @doc "The window, in days, a failed or refused publish counts for."
  def window_days, do: @window_days

  # ── Health ───────────────────────────────────────────────────────────

  @doc """
  The posts health reads for `accounts`, in two queries: per account, the
  failed (not cancelled) or refused posts last written in the window, newest
  first, and the latest published post. Callers pass accounts they already
  read through a scope; nothing else is widened.
  """
  @spec facts([Account.t()], DateTime.t()) :: %{Ecto.UUID.t() => map()}
  def facts(accounts, now \\ DateTime.utc_now())
  def facts([], _now), do: %{}

  def facts(accounts, now) do
    ids = Enum.map(accounts, & &1.id)
    since = DateTime.add(now, -@window_days, :day)

    failures =
      Repo.all(
        from(p in Post,
          where: p.account_id in ^ids and p.updated_at >= ^since,
          where:
            (p.status == "failed" and
               (is_nil(p.error) or p.error != "cancelled before publishing")) or
              (p.status == "approved" and not is_nil(p.refused_reason)),
          order_by: [desc: p.updated_at, desc: p.id]
        )
      )
      |> Enum.group_by(& &1.account_id)

    published =
      Repo.all(
        from(p in Post,
          where: p.account_id in ^ids and p.status == "published",
          distinct: p.account_id,
          order_by: [asc: p.account_id, desc: coalesce(p.published_at, p.updated_at), desc: p.id]
        )
      )
      |> Map.new(&{&1.account_id, &1})

    Map.new(ids, fn id ->
      {id, %{failures: Map.get(failures, id, []), last_published: Map.get(published, id)}}
    end)
  end

  @doc "One account's health from its `facts/2` entry (deterministic)."
  @spec account(Account.t(), map() | nil) :: t()
  def account(%Account{} = account, facts) do
    facts = facts || %{failures: [], last_published: nil}
    failures = facts.failures
    last_published = facts.last_published
    reasons = reasons(account, failures)

    %{
      state: worst(reasons),
      reasons: reasons,
      last_published_at:
        last_published && (last_published.published_at || last_published.updated_at),
      last_published_url: last_published && last_published.external_url,
      last_failure: List.first(failures),
      failure_count: length(failures)
    }
  end

  @doc """
  Rolls `[{account, health}]` up into `%{state, accounts}`: the rows ordered
  down, warn, ok, then by name (handle, then platform), and the worst
  state. No accounts is `:ok`.
  """
  @spec profile([{Account.t(), t()}]) :: %{state: state(), accounts: [{Account.t(), t()}]}
  def profile(rows) when is_list(rows) do
    sorted =
      Enum.sort_by(rows, fn {account, health} ->
        {Map.fetch!(@rank, health.state), String.downcase(account.handle || ""), account.platform,
         account.id}
      end)

    state =
      case sorted do
        [] -> :ok
        [{_account, health} | _] -> health.state
      end

    %{state: state, accounts: sorted}
  end

  @doc "Health for `accounts`, rolled up per profile: `%{profile_id => profile/1}`."
  @spec by_profile([Account.t()], DateTime.t()) :: %{Ecto.UUID.t() => map()}
  def by_profile(accounts, now \\ DateTime.utc_now()) do
    facts = facts(accounts, now)

    accounts
    |> Enum.group_by(& &1.profile_id)
    |> Map.new(fn {profile_id, list} ->
      {profile_id, profile(Enum.map(list, &{&1, account(&1, Map.get(facts, &1.id))}))}
    end)
  end

  defp reasons(account, failures) do
    [
      connection_reason(account),
      failure_reason(failures),
      type_reason(account),
      mode_reason(account)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp connection_reason(%Account{archived_at: %DateTime{}}),
    do: %{code: :archived, tone: :down, text: "Removed from this profile.", fix: nil}

  defp connection_reason(%Account{status: "connected"}), do: nil

  defp connection_reason(%Account{status: "reauth_needed"}),
    do: %{
      code: :disconnected,
      tone: :down,
      text: "Disconnected at the platform. Nothing posts until it is reconnected.",
      fix: :connect
    }

  defp connection_reason(%Account{}),
    do: %{
      code: :not_connected,
      tone: :down,
      text: "Not connected yet. Nothing posts until it is connected.",
      fix: :connect
    }

  defp failure_reason([]), do: nil

  defp failure_reason([%Post{status: "approved"} = post | _]),
    do: %{
      code: :refused,
      tone: :warn,
      text: "Last publish was not sent: #{plain(post.error, "refused before publishing")}",
      fix: {:retry, post.id}
    }

  defp failure_reason([%Post{} = post | _]),
    do: %{
      code: :failed,
      tone: :warn,
      text: "Last publish failed: #{plain(post.error, "failed at the platform")}",
      fix: nil
    }

  defp type_reason(%Account{platform: "instagram", platform_account_type: "personal"}),
    do: %{
      code: :personal_instagram,
      tone: :warn,
      text:
        "Instagram personal account: Reels need a Business or Creator account. Switch it in Instagram, then reconnect.",
      fix: :connect
    }

  defp type_reason(_account), do: nil

  defp mode_reason(%Account{approval_mode: "draft_only"}),
    do: %{
      code: :draft_only,
      tone: :info,
      text: "Draft-only: posts are drafted here and never published.",
      fix: nil
    }

  defp mode_reason(_account), do: nil

  defp worst(reasons) do
    tones = Enum.map(reasons, & &1.tone)

    cond do
      :down in tones -> :down
      :warn in tones -> :warn
      true -> :ok
    end
  end

  defp plain(text, fallback) when is_binary(text) do
    case String.trim(text) do
      "" -> sentence(fallback)
      trimmed -> sentence(trimmed)
    end
  end

  defp plain(_text, fallback), do: sentence(fallback)

  defp sentence(text) do
    text = String.slice(text, 0, 300)
    if String.ends_with?(text, [".", "!", "?"]), do: text, else: text <> "."
  end

  # ── Disconnect alert ─────────────────────────────────────────────────

  @doc """
  Whether a publish error means the platform account itself lost its
  authorization (as opposed to the Zernio key, the content or a limit).
  """
  @spec auth_failure?(term()) :: boolean()
  def auth_failure?(:account_disconnected), do: true
  def auth_failure?({:account_disconnected, _message}), do: true
  def auth_failure?(%{auth?: true}), do: true
  def auth_failure?(_reason), do: false

  @doc """
  Marks the account disconnected and, the FIRST time only since it was last
  connected, alerts its recipients. Returns `{:ok, :alerted, user_ids}`,
  `{:ok, :already_alerted}` (nothing written, nobody alerted) or
  `{:error, :not_found}` (unknown, archived, or never connected).
  """
  @spec account_disconnected(Account.t() | Ecto.UUID.t(), String.t() | nil) ::
          {:ok, :alerted, [Ecto.UUID.t()]} | {:ok, :already_alerted} | {:error, :not_found}
  def account_disconnected(%Account{id: id}, reason), do: account_disconnected(id, reason)

  def account_disconnected(account_id, reason) when is_binary(account_id) do
    now = DateTime.utc_now()

    query =
      from(a in Account,
        where:
          a.id == ^account_id and is_nil(a.archived_at) and not is_nil(a.provider_account_ref),
        where: is_nil(a.disconnect_alerted_at),
        select: a
      )

    case Repo.update_all(query,
           set: [disconnect_alerted_at: now, status: "reauth_needed", updated_at: now]
         ) do
      {1, [account]} ->
        {:ok, :alerted, alert(account, reason)}

      {0, _} ->
        if Repo.exists?(
             from(a in Account,
               where:
                 a.id == ^account_id and is_nil(a.archived_at) and
                   not is_nil(a.disconnect_alerted_at)
             )
           ),
           do: {:ok, :already_alerted},
           else: {:error, :not_found}
    end
  end

  @doc """
  The vendor says the account is connected again: a `"reauth_needed"` row
  goes back to `"connected"` and its alert is re-armed. Any other row is
  left alone (`{:ok, :noop}`).
  """
  @spec account_reconnected(Account.t() | Ecto.UUID.t()) :: {:ok, :reconnected | :noop}
  def account_reconnected(%Account{id: id}), do: account_reconnected(id)

  def account_reconnected(account_id) when is_binary(account_id) do
    now = DateTime.utc_now()

    query =
      from(a in Account,
        where: a.id == ^account_id and is_nil(a.archived_at) and a.status == "reauth_needed"
      )

    case Repo.update_all(query,
           set: [status: "connected", disconnect_alerted_at: nil, updated_at: now]
         ) do
      {1, _} -> {:ok, :reconnected}
      _ -> {:ok, :noop}
    end
  end

  @doc """
  Who is alerted: the profile's `notify_user_ids` when set, else its
  approvers; each must pass `Platform.Social.approver_check/3` now.
  """
  @spec recipients(Profile.t()) :: [Ecto.UUID.t()]
  def recipients(%Profile{} = profile) do
    candidates =
      case profile.notify_user_ids do
        [_ | _] = ids -> ids
        _ -> profile.approver_user_ids || []
      end

    candidates
    |> Enum.uniq()
    |> Enum.filter(&(Social.approver_check(profile.org_id, profile, &1) == :ok))
  end

  @doc "Where the alert opens: Connections on that profile."
  @spec connections_url(Profile.t() | Ecto.UUID.t()) :: String.t()
  def connections_url(%Profile{id: id}), do: connections_url(id)

  def connections_url(profile_id) when is_binary(profile_id),
    do: "/m/social?" <> URI.encode_query([{"profile", profile_id}, {"tab", "connections"}])

  defp alert(%Account{} = account, reason) do
    case Repo.get(Profile, account.profile_id) do
      %Profile{} = profile ->
        label = Map.get(@platform_labels, account.platform, account.platform)
        handle = if is_binary(account.handle) and account.handle != "", do: " #{account.handle}"

        for user_id <- recipients(profile),
            match?(
              {:ok, _},
              Platform.Inbox.emit(%{
                user_id: user_id,
                kind: @kind,
                source_type: @source_type,
                source_id: account.id,
                title: "#{label}#{handle} on #{profile.name} disconnected",
                body: plain(reason, "Reconnect it in Connections to keep posting"),
                url: connections_url(profile)
              })
            ),
            do: user_id

      nil ->
        []
    end
  end
end
