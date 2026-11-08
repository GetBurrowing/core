defmodule PlatformWeb.InstructionPacksComponent do
  @moduledoc "Owner controls inside Settings Help; all mutations re-authorize through the context."
  use PlatformWeb, :live_component
  alias Platform.InstructionPacks.{Entry, Installer, Owner}

  @impl true
  def update(assigns, socket) do
    {:ok, socket |> assign(assigns) |> assign(:notice, nil) |> reload()}
  end

  defp reload(socket) do
    case Owner.snapshot(socket.assigns.actor) do
      {:ok, data} -> assign(socket, data: data, authorized: true)
      {:error, _} -> assign(socket, data: nil, authorized: false)
    end
  end

  @impl true
  def handle_event(event, params, socket) do
    actor = socket.assigns.actor
    result = with :ok <- Owner.authorize(actor), do: act(event, params, actor)

    notice =
      case result do
        {:ok, _} ->
          "Saved. Local changes stay protected."

        {:error, :stale_conflict} ->
          "This content changed since you reviewed it. Review the refreshed conflict before choosing again."

        {:error, :unauthorized} ->
          "Only an install owner or authorized install administrator can change these settings."

        {:error, :sharing_disabled} ->
          "Instruction updates are off. Enable them before applying a version."

        {:error, :sharing_changed} ->
          "Sharing settings changed. Review the current settings and try again."

        _ ->
          "Couldn't save. Your current instructions are unchanged."
      end

    {:noreply, socket |> reload() |> assign(:notice, notice)}
  end

  defp act("sharing", %{"key" => key, "enabled" => value}, actor) when value in ["true", "false"],
    do: Owner.set_sharing(key, value == "true", actor)

  defp act("stop", %{"enabled" => value}, actor) when value in ["true", "false"],
    do: Installer.stop_updates(value == "true", actor)

  defp act("refresh", _, _actor), do: {:ok, :refreshed}
  defp act("resume", %{"pack" => pack}, actor), do: Installer.pin(pack, nil, actor)

  defp act("pin", %{"pack" => pack, "version" => version}, actor) do
    with {version, ""} <- Integer.parse(version), do: Owner.pin(pack, version, actor)
  end

  defp act("rollback", %{"pack" => pack, "version" => version}, actor) do
    with {version, ""} <- Integer.parse(version),
         do: Installer.rollback(pack, version, Owner.roots(), actor)
  end

  defp act(
         "resolve",
         %{
           "pack" => pack,
           "type" => type,
           "target" => target,
           "choice" => choice,
           "token" => token
         },
         actor
       )
       when choice in ["local", "incoming"],
       do:
         Installer.resolve_conflict(
           pack,
           type,
           target,
           if(choice == "local", do: :local, else: :incoming),
           token,
           actor
         )

  defp act(_, _, _), do: {:error, :invalid_action}

  defp time(nil), do: "Not yet"
  defp time(value) when is_binary(value), do: value
  defp time(value), do: Calendar.strftime(value, "%Y-%m-%d %H:%M UTC")
  defp effective(nil), do: "Local version"
  defp effective(v), do: "v#{v}"

  defp status(row, sharing) do
    cond do
      sharing.instruction_updates_stopped or not sharing.instruction_updates ->
        "Disabled"

      row.state.pinned_version ->
        "Pinned"

      row.state.check_error == "verification" ->
        "Verification failure — last good instructions remain active"

      row.state.check_error == "network" ->
        "Network failure — last good instructions remain active"

      row.conflicts != [] ->
        "Local overrides / conflicts"

      Enum.any?(row.versions, &is_nil/1) ->
        "Local overrides"

      is_nil(row.state.version) ->
        "Pending first verified pack"

      true ->
        "Up to date with the latest verified release received"
    end
  end

  defp check_status(check, sharing) do
    cond do
      sharing.instruction_updates_stopped or not sharing.instruction_updates ->
        "Instruction updates are disabled."

      check.pending ->
        "Checking for instruction updates…"

      check.error_kind == "network" ->
        "Network failure — last good instructions remain active."

      check.error_kind == "verification" ->
        "Verification failure — last good instructions remain active."

      check.last_successful_check_at ->
        "Last update check succeeded."

      true ->
        "Waiting for the first update check."
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="instruction-packs-controls" class="space-y-5 text-sm text-base-content">
      <p :if={!@authorized} role="status">
        Only an install owner or authorized install administrator can view and change install sharing.
      </p>
      <%= if @authorized do %>
        <p class="text-subtle">
          Choose what this install shares with Burrow. New installs receive signed agent instruction updates by default. Existing settings stay unchanged. Local edits stay yours.
        </p>
        <p
          :if={@notice}
          role="status"
          aria-live="polite"
          class="rounded-box border border-edge bg-base-200 p-3"
        >
          {@notice}
        </p>
        <button
          type="button"
          phx-click="refresh"
          phx-target={@myself}
          phx-disable-with="Refreshing…"
          class="btn btn-sm focus-visible-ring"
        >
          Refresh status
        </button>
        <section
          :for={entry <- Platform.Sharing.registry()}
          class="rounded-box border border-edge bg-base-100 p-3 space-y-2"
        >
          <button
            type="button"
            role="switch"
            aria-checked={to_string(Map.fetch!(@data.sharing, entry.key))}
            aria-label={entry.title}
            phx-click="sharing"
            phx-target={@myself}
            phx-value-key={entry.key}
            phx-value-enabled={to_string(!Map.fetch!(@data.sharing, entry.key))}
            phx-disable-with="Saving…"
            class="flex min-h-11 w-full items-center justify-between gap-3 text-left focus-visible-ring"
          >
            <span class="font-semibold">{entry.title}</span><span class="text-primary">{if Map.fetch!(@data.sharing, entry.key), do: "On", else: "Off"}</span>
          </button>
          <p class="text-subtle">{entry.description}</p>
          <details>
            <summary class="cursor-pointer min-h-11 py-3 focus-visible-ring">
              Exactly what's sent and received
            </summary>
            <ul class="list-disc pl-5 space-y-1">
              <li :for={line <- entry.exactly_sent}>{line}</li>
            </ul>
          </details>
        </section>
        <section
          class="rounded-box border border-edge bg-base-100 p-3 space-y-3"
          aria-label="Instruction update controls"
        >
          <h3 class="font-semibold">Agent instruction updates</h3>
          <p class="text-subtle">
            Receive signed role guidance, skills, prompt templates and setup dialogue. Packs cannot change permissions, tools, secrets or sharing switches. Anonymous outcome counts are sent only when the corresponding sharing switches allow them.
          </p>
          <button
            type="button"
            role="switch"
            aria-label="Stop instruction updates across this install"
            aria-checked={to_string(@data.sharing.instruction_updates_stopped)}
            phx-click="stop"
            phx-target={@myself}
            phx-value-enabled={to_string(!@data.sharing.instruction_updates_stopped)}
            phx-disable-with="Saving…"
            class="btn btn-outline w-full h-auto min-h-11 whitespace-normal focus-visible-ring"
          >
            {if @data.sharing.instruction_updates_stopped,
              do: "Instruction updates stopped — allow updates",
              else: "Stop instruction updates across this install"}
          </button>
          <section
            aria-label="Instruction check status"
            class="rounded-box border border-edge p-3 space-y-2"
          >
            <p role="status" data-role="instruction-check-status">
              {check_status(@data.check, @data.sharing)}
            </p>
            <p class="text-subtle">Last check: {time(@data.check.checked_at)}</p>
            <p class="text-subtle">
              Last successful check: {time(@data.check.last_successful_check_at)}
            </p>
          </section>
          <p :if={@data.packs == []} data-role="packs-empty" class="text-subtle">
            No verified instruction packs received yet. The next permitted scheduled check will look for updates.
          </p>
          <article
            :for={row <- @data.packs}
            id={"pack-" <> row.state.pack_id}
            class="border-t border-edge pt-4 space-y-3 min-w-0"
          >
            <h4 class="font-semibold break-words">{row.state.pack_id}</h4>
            <p data-role="pack-status" class="font-medium text-primary">
              {status(row, @data.sharing)}
            </p>
            <dl class="grid grid-cols-[auto_minmax(0,1fr)] gap-x-3 gap-y-1">
              <dt>Received version</dt>
              <dd>{if row.state.version, do: "v#{row.state.version}", else: "None"}</dd>
              <dt>Effective content</dt>
              <dd data-role="pack-effective">{Enum.map_join(row.versions, ", ", &effective/1)}</dd>
              <dt>Available version</dt>
              <dd data-role="pack-available">
                {if row.available,
                  do: "v#{row.available.version} (verified and received)",
                  else: "Not yet verified"}
              </dd>
              <dt>Published</dt>
              <dd>{time(row.manifest["published_at"])}</dd>
              <dt>Applied</dt>
              <dd>{time(row.state.applied_at)}</dd>
              <dt>Last check</dt>
              <dd>{time(row.state.checked_at)}</dd>
              <dt>Last successful check</dt>
              <dd>{time(row.state.last_successful_check_at)}</dd>
            </dl>
            <p class="break-words" data-role="pack-changelog">
              {row.manifest["changelog"] || "No changelog received."}
            </p>
            <p class="text-subtle">
              Pin a version you have already used. Resume updates to receive a newer published version.
            </p>
            <form
              :if={row.releases != []}
              phx-submit="pin"
              phx-target={@myself}
              class="flex flex-wrap items-end gap-2"
            >
              <input type="hidden" name="pack" value={row.state.pack_id} />
              <label class="min-w-0 flex-1">
                Version<select
                  name="version"
                  aria-label={"Version for " <> row.state.pack_id}
                  class="select select-bordered w-full"
                ><option
                    :for={release <- row.releases}
                    value={release.version}
                    selected={release.version == (row.state.pinned_version || row.state.version)}
                  >v{release.version}</option></select>
              </label>
              <button
                type="submit"
                phx-disable-with="Pinning…"
                class="btn btn-primary focus-visible-ring"
              >
                Pin
              </button>
            </form>
            <p :if={row.state.pinned_version} class="text-subtle">
              Pinned to v{row.state.pinned_version}. Automatic advances are paused.
            </p>
            <button
              :if={row.state.pinned_version}
              type="button"
              phx-click="resume"
              phx-target={@myself}
              phx-value-pack={row.state.pack_id}
              phx-disable-with="Saving…"
              class="btn btn-sm focus-visible-ring"
            >
              Resume updates
            </button>
            <button
              type="button"
              phx-click="rollback"
              phx-target={@myself}
              phx-value-pack={row.state.pack_id}
              phx-value-version={row.previous}
              disabled={
                is_nil(row.previous) or @data.sharing.instruction_updates_stopped or
                  not @data.sharing.instruction_updates
              }
              phx-disable-with="Rolling back…"
              class="btn btn-outline w-full h-auto min-h-11 focus-visible-ring"
            >
              Roll back to previous version
            </button>
            <p :if={is_nil(row.previous)} class="text-subtle">
              Rollback unavailable: no previously applied, verified version is retained.
            </p>
            <p
              :if={@data.sharing.instruction_updates_stopped or not @data.sharing.instruction_updates}
              class="text-subtle"
            >
              Enable instruction updates and clear the install-wide stop before applying a version.
            </p>
            <section
              :for={entry <- row.conflicts}
              data-role="pack-conflict"
              class="rounded-box border border-warning p-3 space-y-2"
            >
              <h5 class="font-semibold break-all">
                Local change preserved: {entry.type} / {entry.target}
              </h5>
              <p>Keep your local text or explicitly use the published version.</p>
              <h6 class="font-medium">Previous published content</h6>
              <pre data-role="pack-conflict-base" class="whitespace-pre-wrap break-all text-xs">{entry.conflict["base"] || "(no previous published content)"}</pre>
              <h6 class="font-medium">Your current content</h6>
              <pre class="whitespace-pre-wrap break-all text-xs">{entry.conflict["local"] || "(deleted locally)"}</pre>
              <h6 class="font-medium">Incoming published content</h6>
              <pre class="whitespace-pre-wrap break-all text-xs">{entry.conflict["incoming"] || "(removed by publisher)"}</pre>
              <div class="flex flex-wrap gap-2">
                <button
                  :for={
                    {label, choice} <- [
                      {"Keep my version", "local"},
                      {"Use published version", "incoming"}
                    ]
                  }
                  type="button"
                  phx-click="resolve"
                  phx-target={@myself}
                  phx-value-pack={row.state.pack_id}
                  phx-value-type={entry.type}
                  phx-value-target={entry.target}
                  phx-value-choice={choice}
                  phx-value-token={Entry.conflict_token(entry)}
                  phx-disable-with="Saving…"
                  class="btn btn-sm h-auto min-h-11 focus-visible-ring"
                >
                  {label}
                </button>
              </div>
            </section>
          </article>
        </section>
        <section aria-label="Instruction and sharing audit history">
          <h3 class="font-semibold">Recent history</h3>
          <p class="text-subtle">Latest 100 instruction and sharing changes, newest first.</p>
          <p :if={@data.events == []}>No changes recorded.</p>
          <ol class="space-y-2 mt-2">
            <li :for={event <- @data.events} class="border-b border-edge py-2 break-words">
              <time>{time(event.inserted_at)}</time><span class="block">{event.action} · {event.metadata["pack_id"] || event.metadata["key"] || "install"} {if event.metadata["version"], do: "· v#{event.metadata["version"]}"}
                  {if Map.has_key?(event.metadata, "value"), do: "· #{event.metadata["value"]}"}
                  {event.metadata["choice"]} {event.metadata["target"]}</span>
            </li>
          </ol>
        </section>
      <% end %>
    </div>
    """
  end
end
