defmodule Platform.Social.Publishing do
  @moduledoc """
  The ONE guarded publish path (task 01a140a9, Social 2/7). Vendor-neutral:
  the adapter comes from `Platform.Social.Publisher.impl/0`.

  ## The publish guard

  `publish_post/2` is the only caller of a publisher's `publish/2` in
  `apps/social/lib` (a test greps for it). Inside one transaction it:

    1. re-reads the post through the org scope with `FOR UPDATE`, so status
       and approver come from the database, never the caller's struct;
    2. refuses `{:error, :not_approved}` unless `publishable?/1`: status
       `approved`, an `approved_by_user_id`, and that id resolving through
       `Platform.Accounts.get_user/1` to a user who is not archived;
    3. refuses an archived account;
    4. checks `Platform.Social.MediaRules`;
    5. checks `Platform.Social.RateLimit`;

  and only then builds the vendor-neutral request and calls the adapter.
  Step 2 never changes the row. A refusal at steps 3 to 5, or no configured
  publisher, records why on the row under the same lock, in the same
  transaction (task 01a165f1): `refused_reason`, `refused_at`, a one-sentence
  `error` and, for the rate limit only, `retry_after` (the end of the
  current window). The status stays `approved`, so a retry is simply
  `publish_post/2` again, through the full guard. Every later `scheduled`,
  `published` or `failed` write clears the three refusal fields. The row lock is held across the vendor
  call, so a concurrent `publish_post/2` on the same post waits and then
  finds it no longer `approved`.

  ## Outcomes

  `apply_outcome/2` is the one transition from a vendor outcome, shared by
  `refresh_status/2` and the status webhook: it moves only `approved` or
  `scheduled` posts to `published` or `failed`. A post already `published`
  or `failed` answers `{:ok, :noop}` and is not written, so replayed
  deliveries are idempotent.

  Every committed move to `published` or `failed` (publish, cancel, outcome)
  is reported to `Platform.Social.TaskBridge.post_changed/1` (Social 6/7),
  which writes a social task's post URLs once all its drafts are terminal.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset
  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{Account, MediaRules, Post, Publisher, RateLimit}

  @default_ai_disclosure "Made with AI"
  @max_error_length 1_000

  # ── Publish ──────────────────────────────────────────────────────────

  @doc """
  Publishes (or schedules, when `scheduled_at` is set) an approved post.

  Returns `{:ok, post}` (now `scheduled` or `published`), or one of:
  `{:error, :not_found}`, `{:error, :not_approved}`,
  `{:error, :account_archived}`, `{:error, {:media_rejected, messages}}`,
  `{:error, :rate_limited}`, `{:error, :publisher_not_configured}`, or
  `{:error, {:publish_failed, reason}}` after the adapter refused, with the
  row moved to `failed`.

  `:not_found` and `:not_approved` write nothing. The other four refusals
  keep the post `approved` and write `refused_reason`, `refused_at`, a
  plain-sentence `error` and (rate limit only) `retry_after`; the return
  value is the same `{:error, reason}`.
  """
  @spec publish_post(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, Post.t()} | {:error, term()}
  def publish_post(org_id, post_id) do
    {:ok, result} =
      Repo.transaction(fn ->
        with {:ok, post} <- lock(org_id, post_id),
             :ok <- guard(post) do
          now_ms = System.system_time(:millisecond)

          post
          |> attempt(org_id, now_ms)
          |> record_refusal(post, org_id, now_ms)
        end
      end)

    terminal_written(result, post_id)
  end

  # ── Retry (task 01a165f1, stage 2) ───────────────────────────────────

  @doc """
  A human's retry of an approved post whose publish was refused before the
  vendor (`refused_reason` set). Refused, writing nothing, unless:

    * `actor_user_id` passes `Platform.Social.post_approver_check/4` on the
      post's account RIGHT NOW (its refusal is returned: an agent id is
      `:not_a_human`, a non-approver `:not_an_approver`, an archived user
      `:approver_archived`, ...);
    * the post is `approved` with a `refused_reason`, else
      `{:error, :not_refused}`;
    * a `rate_limited` post's `retry_after` has passed, else
      `{:error, {:wait_until, retry_after}}`.

  Then it is exactly `publish_post/2`, so the lock, the approval guard,
  `MediaRules` and `RateLimit` all run again; a cause still unfixed records
  the refusal afresh. The post's approval card is re-rendered after the
  attempt. There is no agent tool for this.
  """
  @spec retry_publish(Ecto.UUID.t(), Ecto.UUID.t(), term()) ::
          {:ok, Post.t()} | {:error, term()}
  def retry_publish(org_id, post_id, actor_user_id) do
    with %Post{} = post <- Social.get_post(org_id, post_id) || {:error, :not_found},
         {:ok, account} <- account_any(org_id, post),
         %Social.Profile{} = profile <-
           Social.get_profile(org_id, account.profile_id) || {:error, :not_found},
         :ok <- Social.post_approver_check(org_id, profile, account, actor_user_id),
         :ok <- retryable(post, DateTime.utc_now()) do
      result = publish_post(org_id, post.id)
      Platform.Social.Approvals.rerender_latest(post.id)
      result
    end
  end

  defp retryable(%Post{status: "approved", refused_reason: "rate_limited"} = post, now) do
    case post.retry_after do
      %DateTime{} = at ->
        if DateTime.compare(now, at) == :lt, do: {:error, {:wait_until, at}}, else: :ok

      nil ->
        :ok
    end
  end

  defp retryable(%Post{status: "approved", refused_reason: reason}, _now) when is_binary(reason),
    do: :ok

  defp retryable(%Post{}, _now), do: {:error, :not_refused}

  defp attempt(post, org_id, now_ms) do
    with {:ok, account} <- active_account(org_id, post),
         {:ok, media} <- load_media(org_id, post),
         :ok <- check_media(account, media),
         :ok <- RateLimit.check(account.id, now_ms),
         adapter when is_atom(adapter) <- Publisher.impl() do
      request = build_request(post, account, media)
      apply_publish(post, adapter.publish(account, request))
    end
  end

  # A refusal before the vendor (task 01a165f1): written under the row lock
  # publish_post/2 still holds. Anything else passes through untouched.
  defp record_refusal({:error, reason} = error, post, org_id, now_ms) do
    case refusal(reason, post, org_id, now_ms) do
      nil ->
        error

      {code, message, retry_after} ->
        post
        |> Post.refusal_changeset(code, readable(message), retry_after)
        |> Repo.update!()

        error
    end
  end

  defp record_refusal(result, _post, _org_id, _now_ms), do: result

  defp refusal({:media_rejected, messages}, _post, _org_id, _now_ms),
    do: {"media_rejected", sentence(messages), nil}

  defp refusal(:rate_limited, post, org_id, now_ms) do
    ends_at = DateTime.from_unix!(RateLimit.window_ends_at(now_ms) * 1_000, :microsecond)

    {"rate_limited",
     "#{label(org_id, post)}'s posting limit is reached. " <>
       "This post goes out at #{Calendar.strftime(ends_at, "%H:%M")} UTC.", ends_at}
  end

  defp refusal(:account_archived, post, org_id, _now_ms),
    do: {"account_archived", "The #{label(org_id, post)} account is disconnected.", nil}

  defp refusal(:publisher_not_configured, _post, _org_id, _now_ms),
    do: {"publisher_not_configured", "Publishing isn't set up for this profile.", nil}

  defp refusal(_reason, _post, _org_id, _now_ms), do: nil

  defp label(org_id, %Post{account_id: account_id}) do
    case Social.get_account(org_id, account_id) do
      %Account{platform: platform} -> Platform.Social.Approvals.platform_label(platform)
      # Unreachable: the with-chain read this account in this transaction.
      nil -> "Social"
    end
  end

  defp sentence(messages) do
    text = messages |> List.wrap() |> Enum.map(&to_string/1) |> Enum.join(". ")
    if String.ends_with?(text, [".", "!", "?"]), do: text, else: text <> "."
  end

  @doc false
  # The guard, exposed for its tests; publish_post/2 calls it on the locked
  # re-read. An approver that is not a user (an agent id, a random id) or
  # whose user row is archived does not count.
  @spec publishable?(Post.t()) :: boolean()
  def publishable?(%Post{status: "approved", approved_by_user_id: approver})
      when is_binary(approver) do
    match?(%{archived_at: nil}, Platform.Accounts.get_user(approver))
  end

  def publishable?(%Post{}), do: false

  defp guard(post), do: if(publishable?(post), do: :ok, else: {:error, :not_approved})

  defp lock(org_id, post_id) do
    case Social.lock_post(org_id, post_id) do
      nil -> {:error, :not_found}
      post -> {:ok, post}
    end
  end

  defp active_account(org_id, %Post{account_id: account_id}) do
    case Social.get_account(org_id, account_id) do
      nil -> {:error, :not_found}
      %Account{archived_at: nil} = account -> {:ok, account}
      %Account{} -> {:error, :account_archived}
    end
  end

  defp check_media(account, media) do
    case MediaRules.check(account.platform, account, media) do
      :ok -> :ok
      {:error, messages} -> {:error, {:media_rejected, messages}}
    end
  end

  # Files through core's context (never a Repo query on core's schema), and
  # only files in the post's org; per-file facts core lacks come from
  # `media_meta`.
  defp load_media(org_id, %Post{media_file_ids: ids, media_meta: meta}) do
    meta = meta || %{}

    Enum.reduce_while(ids || [], {:ok, []}, fn id, {:ok, acc} ->
      with %{} = file <- Platform.Files.get_file(id),
           true <- file_in_org?(file, org_id) do
        facts = Map.get(meta, id) || %{}

        item = %{
          file_id: id,
          url: media_url(file),
          content_type: file.content_type,
          byte_size: file.byte_size,
          duration_s: number(facts["duration_s"]),
          width: number(facts["width"]),
          height: number(facts["height"])
        }

        {:cont, {:ok, [item | acc]}}
      else
        _ -> {:halt, {:error, {:media_rejected, ["A media file is missing or not in this org"]}}}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp file_in_org?(%{project_id: nil}, _org_id), do: false

  defp file_in_org?(%{project_id: project_id}, org_id) do
    match?(%{org_id: ^org_id}, Platform.Tasks.get_project(project_id))
  end

  # ASSUMPTION / gap: core exposes no public, vendor-fetchable URL for a
  # platform file (Files.Storage presigns uploads only). Until one exists the
  # request carries nil and the adapter must refuse media it cannot fetch.
  defp media_url(_file), do: nil

  defp number(n) when is_number(n), do: n
  defp number(_), do: nil

  defp build_request(post, account, media) do
    %{
      body: post.body,
      link_url: post.link_url,
      scheduled_at: post.scheduled_at,
      media: Enum.map(media, &Map.take(&1, [:url, :content_type, :byte_size, :duration_s])),
      is_aigc: post.is_aigc == true,
      ai_disclosure: disclosure(post),
      platform: account.platform,
      idempotency_key: post.id
    }
  end

  defp disclosure(%Post{is_aigc: true, ai_disclosure: label}) do
    if is_binary(label) and String.trim(label) != "", do: label, else: @default_ai_disclosure
  end

  defp disclosure(%Post{ai_disclosure: label}), do: label

  defp apply_publish(post, {:ok, %{status: :scheduled, external_id: external_id} = result}) do
    post
    |> Changeset.change(
      status: "scheduled",
      external_id: external_id,
      external_url: Map.get(result, :external_url) || post.external_url,
      error: nil
    )
    |> Changeset.change(Post.refusal_cleared())
    |> update()
  end

  defp apply_publish(post, {:ok, %{status: :published, external_id: external_id} = result}) do
    post
    |> Changeset.change(
      status: "published",
      external_id: external_id,
      external_url: Map.get(result, :external_url),
      error: nil
    )
    |> Changeset.change(Post.refusal_cleared())
    |> update()
  end

  defp apply_publish(post, {:error, reason}) do
    changeset =
      post
      |> Changeset.change(status: "failed", error: readable(reason))
      |> Changeset.change(Post.refusal_cleared())

    case update(changeset) do
      {:ok, _failed} -> {:error, {:publish_failed, reason}}
      error -> error
    end
  end

  defp apply_publish(post, other), do: apply_publish(post, {:error, {:unexpected_result, other}})

  # ── Cancel, refresh, connect ─────────────────────────────────────────

  @doc """
  Cancels a `scheduled` post at the vendor. There is no `cancelled` status,
  so the row becomes `failed` with error "cancelled before publishing".
  """
  @spec cancel_post(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, Post.t()} | {:error, term()}
  def cancel_post(org_id, post_id) do
    {:ok, result} =
      Repo.transaction(fn ->
        with {:ok, %Post{status: "scheduled"} = post} <- lock(org_id, post_id),
             {:ok, account} <- account_any(org_id, post),
             adapter when is_atom(adapter) <- Publisher.impl(),
             :ok <- adapter.delete(account, post.external_id) do
          post
          |> Changeset.change(status: "failed", error: "cancelled before publishing")
          |> update()
        else
          {:ok, %Post{}} -> {:error, :not_scheduled}
          error -> error
        end
      end)

    terminal_written(result, post_id)
  end

  @doc "Reads the post's state at the vendor and applies it through `apply_outcome/2`."
  @spec refresh_status(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, Post.t() | :noop} | {:error, term()}
  def refresh_status(org_id, post_id) do
    with %Post{external_id: external_id} = post when is_binary(external_id) <-
           Social.get_post(org_id, post_id) || {:error, :not_found},
         {:ok, account} <- account_any(org_id, post),
         adapter when is_atom(adapter) <- Publisher.impl(),
         {:ok, %{status: status} = result} <- adapter.status(account, external_id) do
      kind = if status in [:published, :failed], do: status, else: :ignored

      apply_outcome(post, %{
        kind: kind,
        external_url: Map.get(result, :external_url),
        error: Map.get(result, :error)
      })
    else
      %Post{} -> {:error, :not_published_yet}
      error -> error
    end
  end

  @doc """
  Starts OAuth for an account at the vendor. `actor` (a user id) must be
  allowed to manage the org's social accounts (`can_connect?/2`), and
  `redirect_url` must point at this install's own host.
  """
  @spec connect_url(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def connect_url(org_id, actor, account_id, redirect_url) do
    with true <- can_connect?(actor, org_id) || {:error, :forbidden},
         :ok <- own_host(redirect_url),
         {:ok, account} <- account_any(org_id, %{account_id: account_id}),
         adapter when is_atom(adapter) <- Publisher.impl() do
      profile = Social.get_profile(org_id, account.profile_id)
      adapter.connect_url(account, redirect_url: redirect_url, profile: profile)
    end
  end

  # RBAC SWAP POINT: `Platform.Access` is not on main (checked with
  # `git grep -n 'defmodule Platform.Access' origin/main -- apps/platform/lib`,
  # 2026-10-16). Until it lands, connecting an account needs a non-archived,
  # non-external org ADMIN. Replace this body with `Platform.Access.can?/3`
  # on the profile's org or project.
  @doc false
  @spec can_connect?(term(), Ecto.UUID.t()) :: boolean()
  def can_connect?(actor, org_id) when is_binary(actor) do
    case Platform.Accounts.get_user(actor) do
      %{archived_at: nil, org_memberships: memberships} when is_list(memberships) ->
        Enum.any?(memberships, &(&1.org_id == org_id and &1.role == "admin" and !&1.external))

      _ ->
        false
    end
  end

  def can_connect?(_actor, _org_id), do: false

  # No open redirect: the OAuth return must come back to this install.
  defp own_host(redirect_url) when is_binary(redirect_url) do
    ours = URI.parse(PlatformWeb.Endpoint.url())
    theirs = URI.parse(redirect_url)

    if theirs.scheme in ["http", "https"] and theirs.host == ours.host and
         theirs.port == ours.port,
       do: :ok,
       else: {:error, :redirect_not_allowed}
  end

  defp own_host(_), do: {:error, :redirect_not_allowed}

  defp account_any(org_id, %{account_id: account_id}) do
    case Social.get_account(org_id, account_id) do
      nil -> {:error, :not_found}
      account -> {:ok, account}
    end
  end

  # ── Outcome transition ───────────────────────────────────────────────

  @doc """
  The one transition from a vendor outcome. `outcome` is
  `%{kind: :published | :failed | :ignored, external_url, error}`.

  Moves an `approved` or `scheduled` post (re-read under a row lock) to
  `published` (with `external_url`) or `failed` (with `error`). A post
  already `published` or `failed`, or an `:ignored` outcome, answers
  `{:ok, :noop}` without writing. A `draft` or `needs_approval` post is
  refused with `{:error, :invalid_transition}`.
  """
  @spec apply_outcome(Post.t(), map()) :: {:ok, Post.t() | :noop} | {:error, term()}
  def apply_outcome(%Post{id: id}, outcome) do
    {:ok, result} =
      Repo.transaction(fn ->
        post = Repo.one(from(p in Post, where: p.id == ^id, lock: "FOR UPDATE"))
        transition(post, outcome)
      end)

    terminal_written(result, id)
  end

  defp transition(nil, _outcome), do: {:error, :not_found}
  defp transition(_post, %{kind: :ignored}), do: {:ok, :noop}
  defp transition(%Post{status: status}, _) when status in ~w(published failed), do: {:ok, :noop}

  defp transition(%Post{status: status} = post, %{kind: :published} = outcome)
       when status in ~w(approved scheduled) do
    post
    |> Changeset.change(
      status: "published",
      external_url: Map.get(outcome, :external_url) || post.external_url,
      error: nil
    )
    |> Changeset.change(Post.refusal_cleared())
    |> update()
  end

  defp transition(%Post{status: status} = post, %{kind: :failed} = outcome)
       when status in ~w(approved scheduled) do
    post
    |> Changeset.change(
      status: "failed",
      error: readable(Map.get(outcome, :error) || "failed at the vendor")
    )
    |> Changeset.change(Post.refusal_cleared())
    |> update()
  end

  defp transition(%Post{}, _outcome), do: {:error, :invalid_transition}

  # ── Task write-back (Social 6/7) ─────────────────────────────────────

  # The ONE place this module tells `Platform.Social.TaskBridge` a post
  # reached a terminal state (published or failed), AFTER the transaction
  # that wrote it committed: publish_post/2's step (h), cancel_post/2 and
  # apply_outcome/2 (the webhook and refresh_status/2). A `scheduled` write
  # or a `:noop` replay is not terminal news, so it is not reported.
  defp terminal_written(result, post_id) do
    if terminal?(result), do: Platform.Social.TaskBridge.post_changed(post_id)
    result
  end

  defp terminal?({:ok, %Post{status: status}}), do: status in ~w(published failed)
  defp terminal?({:error, {:publish_failed, _}}), do: true
  defp terminal?(_result), do: false

  # ── Shared ───────────────────────────────────────────────────────────

  defp update(changeset) do
    changeset
    |> Changeset.check_constraint(:status, name: :social_posts_status_check)
    |> Changeset.check_constraint(:approved_by_user_id,
      name: :social_posts_approved_needs_approver_check
    )
    |> Repo.update()
  end

  defp readable(reason) when is_binary(reason), do: String.slice(reason, 0, @max_error_length)
  defp readable(:rate_limited), do: "rate limited by the vendor"
  defp readable(:credentials_unavailable), do: "the account's credentials are unavailable"

  defp readable(reason) when is_atom(reason),
    do: reason |> Atom.to_string() |> String.replace("_", " ")

  defp readable(reason), do: reason |> inspect() |> String.slice(0, @max_error_length)
end
