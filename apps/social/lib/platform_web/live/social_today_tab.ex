defmodule PlatformWeb.SocialTodayTab do
  @moduledoc "Studio work for the currently visible, enabled profiles."
  use PlatformWeb.SocialTab

  alias Platform.Social.Studio
  alias Platform.Social
  alias PlatformWeb.SocialScope

  @impl true
  def enabled?, do: true

  @impl true
  def all_brands?, do: true

  @impl true
  def init(socket) do
    socket
    |> assign(:studio_today_posts, [])
    |> assign(:studio_today_clips, [])
    |> assign(:studio_results, [])
    |> assign(:studio_goals, [])
    |> assign(:studio_pitches, [])
    |> assign(:studio_profile_accessible?, false)
    |> assign(:studio_loaded_profile_ids, MapSet.new())
    |> assign(:studio_post_detail, nil)
    |> assign(:studio_post_error, nil)
    |> assign(:studio_plan_time, "")
    |> assign(:studio_edit_text, "")
    |> assign(:studio_edit_account, nil)
    |> assign(:studio_change_reason, "")
  end

  @impl true
  def events,
    do:
      ~w(studio_open_post studio_approve_post studio_revoke_post studio_submit_post studio_plan_post studio_cancel_plan studio_save_post studio_request_changes studio_accept_clip)

  @impl true
  def load(socket) do
    profiles = SocialScope.visible_profiles(socket)

    profiles =
      case socket.assigns.scope do
        :all -> profiles
        {:profile, %{id: id}} -> Enum.filter(profiles, &(&1.id == id))
        _ -> []
      end

    profiles = Enum.filter(profiles, &accessible?(socket, &1))

    posts =
      profiles
      |> Enum.flat_map(fn profile ->
        case Studio.list_posts(profile.org_id, profile.id) do
          {:ok, posts} -> Enum.map(posts, &%{post: &1, profile: profile})
          _ -> []
        end
      end)

    clips = Enum.flat_map(profiles, &clip_items(&1, socket.assigns.user))

    goals =
      Enum.flat_map(profiles, fn profile ->
        profile.org_id
        |> Social.list_accounts(profile_id: profile.id)
        |> Enum.flat_map(fn account ->
          case Social.Results.weekly_progress(account) do
            nil -> []
            progress -> [%{account: account, profile: profile, progress: progress}]
          end
        end)
      end)

    pitches =
      profiles
      |> Enum.flat_map(fn profile ->
        Social.Ideas.list({:tenant, profile.org_id}, profile.id)
        |> Enum.filter(&(!is_nil(&1.created_by_agent_id)))
        |> Enum.map(&%{idea: &1, profile: profile})
      end)
      |> Enum.take(5)

    socket
    |> assign(:studio_today_posts, posts)
    |> assign(:studio_today_clips, clips)
    |> assign(
      :studio_results,
      Social.Results.by_idea(profiles, 7)
      |> Enum.filter(fn row ->
        Enum.any?(row.metrics, fn {_key, value} -> not is_nil(value) end)
      end)
      |> Enum.take(5)
    )
    |> assign(:studio_goals, goals)
    |> assign(:studio_pitches, pitches)
    |> assign(:studio_profile_accessible?, profiles != [])
    |> assign(:studio_loaded_profile_ids, MapSet.new(profiles, & &1.id))
    |> assign(:studio_post_detail, nil)
  end

  # Revalidate cached material without resetting an authorised user's open form.
  def refresh_authorization(socket) do
    profiles = SocialScope.visible_profiles(socket)
    socket = SocialScope.refresh_studio_tabs(socket, profiles)
    has_today? = Enum.any?(socket.assigns.tabs, &(&1.key == "today"))

    allowed =
      profiles
      |> Enum.filter(&accessible?(socket, &1))
      |> MapSet.new(& &1.id)

    allowed =
      case socket.assigns.scope do
        {:profile, %{id: id}} -> MapSet.intersection(allowed, MapSet.new([id]))
        :all -> allowed
        _ -> MapSet.new()
      end

    keep = fn item -> MapSet.member?(allowed, item.profile.id) end
    detail = socket.assigns.studio_post_detail

    socket =
      if has_today? and not MapSet.subset?(allowed, socket.assigns.studio_loaded_profile_ids) do
        socket |> load() |> assign(:studio_post_detail, detail)
      else
        socket
      end

    socket
    |> assign(:studio_today_posts, Enum.filter(socket.assigns.studio_today_posts, keep))
    |> assign(:studio_today_clips, Enum.filter(socket.assigns.studio_today_clips, keep))
    |> assign(:studio_goals, Enum.filter(socket.assigns.studio_goals, keep))
    |> assign(:studio_pitches, Enum.filter(socket.assigns.studio_pitches, keep))
    |> assign(
      :studio_results,
      Enum.filter(socket.assigns.studio_results, &MapSet.member?(allowed, &1.profile_id))
    )
    |> assign(:studio_post_detail, if(detail && keep.(detail), do: detail, else: nil))
    |> assign(:studio_profile_accessible?, MapSet.size(allowed) > 0)
    |> assign(:studio_loaded_profile_ids, allowed)
  end

  @impl true
  def handle_event("studio_open_post", %{"id" => id}, socket) do
    socket = load(socket)
    detail = detail(socket, id)

    {:noreply,
     socket
     |> SocialScope.select_tab("today")
     |> assign(:studio_post_detail, detail)
     |> assign(:studio_edit_text, if(detail, do: detail.post.body || "", else: ""))
     |> assign(:studio_edit_account, if(detail, do: detail.post.account_id, else: nil))
     |> assign(:studio_post_error, nil)
     |> focus_detail(detail)}
  end

  def handle_event("studio_approve_post", _params, socket) do
    with %{post: post, profile: profile} <- socket.assigns.studio_post_detail,
         true <- current_profile?(socket, profile.id),
         %{id: user_id} <- socket.assigns.user,
         {:ok, %{post: updated}} <-
           Studio.approve_version(profile.org_id, post.id, user_id, %{
             version: post.version,
             state_rev: post.state_rev,
             fingerprint: Platform.Social.Approvals.content_fingerprint(post)
           }) do
      socket = load(socket)
      detail = detail(socket, updated.id)
      {:noreply, socket |> assign(:studio_post_detail, detail) |> assign(:studio_post_error, nil)}
    else
      _ ->
        socket =
          case socket.assigns.studio_post_detail do
            %{profile: profile} ->
              if current_profile?(socket, profile.id) do
                assign(
                  socket,
                  :studio_post_error,
                  "This post could not be approved. Refresh it and try again."
                )
              else
                refresh_scope(socket)
              end

            _ ->
              socket
          end

        {:noreply, socket}
    end
  end

  def handle_event("studio_submit_post", _params, socket) do
    with %{post: post, profile: profile} <- socket.assigns.studio_post_detail,
         true <- current_profile?(socket, profile.id),
         %{id: user_id} <- socket.assigns.user,
         {:ok, updated} <-
           Studio.resubmit(profile.org_id, post.id, user_id, %{
             version: post.version,
             state_rev: post.state_rev
           }) do
      socket = load(socket)
      detail = detail(socket, updated.id)
      {:noreply, socket |> assign(:studio_post_detail, detail) |> assign(:studio_post_error, nil)}
    else
      _ ->
        {:noreply,
         failed_action(
           socket,
           :studio_post_error,
           "This post could not be submitted. Refresh it and try again."
         )}
    end
  end

  def handle_event("studio_revoke_post", _params, socket) do
    with %{post: post, profile: profile, receipts: receipts} <- socket.assigns.studio_post_detail,
         true <- current_profile?(socket, profile.id),
         %{id: user_id} <- socket.assigns.user,
         %{id: receipt_id} <- Enum.find(receipts, &(&1.state == "current")),
         {:ok, updated} <-
           Studio.revoke_approval(profile.org_id, post.id, user_id, %{
             version: post.version,
             state_rev: post.state_rev,
             approval_id: receipt_id
           }) do
      {:noreply, show_updated(socket, updated)}
    else
      _ ->
        {:noreply,
         failed_action(
           socket,
           :studio_post_error,
           "Approval could not be revoked. Refresh and try again."
         )}
    end
  end

  def handle_event("studio_plan_post", %{"planned_at" => text}, socket) do
    socket = assign(socket, :studio_plan_time, text)

    with %{post: post, profile: profile} <- socket.assigns.studio_post_detail,
         true <- current_profile?(socket, profile.id),
         %{id: user_id} <- socket.assigns.user,
         {:ok, naive} <- parse_local_time(text),
         {:ok, local} <- DateTime.from_naive(naive, profile.timezone, Tzdata.TimeZoneDatabase),
         {:ok, utc} <- DateTime.shift_zone(local, "Etc/UTC", Tzdata.TimeZoneDatabase),
         {:ok, %{post: updated}} <-
           Studio.plan_post(
             profile.org_id,
             post.id,
             user_id,
             %{version: post.version, state_rev: post.state_rev},
             utc
           ) do
      {:noreply, show_updated(socket, updated)}
    else
      _ ->
        {:noreply,
         failed_action(
           socket,
           :studio_post_error,
           "The plan could not be saved. Check the time and current approval."
         )}
    end
  end

  def handle_event("studio_cancel_plan", _params, socket) do
    with %{post: post, profile: profile} <- socket.assigns.studio_post_detail,
         true <- current_profile?(socket, profile.id),
         %{id: user_id} <- socket.assigns.user,
         {:ok, updated} <-
           Studio.cancel_plan(profile.org_id, post.id, user_id, %{
             version: post.version,
             state_rev: post.state_rev
           }) do
      {:noreply, show_updated(socket, updated)}
    else
      _ ->
        {:noreply,
         failed_action(
           socket,
           :studio_post_error,
           "The plan could not be cancelled. Refresh and try again."
         )}
    end
  end

  def handle_event("studio_save_post", %{"body" => body} = params, socket) do
    account_id = Map.get(params, "account_id")
    socket = socket |> assign(:studio_edit_text, body) |> assign(:studio_edit_account, account_id)
    attrs = if account_id, do: %{body: body, account_id: account_id}, else: %{body: body}

    with %{post: post, profile: profile} <- socket.assigns.studio_post_detail,
         true <- current_profile?(socket, profile.id),
         %{id: user_id} <- socket.assigns.user,
         {:ok, %{post: updated}} <-
           Studio.save_version(profile.org_id, post.id, user_id, attrs, %{
             version: post.version,
             state_rev: post.state_rev
           }) do
      {:noreply, show_updated(socket, updated)}
    else
      _ ->
        {:noreply,
         failed_action(
           socket,
           :studio_post_error,
           "Your changes were not saved. Refresh the post and try again."
         )}
    end
  end

  def handle_event("studio_request_changes", %{"reason" => reason}, socket) do
    socket = assign(socket, :studio_change_reason, reason)

    with %{post: post, profile: profile} <- socket.assigns.studio_post_detail,
         true <- current_profile?(socket, profile.id),
         %{id: user_id} <- socket.assigns.user,
         {:ok, updated} <-
           Studio.request_changes(
             profile.org_id,
             post.id,
             user_id,
             %{
               version: post.version,
               state_rev: post.state_rev
             },
             reason
           ) do
      {:noreply, show_updated(socket, updated)}
    else
      _ ->
        {:noreply,
         failed_action(
           socket,
           :studio_post_error,
           "Changes could not be requested. Check the reason and try again."
         )}
    end
  end

  def handle_event(
        "studio_accept_clip",
        %{"clip_id" => id, "render_id" => render_id, "account_id" => account_id},
        socket
      ) do
    item = Enum.find(socket.assigns.studio_today_clips, &(&1.clip.id == id))

    with %{profile: profile} <- item,
         true <- current_profile?(socket, profile.id),
         %{id: user_id} <- socket.assigns.user,
         {:ok, %{posts: posts}} <-
           Studio.accept_render(profile.org_id, id, user_id, %{
             render_id: render_id,
             account_ids: [account_id]
           }) do
      socket = load(socket)
      detail = detail(socket, hd(posts).id)

      {:noreply,
       socket
       |> assign(:studio_post_detail, detail)
       |> assign(:studio_edit_text, if(detail, do: detail.post.body || "", else: ""))
       |> assign(:studio_edit_account, if(detail, do: detail.post.account_id, else: nil))
       |> assign(:studio_post_error, nil)
       |> focus_detail(detail)}
    else
      _ ->
        socket =
          if item && not current_profile?(socket, item.profile.id) do
            refresh_scope(socket)
          else
            assign(
              socket,
              :studio_post_error,
              "The clip could not be prepared. Check the account and try again."
            )
          end

        {:noreply, socket}
    end
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  @impl true
  def handle_info(:studio_clips_imported, socket), do: {:noreply, load(socket)}

  def handle_info(:studio_scope_recheck, %{assigns: %{scope: {:profile, %{id: id}}}} = socket) do
    {:noreply, if(current_profile?(socket, id), do: socket, else: refresh_scope(socket))}
  end

  def handle_info(_, _socket), do: :unhandled

  defp show_updated(socket, updated) do
    socket = load(socket)
    detail = detail(socket, updated.id)

    socket
    |> assign(:studio_post_detail, detail)
    |> assign(:studio_edit_text, if(detail, do: detail.post.body || "", else: ""))
    |> assign(:studio_edit_account, if(detail, do: detail.post.account_id, else: nil))
    |> assign(:studio_post_error, nil)
  end

  defp focus_detail(socket, nil), do: socket

  defp focus_detail(socket, %{post: post}),
    do: Phoenix.LiveView.push_event(socket, "studio:focus_detail", %{id: post.id})

  defp parse_local_time(<<_::binary-size(16)>> = text),
    do: NaiveDateTime.from_iso8601(text <> ":00")

  defp parse_local_time(text), do: NaiveDateTime.from_iso8601(text)

  defp detail(socket, id) do
    case Enum.find(socket.assigns.studio_today_posts, &(&1.post.id == id)) do
      nil -> nil
      %{post: post, profile: profile} -> post_item(post, profile, socket.assigns.user)
    end
  end

  defp post_item(post, profile, user) do
    account = Social.get_account(profile.org_id, post.account_id)

    can_approve? =
      account != nil and is_nil(account.archived_at) and user != nil and
        Social.post_approver_check(profile.org_id, profile, account, user.id) == :ok

    receipts =
      case Studio.list_approvals(profile.org_id, post.id) do
        {:ok, rows} -> rows
        _ -> []
      end

    can_cancel? =
      account != nil and user != nil and
        Social.post_rejecter_check(profile.org_id, profile, account, user.id) == :ok

    current_receipt = Enum.find(receipts, &(&1.state == "current"))

    needs_refresh? =
      post.status in ["approved", "planned"] and account != nil and
        (is_nil(current_receipt) or
           Social.post_approver_check(
             profile.org_id,
             profile,
             account,
             current_receipt.approved_by_user_id
           ) != :ok)

    destinations =
      Social.list_accounts(profile.org_id, profile_id: profile.id)
      |> Enum.filter(
        &(user && Social.post_approver_check(profile.org_id, profile, &1, user.id) == :ok)
      )

    %{
      post: post,
      profile: profile,
      account: account,
      can_approve?: can_approve?,
      can_cancel?: can_cancel?,
      needs_refresh?: needs_refresh?,
      receipts: receipts,
      history: Platform.Social.PostEvents.list_for_post(post.id),
      destinations: destinations
    }
  end

  defp clip_items(profile, user) do
    accounts =
      Social.list_accounts(profile.org_id, profile_id: profile.id)
      |> Enum.filter(
        &(user && Social.post_approver_check(profile.org_id, profile, &1, user.id) == :ok)
      )

    profile.org_id
    |> Social.list_clips(profile_id: profile.id, flow: "studio")
    |> Enum.filter(&(&1.review_status == "pending" and is_nil(&1.removed_at)))
    |> Enum.flat_map(fn clip ->
      case Social.ClipVersions.recent(profile.org_id, profile.id, clip.id) do
        {:ok, [_ | _] = renders} ->
          [%{clip: clip, profile: profile, renders: renders, accounts: accounts}]

        _ ->
          []
      end
    end)
  end

  defp current_profile?(socket, profile_id) do
    allowed_scope? =
      case socket.assigns.scope do
        :all -> true
        {:profile, %{id: id}} -> id == profile_id
        _ -> false
      end

    allowed_scope? and
      Enum.any?(
        SocialScope.visible_profiles(socket),
        &(&1.id == profile_id and accessible?(socket, &1))
      )
  end

  defp failed_action(socket, key, message) do
    case socket.assigns.studio_post_detail do
      %{profile: profile} ->
        if current_profile?(socket, profile.id),
          do: assign(socket, key, message),
          else: refresh_scope(socket)

      _ ->
        assign(socket, key, message)
    end
  end

  defp accessible?(%{assigns: %{user: %{id: user_id}}}, profile) do
    profile.studio_enabled == true and Studio.require_social_use(user_id, profile) == :ok
  end

  defp accessible?(_, _), do: false

  defp refresh_scope(%{assigns: %{scope: :all}} = socket), do: SocialScope.select_all(socket)

  defp refresh_scope(%{assigns: %{scope: {:profile, %{id: id}}}} = socket) do
    profile = Enum.find(SocialScope.visible_profiles(socket), &(&1.id == id))
    SocialScope.load_profile(socket, profile)
  end

  defp refresh_scope(socket), do: socket

  @impl true
  def pane(assigns) do
    ~H"""
    <section data-role="social-studio-today" class="space-y-4">
      <h1 class="text-2xl font-semibold">Today</h1>
      <div class="grid gap-5 xl:grid-cols-[minmax(0,1fr)_minmax(0,1.2fr)_minmax(0,1fr)]">
        <div class="space-y-3 min-w-0">
          <h2 class="text-lg font-semibold">Needs attention</h2>
          <p
            :if={@studio_today_posts == [] and @studio_today_clips == []}
            class="text-base-content/70"
          >
            Nothing needs your attention yet.
          </p>
          <p :if={@studio_post_error && is_nil(@studio_post_detail)} role="alert">
            {@studio_post_error}
          </p>
          <section
            :for={item <- @studio_today_clips}
            data-role="studio-clip"
            data-clip-id={item.clip.id}
            class="rounded-box border border-base-300 p-4 space-y-2"
          >
            <h2 class="font-semibold">{item.clip.title || "Untitled clip"}</h2>
            <video
              :if={hd(item.renders).file_id}
              controls
              preload="metadata"
              src={"/files/blob/#{hd(item.renders).file_id}"}
              class="max-h-96 w-full"
            >
            </video>
            <form id={"studio-clip-#{item.clip.id}"} phx-submit="studio_accept_clip" class="space-y-2">
              <input type="hidden" name="clip_id" value={item.clip.id} />
              <input type="hidden" name="render_id" value={hd(item.renders).id} />
              <p>Version {hd(item.renders).rev}</p>
              <label>
                Account
                <select name="account_id" class="select">
                  <option value="">Choose an account</option>
                  <option :for={account <- item.accounts} value={account.id}>
                    {account.platform} · {account.handle || "Account"}
                  </option>
                </select>
              </label>
              <button type="submit" class="btn btn-primary">Prepare post</button>
            </form>
          </section>
          <div :for={item <- @studio_today_posts} data-role="studio-post" data-post-id={item.post.id}>
            <button
              type="button"
              phx-click="studio_open_post"
              phx-value-id={item.post.id}
              data-role="studio-post-open"
              data-post-id={item.post.id}
              class="link"
            >
              {item.post.body || "Untitled post"}
            </button>
            <p class="text-sm text-base-content/70">{item.profile.name}</p>
          </div>
        </div>
        <div class="min-w-0 space-y-3">
          <section class="rounded-box border border-base-300 p-4" data-role="studio-results">
            <h2 class="text-lg font-semibold">Results · last 7 days</h2>
            <p :if={@studio_results == []}>No measured results yet.</p>
            <p :for={item <- @studio_results}>
              {item.title || "Untitled post"} · views {item.metrics.views || "unavailable"}
            </p>
            <div :for={item <- @studio_goals} data-role="studio-weekly-goal">
              {item.profile.name} · {item.account.platform} · {item.progress.published} / {item.progress.goal} published this week
            </div>
            <p :if={@studio_goals == []}>No weekly goals set.</p>
          </section>
          <p :if={is_nil(@studio_post_detail)} class="text-base-content/70">
            Select a post to review its content and history.
          </p>
          <section
            :if={@studio_post_detail}
            id={"studio-post-detail-#{@studio_post_detail.post.id}"}
            data-post-id={@studio_post_detail.post.id}
            phx-hook="StudioPostFocus"
            tabindex="-1"
            data-role="studio-post-detail"
            class="scroll-mt-4 rounded-box border border-base-300 p-4"
          >
            <h2 class="text-lg font-semibold">Post review</h2>
            <p>{@studio_post_detail.post.body}</p>
            <video
              :if={
                @studio_post_detail.post.clip_render_id &&
                  List.first(@studio_post_detail.post.media_file_ids || [])
              }
              controls
              preload="metadata"
              class="max-h-96 w-full"
              src={"/files/blob/#{List.first(@studio_post_detail.post.media_file_ids || [])}"}
            >
            </video>
            <p :if={@studio_post_detail.account}>
              {@studio_post_detail.account.handle || @studio_post_detail.account.platform}
            </p>
            <p
              :if={@studio_post_detail.account && @studio_post_detail.account.archived_at}
              role="status"
            >
              This account is archived. Choose an available destination and save to retarget the post.
            </p>
            <p>
              Version {@studio_post_detail.post.version} · {case @studio_post_detail.post.status do
                "approved" -> "Approved"
                "planned" -> "Planned in Burrow"
                other -> other
              end}
            </p>
            <details :if={@studio_post_detail.history != []}>
              <summary>History</summary>
              <p :for={event <- @studio_post_detail.history} data-role="studio-history">
                {event.action} · {event.actor_kind} {event.actor_id} · version {event.post_version} · {Calendar.strftime(
                  event.inserted_at,
                  "%Y-%m-%d %H:%M UTC"
                )}
                <span :if={event.note}>{event.note}</span>
              </p>
            </details>
            <div :for={receipt <- @studio_post_detail.receipts} data-role="studio-receipt">
              Approval for version {receipt.version} · {receipt.state} · approver {receipt.approved_by_user_id} · account {receipt.account_id} · {Calendar.strftime(
                receipt.approved_at,
                "%Y-%m-%d %H:%M UTC"
              )}
            </div>
            <button
              :if={
                @studio_post_detail.can_approve? and
                  Enum.any?(@studio_post_detail.receipts, &(&1.state == "current")) and
                  @studio_post_detail.post.status in ["approved", "planned"]
              }
              type="button"
              phx-click="studio_revoke_post"
              data-role="studio-revoke"
              class="btn btn-ghost"
            >
              Revoke approval
            </button>
            <form
              :if={
                @studio_post_detail.can_approve? or
                  (@studio_post_detail.account && @studio_post_detail.account.archived_at &&
                     @studio_post_detail.can_cancel?)
              }
              id="studio-edit-form"
              phx-submit="studio_save_post"
              class="space-y-2"
            >
              <label for="studio-edit-body">Post text</label>
              <textarea id="studio-edit-body" name="body" class="textarea w-full">{@studio_edit_text}</textarea>
              <label for="studio-edit-account">Destination account</label>
              <select id="studio-edit-account" name="account_id" class="select">
                <option
                  :if={
                    not Enum.any?(
                      @studio_post_detail.destinations,
                      &(&1.id == @studio_post_detail.post.account_id)
                    )
                  }
                  value={@studio_post_detail.post.account_id}
                  selected={@studio_edit_account == @studio_post_detail.post.account_id}
                >
                  Current account (unavailable)
                </option>
                <option
                  :for={account <- @studio_post_detail.destinations}
                  value={account.id}
                  selected={@studio_edit_account == account.id}
                >
                  {account.platform} · {account.handle || "Account"}
                </option>
              </select>
              <p
                :if={@studio_post_detail.post.status in ["approved", "planned"]}
                data-role="studio-edit-warning"
              >
                Saving changes revokes approval and cancels any plan.
              </p>
              <button type="submit" class="btn btn-outline">Save changes</button>
            </form>
            <button
              :if={
                @studio_post_detail.can_approve? and
                  (@studio_post_detail.post.status == "needs_approval" or
                     @studio_post_detail.needs_refresh?)
              }
              type="button"
              phx-click="studio_approve_post"
              data-role="studio-approve"
              class="btn btn-primary"
            >
              {if @studio_post_detail.needs_refresh?, do: "Refresh approval", else: "Approve content"}
            </button>
            <p :if={@studio_post_detail.can_approve? and @studio_post_detail.needs_refresh?}>
              The previous approver no longer has authority. Refreshing approval cancels any existing plan.
            </p>
            <form
              :if={
                @studio_post_detail.can_approve? and
                  @studio_post_detail.post.status == "needs_approval"
              }
              id="studio-request-changes-form"
              phx-submit="studio_request_changes"
              class="space-y-2"
            >
              <label for="studio-change-reason">What should change?</label>
              <textarea id="studio-change-reason" name="reason" class="textarea w-full">{@studio_change_reason}</textarea>
              <button type="submit" class="btn btn-outline">Request changes</button>
            </form>
            <button
              :if={@studio_post_detail.can_approve? and @studio_post_detail.post.status == "draft"}
              type="button"
              phx-click="studio_submit_post"
              data-role="studio-submit"
              class="btn btn-primary"
            >
              {if @studio_post_detail.post.rejected_at,
                do: "Resubmit for approval",
                else: "Submit for approval"}
            </button>
            <form
              :if={
                @studio_post_detail.can_approve? and not @studio_post_detail.needs_refresh? and
                  @studio_post_detail.post.status in ["approved", "planned"]
              }
              id="studio-plan-form"
              phx-submit="studio_plan_post"
              class="space-y-2"
            >
              <label for="studio-plan-time">Time ({@studio_post_detail.profile.timezone})</label>
              <input
                id="studio-plan-time"
                type="datetime-local"
                name="planned_at"
                value={@studio_plan_time}
                class="input"
              />
              <button class="btn btn-primary" type="submit">Plan in Burrow</button>
            </form>
            <button
              :if={@studio_post_detail.can_cancel? and @studio_post_detail.post.status == "planned"}
              type="button"
              phx-click="studio_cancel_plan"
              data-role="studio-cancel-plan"
              class="btn btn-ghost"
            >
              Cancel plan
            </button>
            <p :if={@studio_post_error} role="alert">{@studio_post_error}</p>
          </section>
        </div>
        <aside class="min-w-0 space-y-3">
          <section class="rounded-box border border-base-300 p-4">
            <h2 class="text-lg font-semibold">Agent ideas</h2>
            <p :if={@studio_pitches == []}>No agent ideas yet.</p>
            <p :for={item <- @studio_pitches}>{item.idea.title} · {item.profile.name}</p>
            <button type="button" phx-click="select_tab" phx-value-tab="ideas" class="link">
              Open Ideas
            </button>
          </section>
          <section data-role="studio-trends" class="rounded-box border border-base-300 p-4">
            <h2 class="text-lg font-semibold">Trends</h2>
            <p>No trend data available.</p>
          </section>
          <.live_component
            :if={(@scope != :all and @profile) && @studio_profile_accessible?}
            module={PlatformWeb.SocialStudioPairing}
            id="studio-pairing"
            profile={@profile}
            user={@user}
          />
        </aside>
      </div>
    </section>
    """
  end
end
