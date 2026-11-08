defmodule PlatformWeb.MeetingLive.CalendarRedirect do
  @moduledoc """
  Where an old `/meetings` listing or schedule link lands now (task 01a1b8a5
  stage 4): the Calendar. The app-host `/meetings` index is retired; its
  links (bookmarks, mail, the Calendar's own old "View in Meetings") keep
  working by being mapped onto Calendar's own params.

  An allow list, not a pass-through. Only these survive, each re-validated:

    * `meeting=<uuid>` — the v4 list's selection. Calendar re-resolves it
      through the viewer scope (`Meetings.get_meeting_for_user/2`) and opens
      that event's details on its day; a meeting the viewer cannot see opens
      plain Calendar, exactly like a stale id.
    * `view=archive` — the archive. Calendar's Past events (`past=1`).
    * `schedule=true` — the old create sheet. Calendar's one editor
      (`new=1`), with `date` (ISO, parsed) and `start_time` (`TimeEntry`)
      carried as `date` and `start`, and `project_id` (a UUID; Calendar only
      uses it when it is one of the viewer's projects).
    * `date` — an ISO date that parses.

  Everything else is dropped: search text, chips, person filters, tabs and
  any parameter this module does not name. The mapping never reads the
  database, so it cannot leak whether a meeting exists.

  Direct room links are NOT redirected and never pass through here:
  `/meetings/:slug`, the guest `/:slug/:token` and `/g/:code`, the
  `invite.ics` feed and the `/api/app/meetings/:id/join|leave` API keep
  their own routes (`PlatformWeb.Router`).
  """

  use PlatformWeb, :verified_routes

  alias PlatformWeb.TimeEntry

  @doc "The Calendar path for an old `/meetings` index `params` map."
  @spec path(map()) :: String.t()
  def path(params) when is_map(params) do
    query =
      []
      |> put_meeting(params)
      |> put_past(params)
      |> put_new(params)
      |> put_date(params)
      |> Enum.reverse()

    case query do
      [] -> ~p"/calendar"
      query -> ~p"/calendar?#{query}"
    end
  end

  def path(_params), do: ~p"/calendar"

  defp put_meeting(acc, %{"meeting" => id}) when is_binary(id) do
    if Platform.UUID.valid?(id), do: [{"meeting", id} | acc], else: acc
  end

  defp put_meeting(acc, _), do: acc

  defp put_past(acc, %{"view" => "archive"}), do: [{"past", "1"} | acc]
  defp put_past(acc, _), do: acc

  defp put_new(acc, %{"schedule" => "true"} = params) do
    acc = [{"new", "1"} | acc]

    acc =
      case TimeEntry.parse(params["start_time"]) do
        {:ok, time} -> [{"start", TimeEntry.format(time)} | acc]
        _ -> acc
      end

    case params["project_id"] do
      id when is_binary(id) -> if Platform.UUID.valid?(id), do: [{"project", id} | acc], else: acc
      _ -> acc
    end
  end

  defp put_new(acc, _), do: acc

  defp put_date(acc, %{"date" => date}) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, date} -> [{"date", Date.to_iso8601(date)} | acc]
      _ -> acc
    end
  end

  defp put_date(acc, _), do: acc
end
