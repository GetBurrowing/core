defmodule PlatformWeb.InboxLive.BriefingComponent do
  @moduledoc """
  The daily briefing's detail in the Inbox's detail pane (task 01a15ee1
  stage 5), mounted by `PlatformWeb.InboxLive` on `/inbox/briefing/:date`.

  ## What it renders, and from where

  `Platform.Memory.Insights.Briefings.view/2` is the only read: the header,
  the progress line, then "Needs your call", "For your information" and
  "Done today", in that order, each hidden when empty. Every word comes from
  `PlatformWeb.InboxLive.BriefingCopy`; this module paints.

  ## Every button goes through Briefings

  An item's buttons call `Briefings.handle/5` (answer, reroute, apply, edit
  first, file, got it, dismiss, not useful, revert, delete, move) and a
  receipt's way back calls `Briefings.undo/3`. Nothing here calls
  `Platform.Memory.Insights.Actions` directly: those functions re-check
  authority underneath, and `handle/5` resolves the insight from the
  briefing row's own `items[key]`, never from anything the client sends.
  The Scope is built from the user row on EVERY click (`scope/1`), never
  kept from mount, so a role change takes effect on the next click.

  ## Errors stay on the card

  `{:error, reason}` leaves the item where it is, with
  `BriefingCopy.error_text/2` under its buttons ("Couldn't file the task.
  Try again."). A blank answer is not an error: the field's placeholder
  turns into "Type an answer first".

  ## The toast is InboxLive's

  A success sends `{:briefing_toast, toast}` to the parent LiveView (a
  LiveComponent runs in its parent's process), which raises its existing
  act-then-confirm toast for 5 seconds, paused while hovered or focused.
  The toast's Undo is `Briefings.undo/3` again, from the parent, which then
  `send_update/2`s this component with `reload: true`. Revert and Delete
  toasts carry no Undo (they have no inverse). The same inverse stays on
  the receipt for the rest of the day.
  """

  use PlatformWeb, :live_component

  alias Platform.Access.Scope
  alias Platform.Accounts
  alias Platform.Memory.Briefing
  alias Platform.Memory.Insights.Briefings
  alias Platform.Memory.Insights.Routing
  alias Platform.Memory.Insights.Settings
  alias Platform.Memory.Insights.Tier
  alias Platform.Tasks
  alias PlatformWeb.InboxLive.BriefingCopy
  alias PlatformWeb.OrgMemoryLive.InsightPreview

  @btn "btn btn-sm min-h-11 focus-visible-ring lg:min-h-0"
  @btn_primary @btn <> " btn-primary"
  @btn_secondary @btn <> " border-edge bg-base-300 text-base-content"
  @btn_ghost @btn <> " btn-ghost text-subtle lg:hover:text-base-content"
  # `placeholder:text-faint` (task 01a15ee1 stage 6): the inherited placeholder
  # (base-content at 50%) measured 3.93:1 on base-200 in light; --faint is
  # main's placeholder tier, 4.89:1 there.
  @field "w-full rounded-lg border border-edge bg-base-200 px-3 py-2 text-sm text-base-content placeholder:text-faint"
  # Links inside a sentence (a receipt's "Open task", the settings note):
  # inline text, under WCAG 2.5.8's inline exception, so no 44px box that
  # would pull the line apart on the phone.
  @link "focus-visible-ring rounded font-semibold text-interactive"

  # ── Lifecycle ─────────────────────────────────────────────────────────

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:open_form, %{})
     |> assign(:errors, %{})
     |> assign(:blank, MapSet.new())
     |> assign(:picked, %{})
     |> assign(:titles, %{})
     |> assign(:view, nil)}
  end

  @impl true
  def update(%{reload: true}, socket), do: {:ok, load(socket)}

  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(Map.take(assigns, [:id, :briefing_id, :user_id, :today, :refresh]))
     |> load()}
  end

  defp load(socket) do
    %{briefing_id: briefing_id, user_id: user_id} = socket.assigns

    case Briefings.get_for_user(briefing_id, user_id) do
      %Briefing{} = briefing ->
        user = Accounts.get_user(user_id)
        scope = Scope.for_user(user)
        view = Briefings.view(briefing, scope)

        socket
        |> assign(:briefing, briefing)
        |> assign(:view, view)
        |> assign(:header, BriefingCopy.header(view.date, socket.assigns.today))
        |> assign(:progress, BriefingCopy.progress(view.counts))
        |> assign(:projects, projects(user, view))
        |> assign(:people, people(view))
        |> assign(:settings, Settings.get())
        |> assign(:admin?, Platform.Access.authorize_install(scope) == :ok)
        |> prune_ui(view)

      nil ->
        assign(socket, :view, nil)
    end
  end

  # Drop form/error state for items that left the section it was opened in.
  defp prune_ui(socket, view) do
    open = for i <- view.needs_call ++ view.fyi, into: MapSet.new(), do: i.key
    done = for i <- view.done, into: MapSet.new(), do: i.key
    keep = fn key, form -> if form == :move, do: key in done, else: key in open end

    socket
    |> update(:open_form, &Map.filter(&1, fn {k, f} -> keep.(k, f) end))
    |> update(:errors, &Map.filter(&1, fn {k, _} -> k in open or k in done end))
    |> update(:blank, &MapSet.filter(&1, fn k -> k in open end))
    |> update(:titles, &Map.filter(&1, fn {k, _} -> k in open end))
  end

  # The projects a picker offers: the live projects of each task's org the
  # viewer can see, by org. Only built for orgs a picker is shown for.
  defp projects(user, view) do
    orgs =
      for %{kind: :task, insight: %{} = insight} = item <- view.needs_call ++ view.done,
          is_nil(item.project) or :move in item.actions,
          uniq: true,
          do: Tier.org_id(insight)

    Map.new(orgs, fn org_id ->
      live = MapSet.new(Tasks.live_project_ids(org_id))

      visible =
        user
        |> Tasks.list_projects_for_user(org_id: org_id)
        |> Enum.filter(&(&1.id in live))
        |> Enum.map(&%{id: &1.id, name: &1.name})

      {org_id, visible}
    end)
  end

  # Who the reroute picker offers, by org: the org's internal members,
  # loaded once per load (not per render) for orgs with an open question.
  defp people(view) do
    view.needs_call
    |> Enum.filter(&match?(%{kind: :question, insight: %{}}, &1))
    |> Enum.map(&Tier.org_id(&1.insight))
    |> Enum.uniq()
    |> Map.new(&{&1, Routing.candidates(&1)})
  end

  # Rebuilt per click from the user row: never the Scope built at mount.
  defp scope(socket) do
    case Accounts.get_user(socket.assigns.user_id) do
      nil -> Scope.for_user(nil)
      user -> Scope.for_user(user)
    end
  end

  # ── Events ────────────────────────────────────────────────────────────

  @impl true
  def handle_event("open", %{"key" => key, "form" => form}, socket)
      when form in ~w(reroute edit reject move) do
    {:noreply,
     socket
     |> update(:open_form, &Map.put(&1, key, String.to_existing_atom(form)))
     |> update(:errors, &Map.delete(&1, key))}
  end

  def handle_event("close", %{"key" => key}, socket),
    do: {:noreply, update(socket, :open_form, &Map.delete(&1, key))}

  def handle_event("pick", %{"key" => key} = params, socket) do
    picked =
      case params["project_id"] do
        id when is_binary(id) and id != "" -> Map.put(socket.assigns.picked, key, id)
        _ -> Map.delete(socket.assigns.picked, key)
      end

    # Keep what the person typed in Title (stage 6): the picker's re-render
    # would otherwise paint the insight's default title back over it.
    titles =
      case params["title"] do
        title when is_binary(title) -> Map.put(socket.assigns.titles, key, title)
        _ -> socket.assigns.titles
      end

    {:noreply,
     socket
     |> assign(:picked, picked)
     |> assign(:titles, titles)
     |> update(:errors, &Map.delete(&1, key))}
  end

  def handle_event("act", %{"key" => key, "verb" => verb} = params, socket) do
    if verb == "answer" and blank?(params["answer"]) do
      {:noreply, update(socket, :blank, &MapSet.put(&1, key))}
    else
      act(socket, key, verb, action_params(params))
    end
  end

  def handle_event("undo", %{"key" => key}, socket) do
    case Briefings.undo(socket.assigns.briefing, key, scope(socket)) do
      {:ok, _briefing} ->
        {:noreply, socket |> update(:errors, &Map.delete(&1, key)) |> load()}

      {:error, reason} ->
        {:noreply, put_error(socket, key, BriefingCopy.error_text(:undo, reason))}
    end
  end

  defp act(socket, key, verb, params) do
    before = find(socket.assigns.view, key)

    case Briefings.handle(socket.assigns.briefing, key, verb, scope(socket), params) do
      {:ok, _briefing} ->
        socket =
          socket
          |> update(:errors, &Map.delete(&1, key))
          |> update(:open_form, &Map.delete(&1, key))
          |> update(:picked, &Map.delete(&1, key))
          |> update(:titles, &Map.delete(&1, key))
          |> load()

        send(self(), {:briefing_toast, toast(socket, key, verb, before)})
        {:noreply, socket}

      {:error, :blank} when verb == "answer" ->
        {:noreply, update(socket, :blank, &MapSet.put(&1, key))}

      {:error, reason} ->
        {:noreply, put_error(socket, key, BriefingCopy.error_text(verb, reason))}
    end
  end

  defp put_error(socket, key, text), do: update(socket, :errors, &Map.put(&1, key, text))

  defp toast(socket, key, verb, before) do
    after_item = find(socket.assigns.view, key)
    receipt = after_item && after_item.receipt

    ctx = %{
      kind: before && before.kind,
      path: receipt && receipt.detail[:path],
      project_name: after_item && after_item.project && after_item.project.name,
      name: receipt && receipt.detail[:name],
      undo?: receipt != nil and receipt.undo != nil
    }

    copy = BriefingCopy.toast(verb, ctx)

    %{
      message: copy.message,
      undo?: copy.undo? and ctx.undo?,
      key: key,
      briefing_id: socket.assigns.briefing_id,
      component_id: socket.assigns.id
    }
  end

  defp find(nil, _key), do: nil

  defp find(view, key),
    do: Enum.find(view.needs_call ++ view.fyi ++ view.done, &(&1.key == key))

  # Only what `Briefings.handle/5` reads; `key` and `verb` are not params.
  defp action_params(params) do
    params
    |> Map.take(["answer", "addressee", "body", "project_id", "title", "reason"])
    |> put_hunks(params["hunks"])
  end

  # The edit form's hunks arrive as `%{"0" => %{"old" => _, "new" => _}}`.
  defp put_hunks(map, %{} = hunks) do
    list =
      hunks
      |> Enum.sort_by(fn {index, _} -> index |> Integer.parse() |> elem(0) end)
      |> Enum.flat_map(fn
        {_index, %{"old" => old, "new" => new}} -> [%{"old" => old, "new" => new}]
        _ -> []
      end)

    Map.put(map, "hunks", list)
  rescue
    _ -> map
  end

  defp put_hunks(map, _hunks), do: map

  defp blank?(text), do: not is_binary(text) or String.trim(text) == ""

  # ── Render ────────────────────────────────────────────────────────────

  @impl true
  def render(%{view: nil} = assigns) do
    ~H"""
    <div id={@id} class="py-10 text-center text-sm text-subtle" data-role="briefing-detail-missing">
      There's no briefing for this day.
    </div>
    """
  end

  def render(assigns) do
    assigns = assign(assigns, :ui, ui(assigns))

    ~H"""
    <div id={@id} data-role="briefing-detail" data-briefing-id={@briefing_id}>
      <header>
        <h2 class="text-2xl font-bold text-base-content" data-role="briefing-title">
          {@header.title}
        </h2>
        <p class="mt-1 text-sm text-subtle" data-role="briefing-meta">{@header.meta}</p>
      </header>

      <div class="mt-4">
        <progress
          class="progress progress-success block h-1.5 w-full bg-base-300"
          value={@progress.handled}
          max={max(@progress.total, 1)}
          aria-hidden="true"
        >
        </progress>
        <p class="mt-1.5 text-xs text-subtle" data-role="briefing-progress">{@progress.label}</p>
      </div>

      <.section
        :if={@view.needs_call != []}
        id={@id <> "-needs-call"}
        section={:needs_call}
        items={@view.needs_call}
        ui={@ui}
      />
      <.section
        :if={@view.fyi != []}
        id={@id <> "-fyi"}
        section={:fyi}
        items={@view.fyi}
        ui={@ui}
      />
      <.section
        :if={@view.done != []}
        id={@id <> "-done"}
        section={:done}
        items={@view.done}
        ui={@ui}
      />

      <p
        :if={@view.counts.open == 0}
        class="flex items-center justify-center gap-2 px-5 py-12 text-center text-sm text-subtle"
        data-role="briefing-all-caught-up"
      >
        <span class="hero-sun size-5 shrink-0" aria-hidden="true"></span>
        {BriefingCopy.all_caught_up()}
      </p>

      <.settings_note settings={@settings} admin?={@admin?} />
    </div>
    """
  end

  defp ui(assigns) do
    Map.take(assigns, [
      :myself,
      :open_form,
      :errors,
      :blank,
      :picked,
      :titles,
      :projects,
      :people
    ])
  end

  attr(:id, :string, required: true)
  attr(:section, :atom, required: true)
  attr(:items, :list, required: true)

  attr(:ui, :map,
    required: true,
    doc: "myself, open_form, errors, blank, picked, titles, projects, people"
  )

  defp section(assigns) do
    ~H"""
    <section
      id={@id}
      aria-labelledby={@id <> "-heading"}
      data-role="briefing-section"
      data-section={@section}
    >
      <h3
        id={@id <> "-heading"}
        class="mb-2 mt-6 text-xs font-bold uppercase tracking-wider text-subtle"
        data-role="briefing-section-heading"
      >
        {BriefingCopy.section_heading(@section, length(@items))}
      </h3>
      <ul role="list" class="space-y-3">
        <li :for={item <- @items}>
          <.done_card :if={@section == :done} item={item} ui={@ui} />
          <.open_card :if={@section != :done} item={item} ui={@ui} />
        </li>
      </ul>
    </section>
    """
  end

  # ── Open cards ────────────────────────────────────────────────────────

  defp open_card(assigns) do
    {title, body} = BriefingCopy.title_and_body(assigns.item.insight)
    form = Map.get(assigns.ui.open_form, assigns.item.key)

    assigns =
      assigns
      |> assign(:title, title)
      |> assign(:body, body)
      |> assign(:form, form)
      |> assign(:tag, BriefingCopy.kind_tag(assigns.item.kind))
      |> assign(:error, Map.get(assigns.ui.errors, assigns.item.key))
      |> assign(:k, assigns.item.key)

    ~H"""
    <article
      id={"briefing-item-" <> @k}
      class="rounded-xl border border-edge bg-base-100 px-4 py-3.5"
      data-role="briefing-card"
      data-key={@k}
      data-kind={@item.kind}
      data-section={@item.section}
    >
      <.kind_tag tag={@tag} />
      <h4 class="text-base font-semibold text-base-content" data-role="briefing-card-title">
        {@title}
      </h4>
      <p :if={@body} class="mt-1 text-sm text-base-content">{@body}</p>

      <.body_for item={@item} k={@k} form={@form} ui={@ui} />

      <.why item={@item} />

      <div class="mt-3 flex flex-wrap items-center gap-2" data-role="briefing-card-actions">
        <.primary_actions item={@item} k={@k} form={@form} ui={@ui} />
        <div class="ml-auto flex flex-wrap gap-1">
          <button
            :if={:dismiss in @item.actions and @item.may_handle?}
            type="button"
            class={btn_ghost()}
            phx-click="act"
            phx-value-key={@k}
            phx-value-verb="dismiss"
            phx-target={@ui.myself}
            data-role="briefing-dismiss"
          >
            Dismiss
          </button>
          <button
            :if={:not_useful in @item.actions and @item.may_handle?}
            type="button"
            class={btn_ghost()}
            phx-click="open"
            phx-value-key={@k}
            phx-value-form="reject"
            phx-target={@ui.myself}
            data-role="briefing-not-useful"
          >
            Not useful
          </button>
        </div>
      </div>

      <form
        :if={@form == :reject}
        id={"briefing-reject-" <> @k}
        phx-submit="act"
        phx-target={@ui.myself}
        class="mt-3"
        data-role="briefing-reject-form"
      >
        <input type="hidden" name="key" value={@k} />
        <input type="hidden" name="verb" value="not_useful" />
        <label class="mb-1 block text-xs text-subtle" for={"briefing-reason-" <> @k}>
          What made this not useful? (teaches dreaming)
        </label>
        <textarea
          id={"briefing-reason-" <> @k}
          name="reason"
          rows="2"
          class={field()}
          placeholder="e.g. too abstract, already known, wrong person"
        ></textarea>
        <div class="mt-2 flex flex-wrap gap-2">
          <button type="submit" class={btn_secondary()}>Reject</button>
          <button
            type="button"
            class={btn_ghost()}
            phx-click="close"
            phx-value-key={@k}
            phx-target={@ui.myself}
          >
            Cancel
          </button>
        </div>
      </form>

      <p
        :if={@error}
        role="alert"
        class="mt-2 flex items-center gap-1.5 text-sm text-base-content"
        data-role="briefing-card-error"
      >
        <span class="hero-exclamation-circle size-4 shrink-0 text-error" aria-hidden="true"></span>
        {@error}
      </p>
    </article>
    """
  end

  attr(:tag, :map, required: true)

  defp kind_tag(assigns) do
    ~H"""
    <div class="mb-1.5 flex items-center gap-2">
      <span
        class={[
          "rounded-md px-1.5 py-0.5 text-[11px] font-bold uppercase tracking-wide text-base-content",
          @tag.class
        ]}
        data-role="briefing-kind-tag"
      >
        {@tag.label}
      </span>
    </div>
    """
  end

  # The middle of the card, by kind.
  defp body_for(%{item: %{kind: :question}} = assigns) do
    assigns =
      assign(
        assigns,
        :placeholder,
        if(MapSet.member?(assigns.ui.blank, assigns.k),
          do: "Type an answer first",
          else: "Answer in a sentence or two"
        )
      )

    ~H"""
    <form
      :if={@item.may_handle?}
      id={"briefing-answer-" <> @k}
      phx-submit="act"
      phx-target={@ui.myself}
      class="mt-3"
      data-role="briefing-answer-form"
    >
      <input type="hidden" name="key" value={@k} />
      <input type="hidden" name="verb" value="answer" />
      <label class="mb-1 block text-xs text-subtle" for={"briefing-answer-text-" <> @k}>
        Your answer
      </label>
      <textarea
        id={"briefing-answer-text-" <> @k}
        name="answer"
        rows="2"
        class={field()}
        placeholder={@placeholder}
        data-role="briefing-answer-text"
      ></textarea>
    </form>
    <form
      :if={@form == :reroute}
      id={"briefing-reroute-" <> @k}
      phx-submit="act"
      phx-target={@ui.myself}
      class="mt-3"
      data-role="briefing-reroute-form"
    >
      <input type="hidden" name="key" value={@k} />
      <input type="hidden" name="verb" value="reroute" />
      <label class="mb-1 block text-xs text-subtle" for={"briefing-addressee-" <> @k}>
        Send it to
      </label>
      <select id={"briefing-addressee-" <> @k} name="addressee" class={[field(), "min-h-11"]}>
        <option
          :for={person <- Map.get(@ui.people, Tier.org_id(@item.insight), [])}
          value={person.id}
          selected={person.id == @item.insight.addressee_user_id}
        >
          {person.name || person.email}
        </option>
      </select>
      <div class="mt-2 flex flex-wrap gap-2">
        <button type="submit" class={btn_secondary()}>Send</button>
        <button
          type="button"
          class={btn_ghost()}
          phx-click="close"
          phx-value-key={@k}
          phx-target={@ui.myself}
        >
          Cancel
        </button>
      </div>
    </form>
    """
  end

  defp body_for(%{item: %{kind: :page_edit}} = assigns) do
    assigns =
      assigns
      |> assign(:path, Map.get(assigns.item.insight.action || %{}, "target"))
      |> assign(:hunks, InsightPreview.hunks(assigns.item.insight))

    ~H"""
    <form
      id={"briefing-edit-" <> @k}
      phx-submit="act"
      phx-target={@ui.myself}
      class="mt-3 overflow-hidden rounded-lg border border-edge font-mono text-[13px] leading-normal"
      data-role="briefing-diff"
    >
      <input type="hidden" name="key" value={@k} />
      <input type="hidden" name="verb" value="edit_apply" />
      <div class="bg-base-300 px-2.5 py-1.5 text-xs text-subtle" data-role="briefing-diff-path">
        {@path}
      </div>
      <%= for {{old, new}, index} <- Enum.with_index(@hunks) do %>
        <div
          class="whitespace-pre-wrap break-words bg-error/10 px-2.5 py-1.5 text-base-content line-through"
          data-role="briefing-diff-old"
          phx-no-format
        >{old}</div>
        <div
          :if={@form != :edit}
          class="whitespace-pre-wrap break-words bg-success/10 px-2.5 py-1.5 text-base-content"
          data-role="briefing-diff-new"
          phx-no-format
        >{new}</div>
        <div :if={@form == :edit} class="bg-success/10 p-1.5">
          <input type="hidden" name={"hunks[#{index}][old]"} value={old} />
          <textarea
            name={"hunks[#{index}][new]"}
            rows="2"
            aria-label="New text"
            class="w-full rounded border border-edge bg-base-100 px-2 py-1 font-mono text-[13px] text-base-content outline-2 outline-primary"
            data-role="briefing-diff-new-edit"
          >{new}</textarea>
        </div>
      <% end %>
    </form>
    """
  end

  defp body_for(%{item: %{kind: :task, project: nil}} = assigns) do
    org_id = Tier.org_id(assigns.item.insight)

    assigns =
      assigns
      |> assign(:options, Map.get(assigns.ui.projects, org_id, []))
      |> assign(:chosen, Map.get(assigns.ui.picked, assigns.k))
      |> assign(
        :task_title,
        Map.get_lazy(assigns.ui.titles, assigns.k, fn ->
          InsightPreview.task_title(assigns.item.insight)
        end)
      )

    ~H"""
    <form
      :if={@item.may_handle?}
      id={"briefing-file-" <> @k}
      phx-change="pick"
      phx-submit="act"
      phx-target={@ui.myself}
      class="mt-3"
      data-role="briefing-file-form"
    >
      <input type="hidden" name="key" value={@k} />
      <input type="hidden" name="verb" value="file" />
      <label class="mb-1 block text-xs text-subtle" for={"briefing-title-" <> @k}>Title</label>
      <input
        id={"briefing-title-" <> @k}
        type="text"
        name="title"
        value={@task_title}
        class={[field(), "min-h-11"]}
      />
      <label class="mb-1 mt-2.5 block text-xs text-subtle" for={"briefing-project-" <> @k}>
        Project
        <span class="text-warning" data-role="briefing-project-hint">
          · this insight didn't name one, pick it here
        </span>
      </label>
      <select
        id={"briefing-project-" <> @k}
        name="project_id"
        class={[field(), "min-h-11"]}
        data-role="briefing-project-picker"
      >
        <option value="">Choose a project…</option>
        <option :for={p <- @options} value={p.id} selected={p.id == @chosen}>{p.name}</option>
      </select>
    </form>
    """
  end

  defp body_for(%{item: %{kind: :outside}} = assigns) do
    ~H"""
    <div class="mt-3 space-y-1 text-sm text-base-content" data-role="briefing-outside">
      <p data-role="briefing-outside-to">{BriefingCopy.outside_to(@item.email)}</p>
      <p :if={@item.draft} class="font-semibold" data-role="briefing-outside-status">
        Draft, not sent
      </p>
      <p :if={is_nil(@item.draft)} class="text-subtle" data-role="briefing-outside-mail-off">
        {BriefingCopy.mail_off()}
      </p>
    </div>
    """
  end

  defp body_for(assigns), do: ~H""

  # The card's one primary action (and a question's secondary).
  defp primary_actions(%{item: %{may_handle?: false}} = assigns), do: ~H""

  defp primary_actions(%{item: %{kind: :question}} = assigns) do
    ~H"""
    <button
      type="submit"
      form={"briefing-answer-" <> @k}
      class={btn_primary()}
      data-role="briefing-answer"
    >
      Send answer
    </button>
    <button
      :if={@form != :reroute}
      type="button"
      class={btn_secondary()}
      phx-click="open"
      phx-value-key={@k}
      phx-value-form="reroute"
      phx-target={@ui.myself}
      data-role="briefing-reroute"
    >
      Not mine · reroute
    </button>
    """
  end

  defp primary_actions(%{item: %{kind: :page_edit}} = assigns) do
    ~H"""
    <button
      :if={@form != :edit}
      type="button"
      class={btn_primary()}
      phx-click="act"
      phx-value-key={@k}
      phx-value-verb="apply"
      phx-target={@ui.myself}
      data-role="briefing-apply"
    >
      Apply edit
    </button>
    <button
      :if={@form != :edit}
      type="button"
      class={btn_secondary()}
      phx-click="open"
      phx-value-key={@k}
      phx-value-form="edit"
      phx-target={@ui.myself}
      data-role="briefing-edit-first"
    >
      Edit first
    </button>
    <button
      :if={@form == :edit}
      type="submit"
      form={"briefing-edit-" <> @k}
      class={btn_primary()}
      data-role="briefing-apply-mine"
    >
      Apply my version
    </button>
    <button
      :if={@form == :edit}
      type="button"
      class={btn_ghost()}
      phx-click="close"
      phx-value-key={@k}
      phx-target={@ui.myself}
    >
      Cancel
    </button>
    """
  end

  defp primary_actions(%{item: %{kind: :task, project: nil}} = assigns) do
    assigns = assign(assigns, :chosen, Map.get(assigns.ui.picked, assigns.k))

    ~H"""
    <button
      type="submit"
      form={"briefing-file-" <> @k}
      class={btn_primary()}
      disabled={is_nil(@chosen)}
      aria-describedby={if(is_nil(@chosen), do: "briefing-file-why-" <> @k)}
      data-role="briefing-file"
    >
      File task
    </button>
    <span
      :if={is_nil(@chosen)}
      id={"briefing-file-why-" <> @k}
      class="text-sm text-subtle"
      data-role="briefing-file-disabled-reason"
    >
      Pick a project to file this.
    </span>
    """
  end

  defp primary_actions(%{item: %{kind: :task}} = assigns) do
    ~H"""
    <button
      type="button"
      class={btn_primary()}
      phx-click="act"
      phx-value-key={@k}
      phx-value-verb="apply"
      phx-target={@ui.myself}
      data-role="briefing-file"
    >
      File task
    </button>
    """
  end

  defp primary_actions(%{item: %{kind: :outside}} = assigns) do
    ~H"""
    <.link
      :if={BriefingCopy.draft_path(@item.draft)}
      navigate={BriefingCopy.draft_path(@item.draft)}
      class={btn_primary()}
      data-role="briefing-open-draft"
    >
      Open draft
    </.link>
    """
  end

  defp primary_actions(assigns) do
    ~H"""
    <button
      type="button"
      class={btn_secondary()}
      phx-click="act"
      phx-value-key={@k}
      phx-value-verb="got_it"
      phx-target={@ui.myself}
      data-role="briefing-got-it"
    >
      Got it
    </button>
    """
  end

  attr(:item, :map, required: true)

  defp why(assigns) do
    assigns = assign(assigns, :evidence, BriefingCopy.evidence(assigns.item.insight))

    ~H"""
    <details class="mt-2 text-sm text-subtle" data-role="briefing-why">
      <summary class="focus-visible-ring inline-flex min-h-11 cursor-pointer items-center rounded text-interactive lg:min-h-0">
        Why am I seeing this?
      </summary>
      <ul :if={@evidence != []} class="ml-5 mt-1.5 list-disc">
        <li :for={line <- @evidence}>{line}</li>
      </ul>
      <p class="mt-1 text-xs">{BriefingCopy.from_line(@item.insight)}</p>
    </details>
    """
  end

  # ── Done cards ────────────────────────────────────────────────────────

  defp done_card(assigns) do
    {title, _body} = BriefingCopy.title_and_body(assigns.item.insight)

    assigns =
      assigns
      |> assign(:title, if(title == "", do: nil, else: title))
      |> assign(:r, BriefingCopy.receipt(assigns.item))
      |> assign(:tag, BriefingCopy.kind_tag(assigns.item.kind))
      |> assign(:k, assigns.item.key)
      |> assign(:error, Map.get(assigns.ui.errors, assigns.item.key))
      |> assign(:form, Map.get(assigns.ui.open_form, assigns.item.key))

    ~H"""
    <article
      id={"briefing-item-" <> @k}
      class="rounded-xl border border-edge bg-base-100 px-4 py-3.5"
      data-role="briefing-card"
      data-key={@k}
      data-kind={@item.kind}
      data-section="done"
    >
      <.kind_tag tag={@tag} />
      <p :if={@title} class="text-sm font-semibold text-base-content">{@title}</p>
      <div
        class="mt-1 flex flex-wrap items-center gap-x-3 gap-y-1 text-sm text-subtle"
        data-role="briefing-receipt"
      >
        <span class="w-full min-w-0 sm:w-auto sm:flex-1">
          <span class={[
            "inline-flex items-center gap-1",
            if(@r.icon, do: "font-bold text-success", else: "font-semibold text-base-content")
          ]}>
            <span
              :if={@r.icon == :reroute}
              class="hero-arrow-uturn-right size-4"
              aria-hidden="true"
            >
            </span>
            <span data-role="briefing-receipt-verb">{@r.verb}</span>
          </span>{@r.rest}
          <.link
            :if={@r.link}
            navigate={elem(@r.link, 1)}
            class={["ml-1", link()]}
            data-role="briefing-receipt-link"
          >
            {elem(@r.link, 0)}
          </.link>
        </span>
        <span
          :if={@item.may_handle? and @r.inverses != []}
          class="-ml-2 flex flex-wrap gap-1 sm:ml-0"
        >
          <button
            :for={inv <- @r.inverses}
            type="button"
            class={[
              text_button(),
              if(inv.tone == :error, do: "gap-1 text-base-content", else: "text-interactive")
            ]}
            phx-click={inverse_event(inv)}
            phx-value-key={@k}
            phx-value-verb={inverse_verb(inv)}
            phx-value-form="move"
            phx-target={@ui.myself}
            data-role="briefing-inverse"
            data-action={inv.action}
            data-tone={inv.tone}
          >
            <%!-- Delete: the destructive signal is the error-coloured icon
                 (non-text, 3:1), the label is body text. text-error as TEXT
                 measures 3.74:1 light / 4.42:1 dark, under 4.5:1. --%>
            <span
              :if={inv.tone == :error}
              class="hero-trash size-4 shrink-0 text-error"
              aria-hidden="true"
              data-role="briefing-inverse-icon"
            >
            </span>
            <span data-role="briefing-inverse-label">{inv.label}</span>
          </button>
        </span>
      </div>

      <form
        :if={@form == :move}
        id={"briefing-move-" <> @k}
        phx-submit="act"
        phx-target={@ui.myself}
        class="mt-3 flex flex-wrap items-end gap-2"
        data-role="briefing-move-form"
      >
        <input type="hidden" name="key" value={@k} />
        <input type="hidden" name="verb" value="move" />
        <label class="sr-only" for={"briefing-move-project-" <> @k}>Project</label>
        <select
          id={"briefing-move-project-" <> @k}
          name="project_id"
          class={[field(), "min-h-11 min-w-0 flex-1"]}
        >
          <option value="">Choose a project…</option>
          <option
            :for={p <- Map.get(@ui.projects, Tier.org_id(@item.insight), [])}
            :if={is_nil(@item.project) or p.id != @item.project.id}
            value={p.id}
          >
            {p.name}
          </option>
        </select>
        <button type="submit" class={btn_secondary()}>Move</button>
        <button
          type="button"
          class={btn_ghost()}
          phx-click="close"
          phx-value-key={@k}
          phx-target={@ui.myself}
        >
          Cancel
        </button>
      </form>

      <p
        :if={@error}
        role="alert"
        class="mt-2 flex items-center gap-1.5 text-sm text-base-content"
        data-role="briefing-card-error"
      >
        <span class="hero-exclamation-circle size-4 shrink-0 text-error" aria-hidden="true"></span>
        {@error}
      </p>
    </article>
    """
  end

  defp inverse_event(%{action: :undo}), do: "undo"
  defp inverse_event(%{action: :move}), do: "open"
  defp inverse_event(_inv), do: "act"

  defp inverse_verb(%{action: :revert}), do: "revert"
  defp inverse_verb(%{action: :delete}), do: "delete"
  defp inverse_verb(_inv), do: nil

  attr(:settings, :map, required: true)
  attr(:admin?, :boolean, required: true)

  defp settings_note(assigns) do
    assigns = assign(assigns, :note, BriefingCopy.settings_note(assigns.settings))

    ~H"""
    <p
      class="mt-6 border-t border-edge pt-3 text-xs text-subtle"
      data-role="briefing-settings-note"
    >
      {@note.lead}
      <.link navigate="/memory/insights" class={link()} data-role="briefing-settings-link">
        Briefing settings
      </.link>{@note.flags}<span :if={
        @admin?
      }>
        ·
        <.link
          navigate="/admin/insights"
          class={link()}
          data-role="briefing-install-settings-link"
        >
          Install settings
        </.link></span>
    </p>
    """
  end

  defp btn_primary, do: @btn_primary
  defp btn_secondary, do: @btn_secondary
  defp btn_ghost, do: @btn_ghost
  # A receipt's way back is a ghost TEXT button, not a daisy `.btn`:
  # `.text-interactive` lives in app.css's components layer, where `.btn`'s
  # own colour beats it. Delete is the error colour, never a red fill.
  defp text_button,
    do:
      "focus-visible-ring inline-flex min-h-11 items-center rounded px-2 text-sm font-semibold lg:min-h-0"

  defp field, do: @field
  defp link, do: @link
end
