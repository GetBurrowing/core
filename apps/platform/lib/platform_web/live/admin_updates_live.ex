defmodule PlatformWeb.AdminUpdatesLive do
  @moduledoc """
  `/admin/updates` (task 01a1b7b6 stage 3): the install's root admin turns
  automatic updates on or off, reads the channel, presses Update now and sees
  the last result. Everything goes through `Platform.Updates`, which talks to
  the host updater only through its inbox and its status file.

  ## Authorization

  The route is in the `:admin` live_session (ModuleGate), which admits any
  holder of the admin module. This page is narrower: `mount/3` AND every
  `handle_event/3` re-check `Platform.Tenancy.root_admin?/1`. A non-root
  event writes nothing and gets a flash error. `Platform.Updates` itself does
  not authorize; this view is its only caller.

  ## Refresh

  No PubSub topic: the view re-reads status.json every 5 s while connected.

  ## Copy and colour (design canvas 01a1b7b9)

  Orange (`primary`) is only the Update now button. A rollback is the safety
  net working, so it reads in the warning outline and never in red. A failed
  update always says why ("update failed · rollback blocked by migration").
  """

  use PlatformWeb, :live_view

  alias Platform.Tenancy
  alias Platform.Updates

  @refresh_ms 5_000

  @impl true
  def mount(_params, _session, socket) do
    if root?(socket) do
      if connected?(socket), do: schedule_refresh()

      {:ok,
       socket
       |> assign(:page_title, "Updates")
       |> assign(:pending_auto_update, nil)
       |> assign(:requested_at, nil)
       |> assign(:now, DateTime.utc_now())
       |> load_status()}
    else
      {:ok,
       socket
       |> put_flash(:error, "Only this install's root admin can manage updates.")
       |> redirect(to: ~p"/admin")}
    end
  end

  @impl true
  def handle_event(event, params, socket) do
    if root?(socket) do
      handle_root_event(event, params, socket)
    else
      {:noreply, put_flash(socket, :error, "Only this install's root admin can manage updates.")}
    end
  end

  defp handle_root_event("set_auto_update", params, socket) do
    enabled = get_in(params, ["updates", "auto_update"]) == "true"

    case Updates.set_auto_update(enabled, socket.assigns[:current_user_record]) do
      :ok ->
        {:noreply,
         socket
         |> assign(:pending_auto_update, enabled)
         |> assign(:form, form_for(enabled))}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:form, form_for(socket.assigns.auto_update))
         |> put_flash(:error, "The setting was not saved: the updater's inbox is unavailable.")}
    end
  end

  defp handle_root_event("update_now", _params, socket) do
    if socket.assigns.status_kind == :ok and socket.assigns.status.channel == "pinned" do
      {:noreply, put_flash(socket, :error, "Pinned: this server does not move.")}
    else
      case Updates.request(:update, socket.assigns[:current_user_record]) do
        {:ok, _request_id} ->
          {:noreply,
           socket
           |> assign(:requested_at, DateTime.utc_now())
           |> put_flash(:info, "Update requested.")}

        {:error, _reason} ->
          {:noreply,
           put_flash(socket, :error, "Update not requested: the updater's inbox is unavailable.")}
      end
    end
  end

  defp handle_root_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info(:refresh, socket) do
    schedule_refresh()
    {:noreply, socket |> assign(:now, DateTime.utc_now()) |> load_status()}
  end

  # A stray message (a shell broadcast, a late reply) must not crash an
  # admin page.
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp schedule_refresh, do: Process.send_after(self(), :refresh, @refresh_ms)

  defp root?(socket), do: Tenancy.root_admin?(socket.assigns[:current_user_record])

  defp load_status(socket) do
    {kind, status} =
      case Updates.status() do
        %{} = status -> {:ok, status}
        :not_installed -> {:not_installed, nil}
        {:error, _} -> {:unreadable, nil}
      end

    published = status && status.auto_update
    pending = socket.assigns[:pending_auto_update]
    # Show what the admin chose until the updater publishes it.
    pending = if pending == published, do: nil, else: pending
    auto_update = if is_nil(pending), do: published != false, else: pending

    socket
    |> assign(:status_kind, kind)
    |> assign(:status, status)
    |> assign(:pending_auto_update, pending)
    |> assign(:auto_update, auto_update)
    |> assign(:form, form_for(auto_update))
  end

  defp form_for(enabled), do: to_form(%{"auto_update" => enabled}, as: :updates)

  # -- copy -------------------------------------------------------------------

  @doc false
  def short(nil), do: nil
  def short(commit) when is_binary(commit), do: String.slice(commit, 0, 7)

  @doc false
  # {glyph, words, tone}. Tone :error only when an update failed and the
  # server could not go back; a rollback is :warning, never :error.
  def result_line(%{last_result: result} = status) do
    reason = status.last_request && status.last_request.reason

    case result do
      "never_run" ->
        {"·", "not checked yet", :subtle}

      "ok" ->
        {"●", "updated", :success}

      "up_to_date" ->
        {"●", "up to date", :success}

      "checked" ->
        {"○", "checked", :subtle}

      "no_release_on_channel" ->
        {"·", "no release on this channel yet", :subtle}

      "skipped_bad_digest" ->
        {"·", "skipped a release that failed on this server", :subtle}

      "deferred_meeting_live" ->
        {"○", "waiting for the live meeting to end", :subtle}

      "held_irreversible" ->
        {"▲", "held · this release can't be rolled back automatically", :warning}

      "rolled_back" ->
        {"↶", "rolled back", :warning}

      "rollback_failed" ->
        {"✕", "update failed · rollback did not restore health", :error}

      "failed_rollback_blocked" ->
        {"✕", "update failed · rollback blocked by migration", :error}

      "pinned" ->
        {"·", "pinned", :subtle}

      "not_pinnable" ->
        {"·", "can't update · this server's image has no registry digest", :subtle}

      "refused" ->
        {"·", refused_words(reason), :subtle}

      _ ->
        {"·", "unknown", :subtle}
    end
  end

  defp refused_words(nil), do: "request refused"
  defp refused_words(reason), do: "request refused · " <> String.replace(reason, "_", " ")

  @doc false
  def ago(nil, _now), do: nil

  def ago(iso, now) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _} ->
        seconds = max(DateTime.diff(now, at), 0)

        cond do
          seconds < 60 -> "just now"
          seconds < 3600 -> "#{div(seconds, 60)} min ago"
          seconds < 86_400 -> "#{div(seconds, 3600)} h ago"
          true -> "#{div(seconds, 86_400)} d ago"
        end

      _ ->
        nil
    end
  end

  defp tone_class(:success), do: "text-success"
  defp tone_class(:warning), do: "rounded border border-warning px-1 text-warning"
  defp tone_class(:error), do: "text-error"
  defp tone_class(_), do: "text-subtle"

  defp headline(%{channel: channel} = status) do
    cond do
      channel == "pinned" ->
        nil

      status.available ->
        {"A newer #{channel} release is ready.", "text-info"}

      status.last_result in ["up_to_date", "ok"] ->
        {"You are on the latest #{channel} release.", nil}

      true ->
        nil
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-full min-h-0 flex-col">
      <.breadcrumb segments={[
        %{label: "Admin", navigate: ~p"/admin"},
        %{label: "Updates", navigate: nil}
      ]} />
      <div class="flex items-center justify-between border-b border-edge px-4 py-3">
        <h1 class="text-sm font-semibold uppercase tracking-widest text-base-content">
          Admin · Updates
        </h1>
      </div>

      <div class="flex-1 min-h-0 overflow-y-auto p-4 clears-tab-bar">
        <div class="mx-auto max-w-2xl space-y-4">
          <%= case @status_kind do %>
            <% :not_installed -> %>
              <section
                class="rounded-xl border border-edge bg-base-100 p-4"
                data-role="updates-not-installed"
              >
                <p class="text-sm font-medium text-base-content">
                  The updater isn't installed on this server yet
                </p>
                <p class="mt-2 text-sm text-subtle">
                  Whoever holds this server's root key installs it once. The steps are under
                  "Updates" in the install guide (docs/burrow/installs.md).
                </p>
              </section>
            <% :unreadable -> %>
              <section
                class="rounded-xl border border-edge bg-base-100 p-4"
                data-role="updates-unreadable"
              >
                <p class="text-sm text-base-content">
                  The updater's status can't be read right now. It is rewritten after every check;
                  this page tries again every few seconds.
                </p>
              </section>
            <% :ok -> %>
              <.updates_card
                status={@status}
                form={@form}
                auto_update={@auto_update}
                pending_auto_update={@pending_auto_update}
                requested_at={@requested_at}
                now={@now}
              />
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  attr :status, :map, required: true
  attr :form, :any, required: true
  attr :auto_update, :boolean, required: true
  attr :pending_auto_update, :any, default: nil
  attr :requested_at, :any, default: nil
  attr :now, :any, required: true

  defp updates_card(assigns) do
    status = assigns.status
    pinned? = status.channel == "pinned"
    deferred? = status.last_result == "deferred_meeting_live"
    held? = status.last_result == "held_irreversible"
    {glyph, words, tone} = result_line(status)

    assigns =
      assigns
      |> assign(:pinned?, pinned?)
      |> assign(:deferred?, deferred?)
      |> assign(:held?, held?)
      |> assign(:glyph, glyph)
      |> assign(:words, words)
      |> assign(:tone, tone)
      |> assign(:headline, headline(status))
      |> assign(:running, short(status.current && status.current.commit))
      |> assign(:checked, ago(status.last_checked_at, assigns.now))
      |> assign(:result_at, status.last_checked_at && String.slice(status.last_checked_at, 0, 16))

    ~H"""
    <section class="rounded-xl border border-edge bg-base-100" data-role="updates-card">
      <div class="space-y-3 p-4">
        <p class="font-mono text-sm tabular-nums text-base-content" data-role="updates-meta">
          <span data-role="updates-channel">{@status.channel || "unknown"}</span>
          <span :if={@running}> · running   {@running}</span>
          <span :if={@checked}> · checked   {@checked}</span>
        </p>

        <p :if={@headline} class="text-sm text-base-content" data-role="updates-headline">
          <span :if={elem(@headline, 1)} class={elem(@headline, 1)}>○</span>
          {elem(@headline, 0)}
        </p>

        <p class="text-sm" data-role="updates-last-result" data-result={@status.last_result}>
          <span class="text-subtle">Last result:</span>
          <span class={tone_class(@tone)}>{@glyph} {@words}</span>
          <span :if={@result_at} class="font-mono text-xs tabular-nums text-subtle">
            {@result_at} UTC
          </span>
        </p>

        <p
          :if={@status.last_rollback}
          class="text-sm text-base-content"
          data-role="updates-last-rollback"
        >
          <span class="rounded border border-warning px-1 text-warning">↶ rolled back</span>
          <span class="font-mono text-xs tabular-nums">
            {short(Updates.commit(@status.last_rollback.from)) || "?"} → {short(
              Updates.commit(@status.last_rollback.to)
            ) || "?"}
            <span :if={@status.last_rollback.at} class="text-subtle">
              · {String.slice(@status.last_rollback.at, 0, 16)} UTC
            </span>
          </span>
        </p>

        <p :if={@deferred?} class="text-sm text-base-content" data-role="updates-deferred">
          Waiting: a meeting is live<span :if={@status.deferred_since}>
            (since <span class="font-mono tabular-nums">{String.slice(@status.deferred_since, 0, 16)} UTC</span>)</span>.
          Starts when the live meeting ends.
        </p>

        <p :if={@held?} class="text-sm text-base-content" data-role="updates-held">
          This release can't be rolled back automatically. Update now takes a database backup
          first, then updates.
        </p>
      </div>

      <.form
        for={@form}
        id="admin-updates-form"
        phx-change="set_auto_update"
        class="flex items-center justify-between gap-4 border-t border-edge p-4"
      >
        <div class="min-w-0">
          <p class="text-sm font-medium text-base-content">Update automatically</p>
          <p class="text-xs text-subtle" data-role="updates-auto-note">
            <%= if @pending_auto_update != nil do %>
              Saved. The server picks it up in a moment.
            <% else %>
              Checks for a new {@status.channel || ""} release every hour.
            <% end %>
          </p>
        </div>
        <.input
          field={@form[:auto_update]}
          type="checkbox"
          class="toggle toggle-sm"
          aria-label="Update automatically"
          data-role="updates-auto-update"
        />
      </.form>

      <div class="space-y-2 border-t border-edge p-4">
        <p :if={@pinned?} class="text-sm text-base-content" data-role="updates-pinned">
          Pinned: this server does not move.
        </p>
        <button
          type="button"
          phx-click="update_now"
          class="btn btn-primary btn-sm"
          disabled={@pinned?}
          data-confirm={
            @held? &&
              "This release can't be rolled back automatically. A database backup is taken first. Update now?"
          }
          data-role="updates-update-now"
        >
          Update now
        </button>
        <p :if={@requested_at} class="text-xs text-subtle" data-role="updates-requested">
          Requested. The result shows here when the server finishes.
        </p>
        <p :if={not @pinned?} class="text-xs leading-relaxed text-subtle">
          Burrow downloads the new version and restarts, which takes a few minutes. It waits for
          any live meeting to end first. If the new version does not report healthy within
          10 minutes, Burrow switches back to the version you are on now.
        </p>
      </div>
    </section>
    """
  end
end
