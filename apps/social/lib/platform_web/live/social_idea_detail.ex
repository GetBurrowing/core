defmodule PlatformWeb.SocialIdeaDetail do
  @moduledoc """
  One idea, opened from the Ideas board (Social authoring 7/11, task
  01a16c50-ea67): a right-hand drawer from sm up, a full screen below.
  Rendered by `PlatformWeb.SocialIdeasTab.overlay/1` from the detail
  `Platform.Social.IdeaBoard.detail/2` reads; every event here is the tab's.

    * The versions side by side: the shared Needs-you card
      (`PlatformWeb.SocialIdeaCard`, with its own DOM prefix so it never
      clashes with the Queue's copy), so a version's preview, flags, status
      and actions are the Queue's own.
    * Platform options per version, only those
      `Platform.Social.PlatformOptions` lists for the platform.
    * The notes thread (humans post here; agents use `social_idea_note_add`).
    * The change log, every row naming who did it and whether that was an
      agent, a human or the system, with an edit's before and after.
    * Where the idea came from, as a link.

  A viewer who is not an approver of the idea's profile gets no write
  controls at all (not disabled ones).
  """

  use PlatformWeb, :html

  import PlatformWeb.SocialHelpers, only: [platform_label: 1]

  alias Platform.Social.PlatformOptions
  alias PlatformWeb.SocialIdeaCard

  @source_labels %{
    "chat" => {"From chat", "hero-chat-bubble-left-right-mini"},
    "clip" => {"From a clip", "hero-film-mini"},
    "task" => {"From a task", "hero-check-circle-mini"},
    "meeting" => {"From a meeting", "hero-video-camera-mini"},
    "agent" => {"Agent idea", "hero-sparkles-mini"},
    "human" => {"Your idea", "hero-user-mini"},
    "url" => {"From a link", "hero-link-mini"}
  }

  @stage_labels %{
    "inbox" => "Inbox",
    "drafting" => "Drafting",
    "in_review" => "In review",
    "scheduled" => "Scheduled",
    "live" => "Live",
    "failed" => "Failed"
  }

  @verbs %{
    "created" => "drafted",
    "edited" => "edited",
    "submitted" => "submitted",
    "approved" => "approved",
    "rejected" => "rejected",
    "revision_requested" => "asked to revise",
    "published" => "published",
    "failed" => "could not publish",
    "refused" => "held back"
  }

  @source_link_labels %{
    "clip" => "Open in Clips",
    "task" => "Open the task",
    "meeting" => "Open the meeting",
    "message" => "Open the message",
    "url" => "Open the link"
  }

  @doc "The source chip of an idea: `%{label, icon}`."
  def source_chip(%{source_kind: kind}) do
    {label, icon} = Map.get(@source_labels, kind, {"Idea", "hero-light-bulb-mini"})
    %{label: label, icon: icon}
  end

  attr :idea_id, :string, required: true
  attr :composer?, :boolean, default: false
  attr :agent_name, :string, default: nil
  attr :size, :string, default: "btn-sm"

  @doc """
  "Draft it": opens the composer (6/11) on this idea when it is on. "Ask
  <agent> to draft" mentions the drafting agent instead (the only offer
  while the composer is off). With no drafting agent it says so, and
  points to Settings.
  """
  def draft_button(assigns) do
    ~H"""
    <button
      :if={@composer?}
      type="button"
      phx-click="ideas_compose"
      phx-value-id={@idea_id}
      data-role="idea-draft-it"
      data-mode="composer"
      class={["btn btn-primary", @size]}
    >
      <.icon name="hero-pencil-square-mini" class="size-4" /> Draft it
    </button>
    <button
      :if={@agent_name}
      type="button"
      phx-click="ideas_ask_draft"
      phx-value-id={@idea_id}
      phx-disable-with="Asking"
      data-role="idea-draft-it"
      data-mode="agent"
      class={["btn", if(@composer?, do: "btn-ghost", else: "btn-primary"), @size]}
    >
      <.icon name="hero-sparkles-mini" class="size-4" /> Ask {@agent_name} to draft
    </button>
    <span
      :if={!@composer? and is_nil(@agent_name)}
      data-role="idea-draft-no-agent"
      class="text-xs text-base-content"
    >
      No drafting agent yet. Choose one in Settings.
    </span>
    """
  end

  attr :detail, :map, required: true
  attr :user, :any, required: true
  attr :rev, :integer, default: 0
  attr :notice, :any, default: nil
  attr :note_form, :any, required: true
  attr :options_errors, :map, default: %{}
  attr :composer?, :boolean, default: false

  @doc "The drawer (sm up) or full screen (phone) for one idea."
  def drawer(assigns) do
    d = assigns.detail

    assigns =
      assign(assigns,
        idea: d.idea,
        source: source_chip(d.idea),
        stage: Map.get(@stage_labels, d.stage, "Inbox"),
        tz: SocialIdeaCard.profile_tz(d.profile),
        group: %{key: d.idea.id, idea: d.idea, posts: d.posts},
        can_archive?: d.can_write? and not d.has_published? and is_nil(d.idea.archived_at),
        can_draft?: d.can_write? and d.posts == [] and is_nil(d.idea.archived_at)
      )

    ~H"""
    <div
      class="fixed inset-0 z-40 flex justify-end"
      role="dialog"
      aria-modal="true"
      aria-labelledby="idea-detail-title"
      phx-window-keydown="ideas_close"
      phx-key="escape"
      data-role="idea-detail"
      data-idea-id={@idea.id}
      data-can-write={to_string(@detail.can_write?)}
    >
      <button
        type="button"
        class="absolute inset-0 hidden bg-base-content/30 sm:block"
        phx-click="ideas_close"
        aria-label="Close"
      >
      </button>
      <div class="relative flex h-full w-full flex-col overflow-y-auto bg-base-100 text-base-content sm:max-w-[min(100%,64rem)] sm:border-l sm:border-base-300 sm:shadow-xl">
        <header class="sticky top-0 z-10 space-y-2 border-b border-base-300 bg-base-100 px-4 py-3 sm:px-6">
          <div class="flex items-center gap-2">
            <button
              type="button"
              class="btn btn-ghost btn-sm btn-square"
              phx-click="ideas_close"
              aria-label="Close"
              data-role="idea-detail-close"
            >
              <.icon name="hero-x-mark" class="size-5" />
            </button>
            <span
              data-role="idea-detail-source"
              data-source={@idea.source_kind}
              class="inline-flex items-center gap-1 rounded-full border border-base-300 bg-base-200 px-2 py-0.5 text-xs font-medium"
            >
              <.icon name={@source.icon} class="size-3.5" /> {@source.label}
            </span>
            <span class="text-xs text-base-content" data-role="idea-detail-brand">
              {@detail.profile.name}
            </span>
            <span class="badge badge-ghost badge-sm ml-auto font-medium" data-role="idea-detail-stage">
              {@stage}
            </span>
          </div>
          <h2
            id="idea-detail-title"
            class="text-xl font-semibold leading-snug"
            data-role="idea-detail-title"
          >
            {@idea.title}
          </h2>
          <div class="flex flex-wrap items-center gap-2">
            <.source_link source={@detail.source} />
            <span
              :if={@detail.agent_name}
              class="text-xs text-base-content"
              data-role="idea-detail-agent"
            >
              <.icon name="hero-sparkles-micro" class="size-3.5" /> {@detail.agent_name}
            </span>
            <span
              :if={@idea.archived_at}
              class="badge badge-ghost badge-sm"
              data-role="idea-detail-archived"
            >
              Archived
            </span>
            <div :if={@can_draft? or @can_archive?} class="ml-auto flex flex-wrap items-center gap-2">
              <.draft_button
                :if={@can_draft?}
                idea_id={@idea.id}
                composer?={@composer?}
                agent_name={@detail.agent_name}
              />
              <button
                :if={@can_archive?}
                type="button"
                phx-click="ideas_archive"
                phx-value-id={@idea.id}
                data-confirm="Archive this idea? Its posts are kept."
                data-role="idea-archive"
                class="btn btn-ghost btn-sm"
              >
                <.icon name="hero-archive-box-mini" class="size-4" /> Archive
              </button>
            </div>
          </div>
          <p
            :if={!@detail.can_write?}
            data-role="idea-detail-read-only"
            class="text-xs text-base-content"
          >
            You can read this idea. Approvers of {@detail.profile.name} can change it.
          </p>
          <p
            :if={@notice}
            role="status"
            data-role="idea-detail-notice"
            data-tone={elem(@notice, 1)}
            class={[
              "rounded-lg px-3 py-2 text-sm",
              if(elem(@notice, 1) == :warning, do: "bg-warning/15", else: "bg-base-200")
            ]}
          >
            {elem(@notice, 0)}
          </p>
        </header>

        <div class="space-y-8 px-4 py-4 max-sm:pb-32 sm:px-6">
          <section :if={@idea.brief} aria-labelledby="idea-brief-title" class="space-y-1">
            <h3 id="idea-brief-title" class="text-sm font-semibold">Brief</h3>
            <.text_block role="idea-detail-brief" text={@idea.brief} />
          </section>

          <section aria-labelledby="idea-versions-title" class="space-y-3" data-role="idea-versions">
            <h3 id="idea-versions-title" class="text-sm font-semibold">Versions</h3>
            <p
              :if={@detail.posts == []}
              data-role="idea-versions-empty"
              class="rounded-xl border border-dashed border-base-300 px-3 py-4 text-sm text-base-content"
            >
              No versions yet. They appear here, one per account, as they are drafted.
            </p>
            <.live_component
              :if={@detail.posts != []}
              module={SocialIdeaCard}
              id={"idea-detail-card-" <> @idea.id}
              group={@group}
              viewer={{:user, @user.id}}
              profiles={%{@detail.profile.id => @detail.profile}}
              show_brand?={false}
              focused?={true}
              cover_controls={false}
              dom_prefix="idea-detail"
              rev={@rev}
            />
          </section>

          <section
            :if={@detail.posts != []}
            aria-labelledby="idea-options-title"
            class="space-y-3"
            data-role="idea-options"
          >
            <h3 id="idea-options-title" class="text-sm font-semibold">Platform options</h3>
            <div class="grid gap-3 md:grid-cols-2">
              <.options_form
                :for={post <- @detail.posts}
                post={post}
                account={Map.get(@detail.accounts, post.account_id)}
                can_write?={@detail.can_write?}
                errors={Map.get(@options_errors, post.id, %{})}
              />
            </div>
          </section>

          <div class="grid gap-8 lg:grid-cols-2">
            <section aria-labelledby="idea-notes-title" class="space-y-3" data-role="idea-notes">
              <h3 id="idea-notes-title" class="text-sm font-semibold">Notes</h3>
              <p
                :if={@detail.notes == []}
                data-role="idea-notes-empty"
                class="text-sm text-base-content"
              >
                No notes yet. Notes here reach the drafting agent through its idea list.
              </p>
              <ol :if={@detail.notes != []} class="space-y-2" data-role="idea-notes-list">
                <li
                  :for={row <- @detail.notes}
                  id={"idea-note-#{row.note.id}"}
                  data-role="idea-note"
                  data-author-kind={row.note.author_kind}
                  class="rounded-lg border border-base-300 px-3 py-2"
                >
                  <p class="text-xs text-base-content">
                    <span class="font-medium text-base-content" data-role="idea-note-author">
                      {row.author_name}
                    </span>
                    ({row.note.author_kind}) · {SocialIdeaCard.when_text(row.note.inserted_at, @tz)}
                  </p>
                  <.text_block role="idea-note-body" class="mt-1" text={row.note.body} />
                </li>
              </ol>
              <.form
                :if={@detail.can_write?}
                for={@note_form}
                id="idea-note-form"
                phx-submit="ideas_note_save"
                data-role="idea-note-form"
                class="space-y-2"
              >
                <.input
                  field={@note_form[:body]}
                  type="textarea"
                  label="Add a note"
                  rows="3"
                  maxlength="4000"
                  placeholder="For the team and the drafting agent"
                />
                <div class="flex justify-end">
                  <button type="submit" class="btn btn-primary btn-sm" data-role="idea-note-save">
                    Post note
                  </button>
                </div>
              </.form>
            </section>

            <section aria-labelledby="idea-log-title" class="space-y-3" data-role="idea-log">
              <h3 id="idea-log-title" class="text-sm font-semibold">Change log</h3>
              <p
                :if={@detail.events == []}
                data-role="idea-log-empty"
                class="text-sm text-base-content"
              >
                Nothing has happened to this idea's posts yet.
              </p>
              <ol :if={@detail.events != []} class="space-y-1" data-role="idea-log-list">
                <li
                  :for={row <- @detail.events}
                  id={"idea-log-#{row.event.id}"}
                  data-role="idea-log-row"
                  data-actor-kind={row.actor_kind}
                  data-action={row.event.action}
                  class="text-sm"
                >
                  <%= if edit_diff?(row.event) do %>
                    <details class="group">
                      <summary class="cursor-pointer list-none rounded px-1 py-0.5 hover:bg-base-200">
                        <.log_line row={row} tz={@tz} />
                        <span class="text-xs text-subtle group-open:hidden">
                          · show change
                        </span>
                      </summary>
                      <div class="mt-1 grid gap-2 sm:grid-cols-2" data-role="idea-log-diff">
                        <div class="rounded border border-base-300 p-2">
                          <p class="text-xs font-medium text-base-content">Before</p>
                          <.text_block role="idea-log-before" text={row.event.body_before} />
                        </div>
                        <div class="rounded border border-base-300 p-2">
                          <p class="text-xs font-medium text-base-content">After</p>
                          <.text_block role="idea-log-after" text={row.event.body_after} />
                        </div>
                      </div>
                    </details>
                  <% else %>
                    <p class="px-1 py-0.5"><.log_line row={row} tz={@tz} /></p>
                  <% end %>
                </li>
              </ol>
            </section>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :role, :string, required: true
  attr :text, :string, default: nil
  attr :class, :string, default: nil

  # Multi-line text with its own line breaks, and no template whitespace.
  defp text_block(assigns) do
    ~H"""
    <p class={["whitespace-pre-line text-sm", @class]} data-role={@role}>{@text}</p>
    """
  end

  defp edit_diff?(%{action: "edited", body_before: b, body_after: a}),
    do: is_binary(b) or is_binary(a)

  defp edit_diff?(_event), do: false

  attr :row, :map, required: true
  attr :tz, :string, required: true

  # "Octavius (agent) edited LinkedIn · 14:02", then the note.
  defp log_line(assigns) do
    ~H"""
    <span data-role="idea-log-text">
      <span class="font-medium">{@row.actor_name}</span>
      <span class="text-base-content" data-role="idea-log-kind">({@row.actor_kind})</span>
      {Map.get(verbs(), @row.event.action, @row.event.action)} {(@row.platform &&
                                                                   platform_label(@row.platform)) ||
        "a post"}
      <span class="text-base-content">
        · {SocialIdeaCard.when_text(@row.at, @tz)}
      </span>
    </span>
    <span
      :if={@row.event.note}
      class="block pl-1 text-xs text-base-content"
      data-role="idea-log-note"
    >
      {@row.event.note}
    </span>
    """
  end

  defp verbs, do: @verbs

  attr :source, :map, default: nil

  defp source_link(%{source: nil} = assigns), do: ~H""

  defp source_link(%{source: %{tab: _}} = assigns) do
    assigns = assign(assigns, :label, Map.fetch!(source_link_labels(), assigns.source.kind))

    ~H"""
    <button
      type="button"
      phx-click="select_tab"
      phx-value-tab={@source.tab}
      data-role="idea-detail-source-link"
      data-kind={@source.kind}
      class="link text-sm"
    >
      {@label}
    </button>
    """
  end

  defp source_link(assigns) do
    assigns = assign(assigns, :label, Map.fetch!(source_link_labels(), assigns.source.kind))

    ~H"""
    <a
      href={@source.href}
      target={if @source.kind == "url", do: "_blank"}
      rel={if @source.kind == "url", do: "noopener noreferrer"}
      data-role="idea-detail-source-link"
      data-kind={@source.kind}
      class="link text-sm"
    >
      {@label}
      <.icon
        :if={@source.kind == "url"}
        name="hero-arrow-top-right-on-square-mini"
        class="size-3.5"
      />
    </a>
    """
  end

  defp source_link_labels, do: @source_link_labels

  attr :post, :map, required: true
  attr :account, :map, default: nil
  attr :can_write?, :boolean, default: false
  attr :errors, :map, default: %{}

  # One version's platform options. Editable by an approver while the
  # version is draft or waiting for approval; read-only otherwise.
  defp options_form(assigns) do
    platform = assigns.account && assigns.account.platform
    fields = PlatformOptions.fields(platform)
    values = PlatformOptions.for_platform(assigns.post.platform_options, platform)

    assigns =
      assign(assigns,
        platform: platform,
        fields: fields,
        values: values,
        editable?: assigns.can_write? and assigns.post.status in ~w(draft needs_approval),
        cover: cover_line(assigns.post, platform)
      )

    ~H"""
    <div
      class="space-y-2 rounded-xl border border-base-300 p-3"
      data-role="idea-options-version"
      data-post-id={@post.id}
      data-platform={@platform}
    >
      <p class="flex items-center gap-1.5 text-sm font-medium">
        <PlatformWeb.SocialPreview.glyph :if={@platform} platform={@platform} class="size-4" />
        {platform_label(@platform)}
        <span :if={@account && @account.handle} class="font-normal text-base-content">
          {@account.handle}
        </span>
      </p>

      <p :if={@fields == []} class="text-sm text-base-content" data-role="idea-options-none">
        {platform_label(@platform)} takes no extra options here.
      </p>

      <form
        :if={@fields != [] and @editable?}
        id={"idea-options-#{@post.id}"}
        phx-submit="ideas_options_save"
        data-role="idea-options-form"
        class="space-y-2"
      >
        <input type="hidden" name="post_id" value={@post.id} />
        <div :for={f <- @fields} class="space-y-1">
          <label class="block text-xs font-medium" for={"idea-option-#{@post.id}-#{f.key}"}>
            {f.label}
          </label>
          <textarea
            :if={f.key != "title"}
            id={"idea-option-#{@post.id}-#{f.key}"}
            name={"options[#{f.key}]"}
            rows="2"
            maxlength={f.max}
            data-role="idea-option-input"
            data-key={f.key}
            class="textarea textarea-sm w-full"
          >{Map.get(@values, f.key, "")}</textarea>
          <input
            :if={f.key == "title"}
            id={"idea-option-#{@post.id}-#{f.key}"}
            type="text"
            name={"options[#{f.key}]"}
            value={Map.get(@values, f.key, "")}
            maxlength={f.max}
            data-role="idea-option-input"
            data-key={f.key}
            class="input input-sm w-full"
          />
          <p
            :if={@errors[f.key]}
            class="text-xs text-error"
            data-role="idea-option-error"
            data-key={f.key}
          >
            {@errors[f.key]}
          </p>
        </div>
        <p :if={@errors["_"]} class="text-xs text-error" data-role="idea-option-error">
          {@errors["_"]}
        </p>
        <div class="flex justify-end">
          <button type="submit" class="btn btn-outline btn-sm" data-role="idea-options-save">
            Save options
          </button>
        </div>
      </form>

      <dl
        :if={@fields != [] and not @editable?}
        class="space-y-1 text-sm"
        data-role="idea-options-read"
      >
        <div :for={f <- @fields} class="flex gap-2">
          <dt class="shrink-0 text-base-content">{f.label}:</dt>
          <dd data-role="idea-option-value" data-key={f.key}>
            {Map.get(@values, f.key) || "Not set"}
          </dd>
        </div>
      </dl>

      <p :if={@cover} class="text-xs text-base-content" data-role="idea-options-cover">
        {@cover}
      </p>
    </div>
    """
  end

  # The cover is the Needs-you picker's (#1324): named here, changed there.
  defp cover_line(post, platform) when platform in ~w(instagram youtube) do
    if video?(post) do
      label =
        cond do
          post.cover_file_id ->
            "Cover: uploaded image"

          is_integer(post.cover_offset_ms) ->
            "Cover: frame " <> PlatformWeb.SocialCardComponent.clock_ms(post.cover_offset_ms)

          true ->
            "Cover: first frame"
        end

      if post.status == "needs_approval", do: label <> " · change it in Needs you", else: label
    end
  end

  defp cover_line(_post, _platform), do: nil

  defp video?(%{media_file_ids: [id | _]}) do
    case Platform.Files.get_file(id) do
      %{content_type: "video/" <> _} -> true
      _ -> false
    end
  end

  defp video?(_post), do: false
end
