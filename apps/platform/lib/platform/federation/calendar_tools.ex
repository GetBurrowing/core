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
          to: %{type: "string", required: true}
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
               do: {:ok, %{events: events}}

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
