defmodule PlatformWeb.SocialDraftCard do
  @moduledoc """
  One legacy draft in the Queue's "Drafts" group (B3).

  Shows the account and platform, the caption, the YouTube title ("Title
  (sent to YouTube)", YouTube only), the media (read only) and the publish
  time. A viewer who may not edit sees the content only when
  `Platform.Social.PostPresentation` describes the post for them (otherwise
  just account, platform and "Draft"); media names, types and thumbnails need
  `files.read` on the file's project for every viewer, approvers included. A viewer who may edit it (`Platform.Social.post_approver_check/4`) can change ONLY the caption, the YouTube title and
  the time, then "Save draft" or "Send for review". Both go through
  `Platform.Social.edit_draft/5`, so the card never writes anything itself.

  The time is typed in the profile's own zone (`datetime-local`, the zone
  named in the label), as the Calendar and Today draw it, and is stored in
  UTC. A refusal keeps every input and lists what is missing. A successful
  send tells the Queue (`{PlatformWeb.SocialDraftCard, :sent, post_id}`) to
  re-read: the post then appears in the ordinary review placement.
  """
  use PlatformWeb, :live_component

  alias Platform.Social
  alias Platform.Social.{Account, Approvals}
  alias PlatformWeb.SocialCalendarClock

  @local_format "%Y-%m-%dT%H:%M"

  @impl true
  def update(assigns, socket) do
    socket =
      socket |> assign_new(:clip_title, fn -> nil end) |> assign(assigns) |> refresh_access()

    %{post: post, tz: tz} = socket.assigns
    stamp = {post.id, post.updated_at}

    # A refusal must not reset what the person typed: the form is rebuilt
    # only when the stored post changed underneath it.
    if socket.assigns[:stamp] == stamp do
      socket
    else
      socket
      |> assign(:stamp, stamp)
      |> assign(:form, form_from(post, tz))
      |> assign(:lines, [])
      |> assign(:notice, nil)
    end
    |> then(&{:ok, &1})
  end

  @impl true
  def handle_event("draft_change", params, socket) do
    socket = refresh_access(socket)

    if socket.assigns.can_edit?,
      do: {:noreply, assign(socket, :form, merge_form(socket.assigns.form, params))},
      else: {:noreply, socket}
  end

  def handle_event("draft_submit", params, socket) do
    socket = refresh_access(socket)
    %{post: post, user: user, profile: profile, account: account, tz: tz} = socket.assigns
    submit? = params["intent"] == "submit"

    if socket.assigns.can_edit? do
      form = merge_form(socket.assigns.form, params)
      socket = assign(socket, form: form, notice: nil)

      with {:ok, attrs} <- attrs_from(form, post, account, tz),
           {:ok, saved} <-
             Social.edit_draft(profile.org_id, post.id, user.id, attrs, submit: submit?) do
        if submit? do
          send(self(), {__MODULE__, :sent, saved.id})
          {:noreply, assign(socket, lines: [])}
        else
          {:noreply,
           socket
           |> assign(:post, saved)
           |> assign(:stamp, {saved.id, saved.updated_at})
           |> assign(:form, form_from(saved, tz))
           |> assign(:lines, [])
           |> assign(:notice, "Draft saved.")}
        end
      else
        {:error, reason} -> {:noreply, assign(socket, :lines, refusal_lines(reason))}
      end
    else
      {:noreply, assign(socket, :lines, ["You can't change this draft."])}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, refresh_access(socket)}

  # Everything this card shows that depends on who is looking (edit authority,
  # the PostPresentation boundary, `files.read` on each file) is read afresh on
  # every update and every event, so a re-render never shows what the viewer
  # lost since the last one. `PostPresentation.authorize/2` is load-local: it is
  # computed here for this card's profile and never held in assigns. This is
  # presentation only; `Social.edit_draft/5` re-checks authority on the locked
  # row by itself.
  defp refresh_access(socket) do
    %{post: held_post, account: held_account, profile: held_profile, user: user} =
      socket.assigns

    case current_rows(held_post, held_account, held_profile) do
      {:ok, post, account, profile} ->
        can_edit? = Social.post_approver_check(profile.org_id, profile, account, user.id) == :ok

        context =
          Platform.Social.PostPresentation.authorize({:user, user.id}, [profile.id])

        tz = SocialCalendarClock.profile_zone(profile)

        socket
        |> assign(:tz, tz)
        |> assign(:can_edit?, can_edit?)
        |> read_only_form(can_edit?, post, tz)
        |> assign(
          :presentation,
          Platform.Social.PostPresentation.describe(post, account, context)
        )
        |> assign_media(post, profile, user)

      :gone ->
        # The post, its account or its brand no longer exists: a minimal card,
        # no form and nothing from the stale rows.
        socket
        |> assign(:tz, SocialCalendarClock.profile_zone(held_profile))
        |> assign(:can_edit?, false)
        |> assign(:presentation, nil)
        |> assign(:media, [])
        |> assign(:media_hidden, 0)
    end
  end

  # The post, its account and the account's profile as they are NOW (scoped to
  # the card's org), not the structs the Queue load put in assigns: the
  # approver list and the account owner can change after render.
  defp current_rows(%{id: post_id}, _account, %{org_id: org_id}) do
    with %{account_id: account_id} = post <- Social.get_post(org_id, post_id),
         %Account{profile_id: profile_id} = account <- Social.get_account(org_id, account_id),
         %{} = profile <- Social.get_profile(org_id, profile_id) do
      {:ok, post, account, profile}
    else
      _ -> :gone
    end
  end

  # A viewer who may not edit sees the post as it is stored now, never form
  # input held from an earlier render or sent with this event.
  defp read_only_form(socket, true, _post, _tz), do: socket

  defp read_only_form(socket, false, post, tz),
    do: socket |> assign(:post, post) |> assign(:form, form_from(post, tz))

  # ── Form ─────────────────────────────────────────────────────────────

  defp form_from(post, tz) do
    %{
      "body" => post.body || "",
      "title" => (post.platform_options || %{})["title"] || "",
      "at" => local_input(post.scheduled_at, tz)
    }
  end

  defp merge_form(form, params),
    do: Map.merge(form, Map.take(params, ["body", "title", "at"]))

  defp local_input(%DateTime{} = at, tz),
    do: at |> DateTime.shift_zone!(tz) |> Calendar.strftime(@local_format)

  defp local_input(_at, _tz), do: ""

  # Only the three editable fields, and the time only when the person changed
  # it (so saving never trims the stored seconds).
  defp attrs_from(form, post, account, tz) do
    attrs = %{body: form["body"]}

    attrs =
      if account.platform == "youtube", do: Map.put(attrs, :title, form["title"]), else: attrs

    original = local_input(post.scheduled_at, tz)

    case form["at"] do
      at when at == original ->
        {:ok, attrs}

      "" ->
        {:ok, Map.put(attrs, :scheduled_at, nil)}

      value ->
        case parse_local(value, tz) do
          {:ok, utc} -> {:ok, Map.put(attrs, :scheduled_at, utc)}
          :error -> {:error, :invalid_time}
        end
    end
  end

  defp parse_local(value, tz) when is_binary(value) do
    value = if byte_size(value) == 16, do: value <> ":00", else: value

    with true <- Regex.match?(~r/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\z/, value),
         {:ok, naive} <- NaiveDateTime.from_iso8601(value) do
      local =
        SocialCalendarClock.at_local(
          NaiveDateTime.to_date(naive),
          NaiveDateTime.to_time(naive),
          tz
        )

      {:ok, DateTime.shift_zone!(local, "Etc/UTC")}
    else
      _ -> :error
    end
  end

  # ── Refusals, in the person's words ──────────────────────────────────

  defp refusal_lines({:incomplete_post, lines}), do: lines
  defp refusal_lines(:invalid_time), do: ["That publish time isn't valid. Choose a publish time."]
  defp refusal_lines(:not_a_draft), do: ["This post is no longer a draft."]
  defp refusal_lines(:not_found), do: ["This draft is unavailable."]
  defp refusal_lines(:profile_has_no_channel), do: ["This brand has no channel for reviews yet."]

  defp refusal_lines(%Ecto.Changeset{errors: errors}) do
    for {field, error} <- errors do
      label = if field == :title, do: "Title", else: "Caption"
      message = PlatformWeb.CoreComponents.translate_error(error)
      if field == :title, do: message, else: "#{label} #{message}"
    end
  end

  defp refusal_lines(reason) when is_atom(reason),
    do: [PlatformWeb.SocialCardComponent.refusal_copy(reason)]

  defp refusal_lines(_reason), do: ["The draft could not be saved. Try again."]

  # ── Read-only facts ──────────────────────────────────────────────────

  # Names, types and thumbnails only for files the viewer may read
  # (`files.read` on the file's project, the decision the blob route and Today
  # apply). Approver status never widens this. The rest are counted, not named.
  defp assign_media(socket, %{media_file_ids: ids}, profile, user) do
    files = for id <- ids || [], file = Platform.Files.get_file(id), file != nil, do: file
    {readable, hidden} = Enum.split_with(files, &readable_file?(&1, profile, user))

    socket
    |> assign(:media, Enum.map(readable, &media_entry/1))
    |> assign(:media_hidden, length(hidden))
  end

  defp media_entry(file) do
    %{
      id: file.id,
      name: file.original_filename || file.name,
      content_type: file.content_type || ""
    }
  end

  defp readable_file?(%{deleted_at: nil, project_id: project_id} = file, profile, user)
       when is_binary(project_id) do
    Platform.Social.OrgFiles.in_org?(file, profile.org_id) and
      user
      |> Platform.Access.Scope.for_user()
      |> Platform.Access.check("files.read", {:project, project_id})
      |> Kernel.==(:ok)
  end

  defp readable_file?(_file, _profile, _user), do: false

  defp account_label(%Account{platform: platform, handle: handle}) do
    label = Approvals.platform_label(platform)
    if is_binary(handle) and handle not in ["", label], do: "#{label} #{handle}", else: label
  end

  @impl true
  def render(assigns) do
    ~H"""
    <article
      id={"queue-draft-card-#{@post.id}"}
      data-role="queue-draft"
      data-post-id={@post.id}
      data-platform={@account.platform}
      class="space-y-3 rounded-2xl border border-edge bg-base-100 p-4"
    >
      <header class="flex flex-wrap items-baseline gap-x-2 text-sm">
        <span data-role="draft-account" class="font-medium">{account_label(@account)}</span>
        <span :if={@show_brand?} data-role="draft-brand" class="text-base-content">
          · {@profile.name}
        </span>
        <span :if={@clip_title} data-role="draft-from-clip" class="text-base-content">
          · From clip: {@clip_title}
        </span>
      </header>

      <%= if @can_edit? do %>
        <form
          id={"queue-draft-form-#{@post.id}"}
          phx-change="draft_change"
          phx-submit="draft_submit"
          phx-target={@myself}
          class="space-y-3"
        >
          <label class="block text-sm" for={"queue-draft-body-#{@post.id}"}>
            Caption <textarea
              id={"queue-draft-body-#{@post.id}"}
              name="body"
              rows="4"
              data-role="draft-body"
              class="textarea textarea-bordered mt-1 w-full"
            >{@form["body"]}</textarea>
          </label>

          <label
            :if={@account.platform == "youtube"}
            class="block text-sm"
            for={"queue-draft-title-#{@post.id}"}
          >
            Title (sent to YouTube)
            <input
              type="text"
              id={"queue-draft-title-#{@post.id}"}
              name="title"
              value={@form["title"]}
              data-role="draft-title"
              class="input input-bordered mt-1 min-h-11 w-full"
            />
          </label>

          <.draft_media media={@media} hidden={@media_hidden} />

          <label class="block text-sm" for={"queue-draft-at-#{@post.id}"}>
            <span data-role="draft-time-label">
              {if @form["at"] == "", do: "Choose a publish time", else: "Publish time"}
            </span>
            <span data-role="draft-time-zone" class="text-base-content">
              ({SocialCalendarClock.label(@tz)})
            </span>
            <input
              type="datetime-local"
              id={"queue-draft-at-#{@post.id}"}
              name="at"
              value={@form["at"]}
              data-role="draft-time"
              class="input input-bordered mt-1 min-h-11 w-full"
            />
          </label>

          <.draft_messages lines={@lines} notice={@notice} />

          <div class="flex flex-wrap gap-2">
            <button
              type="submit"
              name="intent"
              value="save"
              data-role="draft-save"
              class="btn btn-ghost min-h-11"
            >
              Save draft
            </button>
            <button
              type="submit"
              name="intent"
              value="submit"
              data-role="draft-send"
              class="btn btn-primary min-h-11"
            >
              Send for review
            </button>
          </div>
        </form>
      <% else %>
        <div :if={is_nil(@presentation)} class="space-y-3 text-sm">
          <p data-role="draft-status">Draft</p>
          <p data-role="draft-read-only" class="text-subtle">
            Only an approver for this account can edit or send this draft.
          </p>
        </div>
        <div :if={@presentation} class="space-y-3 text-sm">
          <p data-role="draft-body" class="whitespace-pre-wrap">
            {if @form["body"] == "", do: "No caption yet.", else: @form["body"]}
          </p>
          <p :if={@account.platform == "youtube"} data-role="draft-title">
            <span>Title (sent to YouTube)</span>: {if @form["title"] == "",
              do: "Not set",
              else: @form["title"]}
          </p>
          <.draft_media media={@media} hidden={@media_hidden} />
          <p data-role="draft-time">
            {if @form["at"] == "",
              do: "No publish time yet",
              else: "#{@form["at"]} (#{SocialCalendarClock.label(@tz)})"}
          </p>
          <p data-role="draft-read-only" class="text-subtle">
            Only an approver for this account can edit or send this draft.
          </p>
        </div>
      <% end %>
    </article>
    """
  end

  attr :media, :list, required: true
  attr :hidden, :integer, default: 0

  defp draft_media(assigns) do
    ~H"""
    <p :if={@hidden > 0} data-role="draft-media-unavailable" class="text-sm text-base-content">
      Media unavailable
    </p>
    <ul :if={@media != []} data-role="draft-media" class="space-y-2">
      <li :for={m <- @media} class="text-sm">
        <video
          :if={String.starts_with?(m.content_type, "video/")}
          src={"/files/blob/#{m.id}"}
          controls
          preload="metadata"
          class="max-h-60 rounded-lg"
        >
        </video>
        <img
          :if={String.starts_with?(m.content_type, "image/")}
          src={"/files/blob/#{m.id}"}
          alt={m.name}
          class="max-h-60 rounded-lg"
        />
        <span class="text-base-content">{m.name}</span>
      </li>
    </ul>
    """
  end

  attr :lines, :list, required: true
  attr :notice, :string, default: nil

  defp draft_messages(assigns) do
    ~H"""
    <p :if={@notice} role="status" data-role="draft-notice" class="text-sm font-medium">
      {@notice}
    </p>
    <ul :if={@lines != []} role="alert" data-role="draft-lines" class="space-y-1 text-sm text-error">
      <li :for={line <- @lines} data-role="draft-line">{line}</li>
    </ul>
    """
  end
end
