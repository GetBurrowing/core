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
  end

  def execute(tool, args, context) do
    with runtime_id when is_binary(runtime_id) <- context[:runtime_id],
         %Platform.Agents.AgentRuntime{status: "active"} = runtime <-
           Platform.Federation.get_runtime_by_runtime_id(runtime_id) do
      scope = Platform.Access.Scope.for_runtime(runtime)

      case tool do
        "calendar_list" ->
          with {:ok, first, _} <- DateTime.from_iso8601(args["from"] || ""),
               {:ok, last, _} <- DateTime.from_iso8601(args["to"] || ""),
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
      end
    else
      _ -> {:error, :forbidden}
    end
    |> case do
      {:ok, _} = result -> result
      _ -> {:error, %{error: "Calendar grant denied or change unavailable", recoverable: false}}
    end
  end
end
