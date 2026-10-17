defmodule Platform.Social.Approvals do
  @moduledoc """
  The human approval flow (task 01a140a9-31b0, Social 3/7): the approval
  card a post's approvers decide on, and the inbox rows that point at it.

  ## Shape

  Inbox items cannot carry actions on core main (`Platform.Inbox.Item` has
  no action field), so the inbox row is a POINTER: one
  `social_post_approval` row per reachable approver, deep-linking to the
  card's message, carrying no post text and no media. Approve, Edit and
  Reject live on the card (a `social_post_card` canvas in the profile's
  channel), handled in the clicking human's own LiveView process by
  `PlatformWeb.SocialCardHooks`, which calls the `decide_*` functions here.

  The canvas document holds ONLY `%{"card_id" => id, "rev" => n}` on one
  `social_post_card` root node: agents read canvases through `canvas_get`,
  so no post text, media, URL or name is ever in it. `card_view/2` renders
  the card per viewer at view time.

  ## Every decision

  Each `decide_*` call, in ONE transaction:

    1. locks the card by the CLICKED canvas id (`FOR UPDATE`); a canvas
       without a card is `:not_a_social_card` (a lookalike an agent made);
    2. requires the card `pending`, else `:already_decided`;
    3. compares the canvas document's digest with the stored `card_digest`,
       else `:card_changed` (an agent may `canvas_patch` any canvas in a
       space it is in; `Chat.patch_canvas/3` gates on membership only);
    4. locks the post (`FOR UPDATE`) and requires `needs_approval`, else
       `:already_decided`;
    5. compares the content fingerprint the human was SHOWN (rendered into
       the card at view time) with the locked row's, else `:post_changed`.
       This closes the approval race: an agent edit that commits while a
       human's click is pending would otherwise be approved unseen. The
       card digest does not catch it, because the digest guards the canvas,
       not the post;
    6. runs `Platform.Social.approver_check/3` on the user, re-read from the
       database, so archived users, users taken off the list and users who
       lost access are refused at the moment of the click;
    7. compare-and-sets the card `pending -> deciding` (`update_all` with
       the state in the WHERE clause), so a second decision can never win.

  Approval then goes through member 1's `Platform.Social.approve_post/4`,
  the only setter of the approver, and AFTER commit through member 2's
  `Platform.Social.Publishing.publish_post/2`, the only publisher.

  ## Reject

  `decide_reject/3` stores the reason in member 4's `rejection_reason` and
  `rejected_at` (`Post.reject_changeset/2`) and moves the post to `draft`:
  there is no `rejected` status, and `draft` lets the drafting agent revise
  and resubmit. "Rejected" is `Post.rejected?/1`.
  """

  import Ecto.Query

  require Logger

  alias Ecto.Changeset
  alias Platform.Chat
  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{Account, ApprovalCard, Post, Publishing}

  @kind "social_post_approval"
  @source_type "social_post"
  @card_kind "social_post_card"

  # ASSUMPTION: each platform's text limit as of 2026-10; the vendor is the
  # final word, this only drives the card's counter.
  @platform_limits %{
    "linkedin" => 3000,
    "x" => 280,
    "tiktok" => 2200,
    "instagram" => 2200,
    "youtube" => 5000
  }

  @platform_labels %{
    "linkedin" => "LinkedIn",
    "x" => "X",
    "tiktok" => "TikTok",
    "instagram" => "Instagram",
    "youtube" => "YouTube"
  }

  @type refusal ::
          :not_a_social_card
          | :already_decided
          | :card_changed
          | :post_changed
          | :draft_only
          | :reason_required
          | Social.approver_refusal()

  # ── Fan-out ──────────────────────────────────────────────────────────

  @doc """
  Posts the approval card for a `needs_approval` post and emits one inbox
  row per reachable approver; if the post already has a live card (an
  agent re-edited it), re-renders that card instead and emits nothing.

  Called only from `Platform.Social.needs_approval_written/1`, after the
  post is committed. Refuses `{:error, :profile_has_no_channel}` when the
  profile has no `space_id` (the write paths refuse the transition first).

  An approver who passes `approver_check/3` but cannot read the card's
  canvas (not a participant of the channel) gets NO row and is NOT added
  to the channel: adding them would bypass a role-restricted channel. They
  are returned in `unreachable_approvers` and logged.
  """
  @spec request_approval(Post.t()) ::
          {:ok, %{card: ApprovalCard.t(), unreachable_approvers: [Ecto.UUID.t()]}}
          | {:error, term()}
  def request_approval(%Post{status: "needs_approval"} = post) do
    with {:ok, profile} <- Social.profile_of_post(post),
         :ok <- Social.require_channel("needs_approval", profile) do
      case live_card(post.id) do
        %ApprovalCard{} = card ->
          with {:ok, card} <- rerender(card), do: {:ok, %{card: card, unreachable_approvers: []}}

        nil ->
          create_card(post, profile)
      end
    end
  end

  def request_approval(%Post{}), do: {:error, :not_needs_approval}

  @doc """
  The post's live (pending or deciding) approval card, or nil. READ ONLY:
  Social 7/7's queue uses it to find the card to embed; every decision still
  goes through `decide_*` by the card's canvas id.
  """
  @spec live_card(Ecto.UUID.t()) :: ApprovalCard.t() | nil
  def live_card(post_id) do
    Repo.one(
      from(c in ApprovalCard,
        where: c.post_id == ^post_id and c.state in ^ApprovalCard.live_states()
      )
    )
  end

  defp create_card(post, profile) do
    card_id = Platform.Types.UUIDv7.generate()

    with {:ok, participant} <- ensure_system_participant(profile.space_id),
         {:ok, canvas, message} <-
           Chat.create_canvas_with_message(profile.space_id, participant.id, %{
             title: "Post approval",
             message_content: "A post is waiting for a human approval.",
             document: card_document(card_id, 1)
           }),
         {:ok, card} <-
           %ApprovalCard{id: card_id}
           |> ApprovalCard.create_changeset(%{
             post_id: post.id,
             canvas_id: canvas.id,
             message_id: message.id,
             card_digest: digest(canvas.document)
           })
           |> Repo.insert() do
      unreachable = fan_out(post, profile, card, canvas, message)
      {:ok, %{card: card, unreachable_approvers: unreachable}}
    else
      # A concurrent request created the live card first: re-render it.
      {:error, %Changeset{errors: errors}} = error ->
        if Keyword.has_key?(errors, :post_id) do
          request_approval(post)
        else
          error
        end

      error ->
        error
    end
  end

  @doc "The canvas document of a card: one `social_post_card` node, `card_id` and `rev` only."
  @spec card_document(Ecto.UUID.t(), pos_integer()) :: map()
  def card_document(card_id, rev) do
    %{
      "version" => 1,
      "revision" => 1,
      "root" => %{
        "id" => "root",
        "type" => @card_kind,
        "props" => %{"card_id" => card_id, "rev" => rev},
        "children" => []
      },
      "theme" => %{},
      "bindings" => %{},
      "meta" => %{}
    }
  end

  defp fan_out(post, profile, card, canvas, message) do
    {:ok, account} = fetch_account(post)
    space = Chat.get_space(profile.space_id)
    url = "/chat/#{Chat.space_path_segment(space)}?message=#{message.id}"

    {reachable, unreachable} =
      (profile.approver_user_ids || [])
      |> Enum.filter(&(Social.approver_check(profile.org_id, profile, &1) == :ok))
      |> Enum.split_with(
        &match?(
          {:ok, _, _},
          Chat.CanvasAccess.fetch_for_viewer(canvas.id, {:user, &1}, audit: false)
        )
      )

    for user_id <- reachable do
      {:ok, _} =
        Platform.Inbox.emit(%{
          user_id: user_id,
          kind: @kind,
          source_type: @source_type,
          source_id: post.id,
          title: "Post for #{profile.name} needs your approval",
          body: "#{String.upcase(platform_label(account.platform))} · #{schedule_text(post)}",
          url: url
        })
    end

    if unreachable != [] do
      Logger.warning(
        "[Social] approval card #{card.id}: approvers who cannot see the channel got no inbox row: " <>
          Enum.join(unreachable, ", ")
      )
    end

    unreachable
  end

  # A Social system participant in the channel, with a deterministic id per
  # space (`Platform.Orchestration.ExecutionSpace.ensure_system_participant/1`'s
  # pattern), through core's public Chat API.
  defp ensure_system_participant(space_id) do
    participant_id = system_participant_id(space_id)

    case Enum.find(
           Chat.list_participants(space_id),
           &(&1.participant_type == "system" and &1.participant_id == participant_id)
         ) do
      nil ->
        Chat.add_participant(space_id, %{
          participant_type: "system",
          participant_id: participant_id,
          display_name: "Social",
          attention_mode: "mention",
          joined_at: DateTime.utc_now()
        })

      participant ->
        {:ok, participant}
    end
  end

  defp system_participant_id(space_id) do
    <<a::binary-8, b::binary-4, c::binary-4, d::binary-4, e::binary-12, _::binary>> =
      :crypto.hash(:sha256, "social_system:#{space_id}") |> Base.encode16(case: :lower)

    "#{a}-#{b}-#{c}-#{d}-#{e}"
  end

  # ── Digest and fingerprint ───────────────────────────────────────────

  @doc """
  The card digest: sha256 of the canonical document minus `revision`
  (the server bumps it on every patch, ours included).
  """
  @spec digest(map()) :: String.t()
  def digest(document) when is_map(document) do
    document
    |> Map.delete("revision")
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc """
  The content fingerprint of what an approver is shown: body, link, media,
  schedule and account. Rendered into the card at view time and compared
  with the locked row at click time (`:post_changed` on mismatch).
  """
  @spec fingerprint(Post.t()) :: String.t()
  def fingerprint(%Post{} = post) do
    {post.account_id, post.body, post.link_url, post.media_file_ids || [],
     post.scheduled_at && DateTime.to_iso8601(post.scheduled_at)}
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 32)
  end

  # The authoritative document: the canvas server's in-memory copy (the
  # database row is an async write-through sink).
  defp current_document(canvas_id) do
    case Platform.Chat.Canvas.Server.describe(canvas_id) do
      {:ok, %{document: document}} -> {:ok, document}
      error -> {:error, {:canvas_unavailable, error}}
    end
  end

  # ── Decisions ────────────────────────────────────────────────────────

  @doc """
  Approves the post on the card behind `canvas_id` as `clicker`, then
  publishes it. `shown_fingerprint` is the `fingerprint/1` the card
  rendered for that human; the click handler always passes it.

  `decide_approve/2` (no fingerprint) approves the post as it is when the
  call starts: the fingerprint is read before the transaction, so an edit
  that lands between that read and the row lock is still refused.

  Returns `{:ok, %{post: post, publish: publish_result}}` or
  `{:error, refusal}`. Every refusal leaves the post, the card and the
  publisher untouched.
  """
  @spec decide_approve(Ecto.UUID.t(), map(), String.t() | nil) ::
          {:ok, map()} | {:error, refusal() | term()}
  def decide_approve(canvas_id, clicker, shown_fingerprint \\ nil)

  def decide_approve(canvas_id, clicker, nil) do
    case peek_post(canvas_id) do
      %Post{} = post -> decide_approve(canvas_id, clicker, fingerprint(post))
      nil -> {:error, :not_a_social_card}
    end
  end

  def decide_approve(canvas_id, clicker, shown_fingerprint) do
    result =
      decide(canvas_id, clicker, shown_fingerprint, fn card, post, account, profile, user_id ->
        with :ok <- refuse_draft_only(account),
             :ok <- claim(card),
             {:ok, approved} <- Social.approve_post(profile.org_id, post, user_id, lock: true),
             {:ok, card} <-
               card |> ApprovalCard.decided_changeset("approve", user_id) |> Repo.update() do
          {card, approved, profile}
        end
      end)

    with {:ok, {card, approved, profile}} <- result do
      publish = Publishing.publish_post(profile.org_id, approved.id)
      resolve(card, profile, approved)
      {:ok, %{post: Repo.get!(Post, approved.id), publish: publish, card: card}}
    end
  end

  @doc """
  A human approver edits the post's text from the card. Only `body`
  changes; the post stays `needs_approval`, the card stays pending (with
  `edited_by`), and the inbox rows stay.
  """
  @spec decide_edit(Ecto.UUID.t(), map(), map(), String.t() | nil) ::
          {:ok, map()} | {:error, refusal() | term()}
  def decide_edit(canvas_id, clicker, attrs, shown_fingerprint \\ nil) do
    shown_fingerprint = shown_fingerprint || peek_fingerprint(canvas_id)
    body = Map.get(attrs, :body) || Map.get(attrs, "body")

    result =
      decide(canvas_id, clicker, shown_fingerprint, fn card, post, _account, profile, user_id ->
        with {:ok, edited} <- post |> Post.human_edit_changeset(%{body: body}) |> Repo.update(),
             {:ok, card} <- card |> ApprovalCard.edited_changeset(user_id) |> Repo.update() do
          {card, edited, profile}
        end
      end)

    with {:ok, {card, edited, _profile}} <- result,
         {:ok, card} <- rerender(card) do
      {:ok, %{post: edited, card: card}}
    end
  end

  @doc """
  A human approver rejects the post with `reason` (non-blank, at most
  #{Post.max_rejection_reason()} characters, else `:reason_required`). The
  reason lands in member 4's columns, the post goes to `draft`, the card is
  decided, and every approver's inbox row is dismissed.
  """
  @spec decide_reject(Ecto.UUID.t(), map(), String.t() | nil, String.t() | nil) ::
          {:ok, map()} | {:error, refusal() | term()}
  def decide_reject(canvas_id, clicker, reason, shown_fingerprint \\ nil) do
    reason = if is_binary(reason), do: String.trim(reason), else: ""

    if reason == "" or String.length(reason) > Post.max_rejection_reason() do
      {:error, :reason_required}
    else
      shown_fingerprint = shown_fingerprint || peek_fingerprint(canvas_id)

      result =
        decide(canvas_id, clicker, shown_fingerprint, fn card, post, _account, profile, user_id ->
          with :ok <- claim(card),
               {:ok, rejected} <- post |> Post.reject_changeset(reason) |> Repo.update(),
               {:ok, card} <-
                 card |> ApprovalCard.decided_changeset("reject", user_id) |> Repo.update() do
            {card, rejected, profile}
          end
        end)

      with {:ok, {card, rejected, profile}} <- result do
        resolve(card, profile, rejected)
        # Social 6/7: a rejection is terminal for the task write-back.
        Platform.Social.TaskBridge.post_changed(rejected.id)
        {:ok, %{post: rejected, card: card}}
      end
    end
  end

  # The shared locked prologue (steps 1-6 of the moduledoc), then `body`.
  defp decide(canvas_id, clicker, shown_fingerprint, body) do
    user_id = clicker_id(clicker)
    # Read BEFORE the transaction: the canvas server is another process, and
    # on first use it loads the row through the pool, which this
    # transaction's connection would otherwise starve.
    live = live_document(canvas_id)

    Repo.transaction(fn ->
      with {:ok, card} <- lock_card(canvas_id),
           :ok <- refuse_not_pending(card),
           :ok <- check_digest(card, live),
           {:ok, post} <- lock_post(card.post_id),
           :ok <- refuse_not_needs_approval(post),
           :ok <- check_fingerprint(post, shown_fingerprint),
           {:ok, account} <- fetch_account(post),
           {:ok, profile} <- Social.profile_of_post(post),
           :ok <- Social.approver_check(profile.org_id, profile, user_id) do
        case body.(card, post, account, profile, user_id) do
          {:error, %Changeset{} = changeset} -> Repo.rollback(changeset_reason(changeset))
          {:error, reason} -> Repo.rollback(reason)
          result -> result
        end
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp changeset_reason(%Changeset{errors: errors} = changeset) do
    Enum.find_value(errors, changeset, fn {_field, {_msg, opts}} -> Keyword.get(opts, :reason) end)
  end

  defp clicker_id(%{id: id}), do: id
  defp clicker_id(id) when is_binary(id), do: id
  defp clicker_id(_), do: nil

  defp lock_card(canvas_id) do
    case Ecto.UUID.cast(canvas_id) do
      {:ok, canvas_id} ->
        case Repo.one(
               from(c in ApprovalCard, where: c.canvas_id == ^canvas_id, lock: "FOR UPDATE")
             ) do
          nil -> {:error, :not_a_social_card}
          card -> {:ok, card}
        end

      :error ->
        {:error, :not_a_social_card}
    end
  end

  defp refuse_not_pending(%ApprovalCard{state: "pending"}), do: :ok
  defp refuse_not_pending(%ApprovalCard{}), do: {:error, :already_decided}

  # Both copies must match the stored digest: the server's in-memory
  # document (authoritative while the canvas is live) and, when it is at the
  # same revision, the persisted row read inside this transaction.
  defp check_digest(_card, {:error, _}), do: {:error, :card_changed}

  defp check_digest(%ApprovalCard{canvas_id: canvas_id, card_digest: stored}, {:ok, live}) do
    row = Chat.get_canvas(canvas_id)

    cond do
      digest(live) != stored ->
        {:error, :card_changed}

      is_nil(row) ->
        {:error, :card_changed}

      row.document["revision"] == live["revision"] and digest(row.document) != stored ->
        {:error, :card_changed}

      true ->
        :ok
    end
  end

  defp live_document(canvas_id) do
    if Platform.UUID.valid?(canvas_id),
      do: current_document(canvas_id),
      else: {:error, :not_found}
  end

  defp lock_post(post_id) do
    case Repo.one(from(p in Post, where: p.id == ^post_id, lock: "FOR UPDATE")) do
      nil -> {:error, :already_decided}
      post -> {:ok, post}
    end
  end

  defp refuse_not_needs_approval(%Post{status: "needs_approval"}), do: :ok
  defp refuse_not_needs_approval(%Post{}), do: {:error, :already_decided}

  defp check_fingerprint(post, shown) do
    if is_binary(shown) and shown == fingerprint(post), do: :ok, else: {:error, :post_changed}
  end

  defp refuse_draft_only(%Account{approval_mode: "draft_only"}), do: {:error, :draft_only}
  defp refuse_draft_only(%Account{}), do: :ok

  # The compare-and-set: only a `pending` card moves to `deciding`; a
  # second decision finds zero rows and is refused.
  defp claim(%ApprovalCard{id: id}) do
    case Repo.update_all(
           from(c in ApprovalCard, where: c.id == ^id and c.state == "pending"),
           set: [state: "deciding", updated_at: DateTime.utc_now()]
         ) do
      {1, _} -> :ok
      {0, _} -> {:error, :already_decided}
    end
  end

  defp peek_post(canvas_id) do
    with {:ok, canvas_id} <- Ecto.UUID.cast(canvas_id),
         %ApprovalCard{post_id: post_id} <- Repo.get_by(ApprovalCard, canvas_id: canvas_id) do
      Repo.get(Post, post_id)
    else
      _ -> nil
    end
  end

  defp peek_fingerprint(canvas_id) do
    case peek_post(canvas_id) do
      %Post{} = post -> fingerprint(post)
      nil -> nil
    end
  end

  defp fetch_account(%Post{account_id: account_id}) do
    case Repo.get(Account, account_id) do
      nil -> {:error, :not_found}
      account -> {:ok, account}
    end
  end

  # After a decision: every approver's inbox row is dismissed and the card
  # re-renders for every open session.
  defp resolve(card, profile, post) do
    for user_id <- profile.approver_user_ids || [] do
      Platform.Inbox.dismiss_by_source(user_id, @source_type, post.id, kind: @kind)
    end

    case rerender(card) do
      {:ok, _} -> :ok
      error -> Logger.warning("[Social] card #{card.id} re-render failed: #{inspect(error)}")
    end
  end

  @doc """
  Re-renders a card: bumps `props.rev` through `Chat.patch_canvas(:system,
  ...)`, which broadcasts the canvas update so every open session renders
  `card_view/2` again, and re-stores `card_digest` from the patched
  document.
  """
  @spec rerender(ApprovalCard.t()) :: {:ok, ApprovalCard.t()} | {:error, term()}
  def rerender(%ApprovalCard{} = card) do
    with %Platform.Chat.Canvas{} = canvas <-
           Chat.get_canvas(card.canvas_id) || {:error, :not_found},
         {:ok, document} <- current_document(card.canvas_id),
         rev = rev_of(document) + 1,
         {:ok, _canvas} <-
           Chat.patch_canvas(:system, canvas, [{:set_props, "root", %{"rev" => rev}}]),
         {:ok, patched} <- current_document(card.canvas_id) do
      card |> Changeset.change(card_digest: digest(patched)) |> Repo.update()
    else
      {:conflict, payload} -> {:error, {:conflict, payload}}
      error -> error
    end
  end

  defp rev_of(%{"root" => %{"props" => %{"rev" => rev}}}) when is_integer(rev), do: rev
  defp rev_of(_), do: 0

  # ── View ─────────────────────────────────────────────────────────────

  @doc """
  What the card shows `viewer` (`{:user, id}`, `{:agent, id}`, or nil).

  A viewer who passes `Platform.Social.approver_check/3` RIGHT NOW gets
  `role: :approver` and the preview: body, media, link, hashtags, platform,
  character count against the platform limit, schedule, provenance, the
  edited-by line, the content `fingerprint`, and the `actions` while the
  card is pending (`:approve`, or `:copy` on a draft_only account, plus
  `:edit` and `:reject`). Everyone else, agents included, gets
  `role: :viewer` with the status line only: no text, media or actions.
  """
  @spec card_view(term(), term()) :: map()
  def card_view(card_id, viewer) do
    with {:ok, card_id} <- Ecto.UUID.cast(card_id),
         %ApprovalCard{} = card <- Repo.get(ApprovalCard, card_id),
         %Post{} = post <- Repo.get(Post, card.post_id),
         {:ok, account} <- fetch_account(post),
         {:ok, profile} <- Social.profile_of_post(post) do
      base = %{
        found: true,
        card_id: card.id,
        state: card.state,
        status: status_line(card, post, account),
        profile_name: profile.name,
        handle: account.handle,
        platform: account.platform,
        platform_label: platform_label(account.platform),
        scheduled_at: post.scheduled_at
      }

      if approver?(viewer, profile) do
        Map.merge(base, approver_view(card, post, account, profile))
      else
        Map.put(base, :role, :viewer)
      end
    else
      _ ->
        %{
          found: false,
          role: :viewer,
          status: %{tone: :muted, text: "This card is no longer available."}
        }
    end
  end

  defp approver?({:user, user_id}, profile),
    do: Social.approver_check(profile.org_id, profile, user_id) == :ok

  defp approver?(_viewer, _profile), do: false

  defp approver_view(card, post, account, profile) do
    limit = Map.get(@platform_limits, account.platform)
    count = String.length(post.body || "")
    draft_only? = account.approval_mode == "draft_only"

    actions =
      if card.state == "pending" and post.status == "needs_approval",
        do: [if(draft_only?, do: :copy, else: :approve), :edit, :reject],
        else: []

    %{
      role: :approver,
      body: post.body || "",
      link_url: post.link_url,
      hashtags: profile.default_hashtags || [],
      media: media(post),
      char_count: count,
      char_limit: limit,
      over_limit?: is_integer(limit) and count > limit,
      draft_only?: draft_only?,
      provenance: provenance(post),
      edited_by: card.edited_by_user_id && user_name(card.edited_by_user_id),
      fingerprint: fingerprint(post),
      actions: actions
    }
  end

  defp media(%Post{media_file_ids: ids, media_meta: meta}) do
    for id <- ids || [], file = Platform.Files.get_file(id), file != nil do
      facts = Map.get(meta || %{}, id) || %{}

      %{
        id: id,
        src: "/files/blob/#{id}",
        content_type: file.content_type,
        width: facts["width"],
        height: facts["height"]
      }
    end
  end

  defp provenance(%Post{} = post) do
    if post.episode_url || post.task_id || post.meeting_id do
      agent = agent_name(post)
      source = if post.episode_url, do: " from #{post.episode_url}", else: ""

      range =
        if is_number(post.start_s) and is_number(post.end_s),
          do: ", #{clock(post.start_s)}-#{clock(post.end_s)}",
          else: ""

      "Drafted by #{agent}#{source}#{range}"
    end
  end

  # Through the association member 2 declared on Social's own schema.
  defp agent_name(%Post{generated_by_agent_id: nil}), do: "an agent"

  defp agent_name(post) do
    case Repo.preload(post, :generated_by_agent).generated_by_agent do
      %{name: name} when is_binary(name) -> name
      _ -> "an agent"
    end
  end

  defp clock(seconds) do
    total = trunc(seconds)
    "#{div(total, 60)}:#{String.pad_leading(Integer.to_string(rem(total, 60)), 2, "0")}"
  end

  @doc """
  The card's status line, `%{tone: tone, text: text}` plus `:external_url`
  when published. Tones are semantic: `:warning`, `:muted`, `:success`,
  `:error`.
  """
  @spec status_line(ApprovalCard.t(), Post.t(), Account.t()) :: map()
  def status_line(card, post, account) do
    label = platform_label(account.platform)

    cond do
      card.decision == "reject" or Post.rejected?(post) ->
        %{
          tone: :muted,
          text: "Rejected by #{user_name(card.decided_by_user_id)}: #{post.rejection_reason}"
        }

      post.status == "published" ->
        %{tone: :success, text: "Published on #{label}", external_url: post.external_url}

      post.status == "failed" ->
        %{tone: :error, text: "#{label} refused the post: #{post.error}"}

      post.status in ~w(approved scheduled) ->
        %{
          tone: :muted,
          text:
            "Approved by #{user_name(post.approved_by_user_id)}, #{hhmm(post.approved_at)}. " <>
              "Publishing #{publishing_text(post)}"
        }

      post.status == "needs_approval" ->
        %{tone: :warning, text: "Needs approval"}

      true ->
        %{tone: :muted, text: "Back in draft"}
    end
  end

  defp publishing_text(%Post{scheduled_at: %DateTime{} = at}), do: when_text(at)
  defp publishing_text(_), do: "now"

  defp schedule_text(%Post{scheduled_at: %DateTime{} = at}), do: when_text(at)
  defp schedule_text(_), do: "not scheduled"

  @doc false
  def when_text(%DateTime{} = at), do: Calendar.strftime(at, "%a %d %b %H:%M UTC")

  defp hhmm(%DateTime{} = at), do: Calendar.strftime(at, "%H:%M")
  defp hhmm(_), do: ""

  defp user_name(nil), do: "someone"

  defp user_name(user_id) do
    case Platform.Accounts.get_user(user_id) do
      %{name: name} when is_binary(name) and name != "" -> name
      %{email: email} when is_binary(email) -> email
      _ -> "someone"
    end
  end

  @doc "A platform's display label (\"LinkedIn\")."
  @spec platform_label(String.t() | nil) :: String.t()
  def platform_label(platform), do: Map.get(@platform_labels, platform, platform || "")

  @doc "The text limits per platform (an assumption, see the attribute)."
  @spec platform_limits() :: %{String.t() => pos_integer()}
  def platform_limits, do: @platform_limits
end
