defmodule Platform.Federation.CalendarTools do
  @moduledoc "Calendar tools resolve the authenticated runtime before entering the delegation context."
  alias Platform.Calendar.AgentAccess

  def definitions do
    [
      %{
        name: "calendar_list",
        description:
          "Read an owner's calendar using your explicit read grant. Private events require a private-read grant.",
        parameters: %{
          owner_id: %{type: "string", required: true},
          from: %{type: "string", required: true},
          to: %{type: "string", required: true},
          limit: %{type: "integer"},
          offset: %{type: "integer"}
        }
      },
      %{
        name: "calendar_propose",
        description:
          "Propose create or move under an explicit owner grant. Creates a durable tentative reservation and Inbox approval unless the owner preapproved. Same request_key returns the original intent. Booked and recurring events cannot be moved.",
        parameters: %{
          owner_id: %{type: "string", required: true},
          operation: %{type: "string", required: true, enum: ["create", "move"]},
          event_id: %{type: "string"},
          attributes: %{type: "object", required: true},
          request_key: %{type: "string", required: true}
        }
      }
    ]
    |> Enum.map(fn tool ->
      Map.merge(tool, %{
        returns:
          if(tool.name == "calendar_list",
            do:
              "%{events, total, has_more}; total is the complete bounded-window count, with default limit50 and maximum100.",
            else:
              "%{id, state, inbox_url}; state is pending or approved according to owner policy."
          ),
        limitations:
          "Authenticated active runtime, owner Calendar permission and live per-agent grant required. Private reads require read_private. Create/move require corresponding grant; booked, recurring and all-day moves are refused. Consent actions remain owner-only in Inbox.",
        when_to_use:
          "When the Calendar owner explicitly delegated reading or scheduling to this agent. Use a stable request_key to retry changes safely."
      })
    end)
    |> Kernel.++([draft_definition()])
  end

  # Task 01a1b8a5 stage 3. Kept out of the shared `returns`/`limitations`
  # above so calendar_list and calendar_propose stay byte for byte.
  defp draft_definition do
    %{
      name: "calendar_draft",
      description:
        "Prepare an event for the Calendar owner to review and save themselves. Write-free: creates no event, meeting, invitation, busy hold or Inbox item (calendar_propose is the tool that reserves time). Pass resolved values only: start/end as ISO 8601 with an offset, or as local wall time read in time_zone; attendees by user_id, email or name. Ambiguous names and local times a daylight-saving change repeats or skips come back as clarifications to ask the owner about. Same request_key returns the original draft.",
      parameters: %{
        owner_id: %{type: "string", required: true, description: "The Calendar owner's user id."},
        request_key: %{
          type: "string",
          required: true,
          description:
            "The request key from the owner's Calendar message, or your own stable key."
        },
        time_zone: %{
          type: "string",
          required: true,
          description: "IANA zone the owner gave (for example America/Chicago)."
        },
        title: %{type: "string", description: "Event title."},
        start: %{
          type: "string",
          description:
            "Start, ISO 8601. With an offset it is that instant; without one it is local time in time_zone. For all_day, a date."
        },
        end: %{
          type: "string",
          description: "End, same format as start. For all_day, the last day."
        },
        all_day: %{type: "boolean"},
        category: %{
          type: "string",
          enum: ["event", "focus", "ooo"],
          schema: %{type: "string", enum: ["event", "focus", "ooo"]},
          description: "event (default), focus (Focus time) or ooo (Out of office)."
        },
        visibility: %{
          type: "string",
          enum: ["busy", "details"],
          schema: %{type: "string", enum: ["busy", "details"]},
          description: "details (default) or busy."
        },
        call_enabled: %{type: "boolean", description: "Add a Burrow call. Off unless asked."},
        project_id: %{type: "string", description: "Project to hold a Burrow call."},
        notes: %{type: "string"},
        attendees: %{
          type: "array",
          schema: %{
            type: "array",
            items: %{
              type: "object",
              properties: %{
                user_id: %{type: "string"},
                email: %{type: "string"},
                name: %{type: "string"}
              }
            }
          },
          description:
            "People, each an object with user_id (from principal_search), email, or name. A name matching several people is a clarification, never a pick."
        }
      },
      returns:
        "%{status, url, expires_at, clarifications, issues}; status is ready, needs_clarification or incomplete. url opens the draft in Calendar for the owner only.",
      limitations:
        "Authenticated active runtime, owner Calendar permission and live per-agent create grant required. The link works only for the signed-in owner, for 24 hours, and saves at most once. Nothing is saved without the owner's Save.",
      when_to_use:
        "When the owner asks you, from Calendar or chat, to schedule something they will review first. Send the url back to them with any clarification questions."
    }
  end

  def execute(tool, args, context) do
    with runtime_id when is_binary(runtime_id) <- context[:runtime_id],
         %Platform.Agents.AgentRuntime{status: "active"} = runtime <-
           Platform.Federation.get_runtime_by_runtime_id(runtime_id) do
      scope = Platform.Access.Scope.for_runtime(runtime)

      case tool do
        "calendar_list" ->
          with {:ok, first, _} <- instant(args["from"]),
               {:ok, last, _} <- instant(args["to"]),
               {:ok, events} <- AgentAccess.read(scope, args["owner_id"], first, last),
               limit = Map.get(args, "limit", 50),
               offset = Map.get(args, "offset", 0),
               true <-
                 is_integer(limit) and limit in 1..100 and is_integer(offset) and offset >= 0 do
            {:ok,
             Platform.Federation.ResultBound.paged(
               :events,
               Enum.slice(events, offset, limit),
               length(events),
               offset
             )}
          end

        "calendar_propose" ->
          with {:ok, consent} <-
                 AgentAccess.propose(
                   scope,
                   args["owner_id"],
                   args["operation"],
                   args["attributes"],
                   args["request_key"],
                   args["event_id"]
                 ) do
            {:ok, %{id: consent.id, state: consent.state, inbox_url: "/inbox"}}
          end

        "calendar_draft" ->
          case Platform.Calendar.Draft.create(scope, args["owner_id"], args) do
            {:ok, draft, _created_or_existing} -> {:ok, draft_result(draft)}
            {:error, {:invalid, messages}} -> {:invalid, messages}
            error -> error
          end
      end
    else
      _ -> {:error, :forbidden}
    end
    |> case do
      {:ok, _} = result ->
        result

      {:invalid, messages} ->
        {:error, %{error: "calendar_draft: " <> Enum.join(messages, "; "), recoverable: true}}

      _ ->
        {:error, %{error: "Calendar grant denied or change unavailable", recoverable: false}}
    end
  end

  defp draft_result(draft) do
    %{
      status: Platform.Calendar.Draft.status(draft),
      url: Platform.Calendar.Draft.url(draft),
      expires_at: DateTime.to_iso8601(draft.expires_at),
      clarifications:
        Enum.map(draft.clarifications, fn c ->
          %{
            kind: c["kind"],
            question: c["question"],
            candidates:
              for(
                candidate <- c["candidates"] || [],
                do: Map.take(candidate, ["user_id", "name"])
              )
          }
        end),
      issues: draft.issues
    }
  end

  defp instant(value) when is_binary(value), do: DateTime.from_iso8601(value)
  defp instant(_), do: {:error, :invalid_date}
end
