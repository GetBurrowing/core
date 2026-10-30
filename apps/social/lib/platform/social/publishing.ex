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

  and only then calls the vendor-neutral adapter. A nonblank `external_id`
  selects `retry/2` for the existing vendor post; otherwise `publish/2`
  creates it with the original post idempotency key. An unsupported retry
  records a configuration refusal and never falls back to creation.
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

  ## Attempts and platform ids (Clip Studio 2/9, task 01a16662)

  Every adapter `publish/2` or `retry/2` call adds one to `publish_attempts`,
  on success and on failure, in the same write as its result. A refusal before the
  adapter (the guard, an archived account, `MediaRules`, `RateLimit`, no
  configured publisher) sent nothing, so it does not count. When a publish,
  status or webhook result carries `:platform_post_id` (the platform's own
  id, read from the vendor's per-account entry) it is stored; `external_id`
  is unchanged. Every committed move to `published` writes `published_at`.

  Every committed move to `published` or `failed` (publish, cancel, outcome)
  is reported to `Platform.Social.TaskBridge.post_changed/1` (Social 6/7),
  which writes a social task's post URLs once all its drafts are terminal.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset
  alias Platform.Repo
  alias Platform.Social

  alias Platform.Social.{
    Account,
    Cover,
    MediaRules,
    OrgFiles,
    Post,
    PostEvents,
    Profile,
    Publisher,
    RateLimit
  }

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
          |> log_outcome(post)
        end
      end)

    terminal_written(result, post_id)
    |> alert_disconnect(post_id, result_reason(result))
    |> set_cover_after_publish()
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
         {:ok, cover} <- load_cover(org_id, post),
         :ok <- check_media(account, media),
         :ok <- RateLimit.check(account.id, now_ms),
         adapter when is_atom(adapter) <- Publisher.impl() do
      if is_binary(post.external_id) and String.trim(post.external_id) != "" do
        if Code.ensure_loaded?(adapter) and function_exported?(adapter, :retry, 2) do
          apply_publish(post, adapter.retry(account, post.external_id))
        else
          {:error, :retry_not_supported}
        end
      else
        request = build_request(post, account, media, cover)
        apply_publish(post, adapter.publish(account, request))
      end
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

        PostEvents.record!(post, "refused", :system, note: code)
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

  defp refusal(:retry_not_supported, _post, _org_id, _now_ms),
    do:
      {"publisher_not_configured", "The publisher does not support retrying an existing post.",
       nil}

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
  defp load_media(org_id, %Post{media_file_ids: ids, media_meta: meta} = post) do
    meta = meta || %{}

    Enum.reduce_while(ids || [], {:ok, []}, fn id, {:ok, acc} ->
      with %{} = file <- Platform.Files.get_file(id),
           true <- file_in_org?(file, org_id) do
        facts = Map.get(meta, id) || %{}

        item = %{
          file_id: id,
          url: vendor_url(file, post),
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

  # The one org rule for a core file, shared with AgentDrafts and Cover.
  defp file_in_org?(file, org_id), do: Platform.Social.OrgFiles.in_org?(file, org_id)

  @vendor_url_grace_seconds 3600

  @doc """
  A vendor-fetchable URL for `file` on behalf of `post`: a signed,
  session-free GET (`Platform.Files.SignedUrl`) that expires one hour after
  `max(now, post.scheduled_at)`, so a scheduled post's media is still live
  when the vendor fetches it at publish time. `nil` when one cannot be minted
  (the adapter then refuses the media as unfetchable).

  Possession of the URL is possession of the bytes until it expires, so this
  is called only inside `publish_post/2`, after the publish guard, never to
  display or preview. The cover image (stage 3) goes out the same way.
  """
  @spec vendor_url(Platform.Files.File.t(), Post.t()) :: String.t() | nil
  def vendor_url(file, %Post{scheduled_at: scheduled_at}) do
    now = DateTime.utc_now()

    base =
      case scheduled_at do
        %DateTime{} = at -> if DateTime.compare(at, now) == :gt, do: at, else: now
        _ -> now
      end

    expires_at = DateTime.add(base, @vendor_url_grace_seconds, :second)

    case Platform.Files.SignedUrl.url(file, expires_at: expires_at) do
      {:ok, url} -> url
      {:error, _} -> nil
    end
  end

  defp number(n) when is_number(n), do: n
  defp number(_), do: nil

  defp build_request(post, account, media, cover) do
    %{
      body: post.body,
      link_url: post.link_url,
      scheduled_at: post.scheduled_at,
      media: Enum.map(media, &Map.take(&1, [:url, :content_type, :byte_size, :duration_s])),
      is_aigc: post.is_aigc == true,
      ai_disclosure: disclosure(post),
      platform: account.platform,
      idempotency_key: post.id,
      cover: cover,
      options:
        Platform.Social.PlatformOptions.for_platform(post.platform_options, account.platform)
    }
  end

  # ── Cover (task 01a165ec, stage 3) ───────────────────────────────────

  # The request's cover: an uploaded image goes out as a signed URL minted
  # by `vendor_url/2`, exactly like media; a frame as its offset. The file
  # is re-checked here (still there, still in the org, still JPG/PNG), and a
  # failure refuses the publish before any HTTP, like a bad media file.
  defp load_cover(org_id, %Post{cover_file_id: file_id} = post) when is_binary(file_id) do
    with {:ok, file} <- cover_file(org_id, file_id),
         url when is_binary(url) <- vendor_url(file, post) do
      {:ok, %{kind: :image, url: url, content_type: file.content_type}}
    else
      {:error, message} -> {:error, {:media_rejected, [message]}}
      nil -> {:error, {:media_rejected, ["The cover image could not be shared with the vendor"]}}
    end
  end

  defp load_cover(_org_id, %Post{cover_offset_ms: offset}) when is_integer(offset),
    do: {:ok, %{kind: :frame, offset_ms: offset}}

  defp load_cover(_org_id, %Post{}), do: {:ok, nil}

  defp cover_file(org_id, file_id) do
    file = Platform.Files.get_file(file_id)

    cond do
      is_nil(file) or not OrgFiles.in_org?(file, org_id) ->
        {:error, "The cover image is missing or not in this org"}

      file.content_type not in Cover.image_types() ->
        {:error, "The cover image must be a JPG or PNG"}

      true ->
        {:ok, file}
    end
  end

  # YouTube takes no cover at create time, so an uploaded cover is set
  # AFTER the post is published, once the transaction that wrote
  # `published` has committed (publish_post/2 on a synchronous publish,
  # apply_outcome/2 otherwise). One call with a freshly minted URL, no
  # retry. Its outcome lands on `cover_error` only: success clears it, a
  # failure explains it, and the post's status never changes. A frame
  # offset sends nothing (YouTube has no API for one).
  defp set_cover_after_publish({:ok, %Post{status: "published", cover_file_id: file_id} = post})
       when is_binary(file_id) do
    case youtube_account(post) do
      {account, org_id} -> {:ok, send_cover(post, account, org_id, file_id)}
      nil -> {:ok, post}
    end
  end

  defp set_cover_after_publish(result), do: result

  defp youtube_account(%Post{account_id: account_id}) do
    Repo.one(
      from(a in Account,
        join: p in Profile,
        on: p.id == a.profile_id,
        where: a.id == ^account_id and a.platform == "youtube",
        select: {a, p.org_id}
      )
    )
  end

  defp send_cover(post, account, org_id, file_id) do
    with adapter when is_atom(adapter) <- Publisher.impl(),
         true <- Code.ensure_loaded?(adapter) and function_exported?(adapter, :set_cover, 3) do
      outcome =
        with {:ok, file} <- cover_file(org_id, file_id),
             url when is_binary(url) <- vendor_url(file, post) || {:error, :url_unavailable},
             true <- is_binary(post.external_id) || {:error, :no_external_id} do
          adapter.set_cover(account, post.external_id, url)
        end

      write_cover_error(post, cover_error(outcome))
    else
      _ -> post
    end
  end

  defp cover_error(:ok), do: nil

  defp cover_error({:error, :rate_limited}),
    do: "YouTube cover not set: the upload limit was reached; set it again later"

  defp cover_error({:error, reason}), do: readable("YouTube cover not set: " <> readable(reason))
  defp cover_error(other), do: cover_error({:error, {:unexpected_result, other}})

  defp write_cover_error(%Post{cover_error: same} = post, same), do: post

  defp write_cover_error(post, message) do
    case post |> Changeset.change(cover_error: message) |> Repo.update() do
      {:ok, post} -> post
      _ -> post
    end
  end

  defp disclosure(%Post{is_aigc: true, ai_disclosure: label}) do
    if is_binary(label) and String.trim(label) != "", do: label, else: @default_ai_disclosure
  end

  defp disclosure(%Post{ai_disclosure: label}), do: label

  # Every clause is one adapter call's result, so every clause counts one
  # attempt (`counted/2`), success or failure.
  defp apply_publish(post, {:ok, %{status: :scheduled, external_id: external_id} = result}) do
    post
    |> Changeset.change(
      status: "scheduled",
      external_id: external_id,
      external_url: Map.get(result, :external_url) || post.external_url,
      platform_post_id: Map.get(result, :platform_post_id) || post.platform_post_id,
      error: nil
    )
    |> Changeset.change(Post.refusal_cleared())
    |> counted(post)
    |> update()
  end

  defp apply_publish(post, {:ok, %{status: :published, external_id: external_id} = result}) do
    post
    |> Changeset.change(
      status: "published",
      external_id: external_id,
      external_url: Map.get(result, :external_url),
      platform_post_id: Map.get(result, :platform_post_id) || post.platform_post_id,
      published_at: DateTime.utc_now(),
      error: nil
    )
    |> Changeset.change(Post.refusal_cleared())
    |> counted(post)
    |> update()
  end

  defp apply_publish(post, {:ok, %{status: :failed, external_id: external_id} = result}) do
    reason = Map.get(result, :error) || "failed at the vendor"

    changeset =
      post
      |> Changeset.change(status: "failed", external_id: external_id, error: readable(reason))
      |> Changeset.change(Post.refusal_cleared())
      |> counted(post)

    case update(changeset) do
      {:ok, _failed} -> {:error, {:publish_failed, reason}}
      error -> error
    end
  end

  defp apply_publish(post, {:error, reason}) do
    changeset =
      post
      |> Changeset.change(status: "failed", error: readable(reason))
      |> Changeset.change(Post.refusal_cleared())
      |> counted(post)

    case update(changeset) do
      {:ok, _failed} -> {:error, {:publish_failed, reason}}
      error -> error
    end
  end

  defp apply_publish(post, other), do: apply_publish(post, {:error, {:unexpected_result, other}})

  # One adapter call happened. `post` is the locked re-read, so its count is
  # the database's.
  defp counted(changeset, %Post{publish_attempts: attempts}),
    do: Changeset.put_change(changeset, :publish_attempts, (attempts || 0) + 1)

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
          |> log_outcome(post)
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
        platform_post_id: Map.get(result, :platform_post_id),
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
  `%{kind: :published | :failed | :ignored, external_url, error}` and may
  carry `:platform_post_id`, stored when present.

  Moves an `approved` or `scheduled` post (re-read under a row lock) to
  `published` (with `external_url` and `published_at`) or `failed` (with
  `error`). A post
  already `published` or `failed`, or an `:ignored` outcome, answers
  `{:ok, :noop}` without writing. A `draft` or `needs_approval` post is
  refused with `{:error, :invalid_transition}`.
  """
  @spec apply_outcome(Post.t(), map()) :: {:ok, Post.t() | :noop} | {:error, term()}
  def apply_outcome(%Post{id: id}, outcome) do
    {:ok, result} =
      Repo.transaction(fn ->
        post = Repo.one(from(p in Post, where: p.id == ^id, lock: "FOR UPDATE"))
        post |> transition(outcome) |> log_outcome(post)
      end)

    terminal_written(result, id)
    |> alert_disconnect(id, outcome)
    |> set_cover_after_publish()
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
      platform_post_id: Map.get(outcome, :platform_post_id) || post.platform_post_id,
      published_at: DateTime.utc_now(),
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
      platform_post_id: Map.get(outcome, :platform_post_id) || post.platform_post_id,
      error: readable(Map.get(outcome, :error) || "failed at the vendor")
    )
    |> Changeset.change(Post.refusal_cleared())
    |> update()
  end

  defp transition(%Post{}, _outcome), do: {:error, :invalid_transition}

  # Social authoring 2/11: the change log entry for a publish outcome, in
  # the transaction that wrote it. A `scheduled` write and a `:noop` are not
  # logged; a refusal before the vendor is logged by `record_refusal/4`.
  defp log_outcome({:ok, %Post{status: "published"} = written} = result, _post) do
    PostEvents.record!(written, "published", :system)
    result
  end

  defp log_outcome({:ok, %Post{status: "failed"} = written} = result, _post) do
    PostEvents.record!(written, "failed", :system, note: written.error)
    result
  end

  defp log_outcome({:error, {:publish_failed, reason}} = result, %Post{} = post) do
    PostEvents.record!(post, "failed", :system, note: readable(reason))
    result
  end

  defp log_outcome(result, _post), do: result

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

  # Social authoring 9/11: a committed failure the adapter classified as the
  # platform account losing its authorization marks the account and alerts
  # its approvers ONCE (`Platform.Social.Health.account_disconnected/2`
  # dedupes on the account), after the transaction.
  defp alert_disconnect(result, post_id, reason) do
    with true <- failed_write?(result) and Platform.Social.Health.auth_failure?(reason),
         %Post{account_id: account_id, error: error} <- Repo.get(Post, post_id) do
      Platform.Social.Health.account_disconnected(account_id, error)
    end

    result
  end

  defp failed_write?({:ok, %Post{status: "failed"}}), do: true
  defp failed_write?({:error, {:publish_failed, _}}), do: true
  defp failed_write?(_result), do: false

  defp result_reason({:error, {:publish_failed, reason}}), do: reason
  defp result_reason(_result), do: nil

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
    |> Changeset.check_constraint(:publish_attempts,
      name: :social_posts_publish_attempts_check
    )
    |> Repo.update()
  end

  defp readable(reason) when is_binary(reason), do: String.slice(reason, 0, @max_error_length)
  defp readable(:rate_limited), do: "rate limited by the vendor"
  defp readable(:credentials_unavailable), do: "the account's credentials are unavailable"

  defp readable(:account_disconnected),
    do: "the platform disconnected this account; reconnect it in Connections"

  defp readable({:account_disconnected, message}) when is_binary(message), do: readable(message)

  defp readable(reason) when is_atom(reason),
    do: reason |> Atom.to_string() |> String.replace("_", " ")

  defp readable(reason), do: reason |> inspect() |> String.slice(0, @max_error_length)
end
