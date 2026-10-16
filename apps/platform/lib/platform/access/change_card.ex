defmodule Platform.Access.ChangeCard do
  @moduledoc "Server-built consent facts and actions. Agent-authored prose never enters the card."
  alias Platform.Access.Proposal

  def document(%Proposal{} = proposal) do
    options = proposal.options
    chosen = Enum.find(options, &(&1["key"] == proposal.selected_option))
    impacts = if chosen, do: [chosen["impact"]], else: Enum.map(options, & &1["impact"])

    loses =
      impacts
      |> Enum.flat_map(
        &(&1["loses"] ++ Enum.filter(&1["inherited"], fn x -> x["effect"] == "loses" end))
      )
      |> unique_people()

    gains = impacts |> Enum.flat_map(& &1["gains"]) |> unique_people()
    conflicts = impacts |> Enum.flat_map(& &1["conflicts"]) |> Enum.uniq()
    inherited = impacts |> Enum.flat_map(& &1["inherited"]) |> Enum.uniq()
    count = impacts |> Enum.map(& &1["count"]) |> Enum.max(fn -> 0 end)
    state = proposal.state
    subject = (loses ++ gains) |> Enum.map(& &1["name"]) |> Enum.uniq() |> Enum.join(", ")
    subject = if subject == "", do: "access", else: subject

    nodes = [
      node("heading", "title", %{"value" => "Proposed change · " <> subject, "level" => 3}),
      node("badge", "state", %{"value" => status(state)})
    ]

    nodes =
      nodes ++
        removal(loses) ++
        Enum.map(gains, &person(&1, "+", "gain", "text-info")) ++
        Enum.with_index(conflicts, fn entry, i ->
          text(
            "cap-#{i}",
            "! Capped: #{entry["name"]} is limited by owner (#{entry["owner_name"]})",
            "text-warning"
          )
        end)

    nodes =
      nodes ++
        if(inherited == [],
          do: [],
          else: [
            text(
              "inherited",
              "Inherits: " <> inherited_summary(inherited),
              "text-base-content/60"
            )
          ]
        )

    nodes =
      nodes ++
        [
          text(
            "impact",
            "#{count} #{if count == 1, do: "person or agent", else: "people or agents"} affected."
          )
        ]

    details = if chosen, do: [chosen], else: options

    nodes =
      nodes ++
        Enum.with_index(details, fn option, i -> text("operation-#{i}", option["label"]) end)

    nodes = nodes ++ choices(proposal) ++ state_nodes(proposal)

    %{
      "version" => 1,
      "revision" => 1,
      "root" => %{
        "id" => "root",
        "type" => "card",
        "props" => %{
          "class_overrides" =>
            if(state == "cancelled", do: "opacity-60", else: "bg-base-100 border-edge")
        },
        "children" => nodes
      },
      "theme" => %{},
      "bindings" => %{},
      "meta" => %{"access_proposal_id" => proposal.id}
    }
  end

  defp inherited_summary(entries) do
    entries
    |> Enum.uniq_by(&{&1["resource"]["type"], &1["resource"]["id"]})
    |> Enum.frequencies_by(& &1["resource"]["type"])
    |> Enum.sort()
    |> Enum.map_join(", ", fn {type, count} ->
      label =
        case type do
          "space" -> if count == 1, do: "execution space", else: "execution spaces"
          "canvas" -> if count == 1, do: "canvas", else: "canvases"
          _ -> if count == 1, do: type, else: type <> "s"
        end

      "#{count} #{label}"
    end)
  end

  defp removal([]), do: []

  defp removal(people) do
    [
      %{
        "id" => "removals",
        "type" => "card",
        "props" => %{
          "tone" => "critical",
          "class_overrides" => "border-l-4 border-error bg-base-100"
        },
        "children" =>
          [
            node("text", "loss-count", %{
              "value" => "#{length(people)} lose access",
              "size" => "2xl",
              "weight" => "semibold",
              "class_overrides" => "text-error"
            })
          ] ++
            Enum.map(people, &person(&1, "−", "lose", "text-error"))
      }
    ]
  end

  defp person(entry, sign, prefix, class) do
    node("text", prefix <> "-" <> entry["type"] <> "-" <> entry["id"], %{
      "value" => "#{sign} #{entry["name"]} (#{entry["type"]})",
      "weight" => "medium",
      "principal_id" => entry["id"],
      "class_overrides" => class
    })
  end

  defp unique_people(entries), do: Enum.uniq_by(entries, &{&1["type"], &1["id"]})
  defp choices(%{options: [_]}), do: []

  defp choices(%{state: "proposed"} = row) do
    [
      node("action_row", "choices", %{
        "label" => "Choose a change",
        "class_overrides" =>
          "[&>button]:h-auto [&>button]:whitespace-normal [&>button]:max-w-full [&>button]:min-w-0 [&>button]:py-2",
        "actions" =>
          Enum.map(row.options, fn option ->
            %{
              "label" => option_label(option),
              "value" => "access_choose:" <> option["key"],
              "variant" => "outline"
            }
          end)
      })
    ]
  end

  defp choices(_), do: []

  defp option_label(option), do: option["label"]

  defp state_nodes(%{state: "proposed"} = row) do
    [
      node("action_row", "actions", %{
        "class_overrides" => "[&>button]:flex-1",
        "actions" => [
          %{
            "label" => "Apply",
            "value" => "access_apply",
            "variant" => "primary",
            "disabled" => is_nil(row.selected_option)
          },
          %{"label" => "Cancel", "value" => "access_cancel", "variant" => "outline"}
        ]
      })
    ]
  end

  defp state_nodes(%{state: "applied"} = row) do
    name = row.approved_by_name || "human"

    time = Calendar.strftime(row.approved_at, "%H:%M")

    [
      text("applied", "✓ Applied. Access has changed."),
      text("approver", "Applied by #{name}, #{time}", "text-base-content/60"),
      node("action_row", "undo", %{
        "actions" => [%{"label" => "Undo", "value" => "access_undo", "variant" => "outline"}]
      })
    ]
  end

  defp state_nodes(%{state: "undone"}),
    do: [text("undone", "↺ Undone. Access is back to how it was.")]

  defp state_nodes(%{state: "cancelled"}),
    do: [text("cancelled", "Cancelled. Access has not changed.")]

  defp state_nodes(%{state: state}) when state in ["stale", "failed"] do
    [
      text("stale", "Expired (stale). Ask your agent to propose again.", "text-warning"),
      node("action_row", "disabled", %{
        "actions" => [
          %{
            "label" => "Apply",
            "value" => "access_apply",
            "variant" => "primary",
            "disabled" => true
          }
        ]
      })
    ]
  end

  defp state_nodes(_), do: [text("applying", "Applying…")]
  defp status("proposed"), do: "not applied"
  defp status(state), do: state

  defp text(id, value, class \\ ""),
    do: node("text", id, %{"value" => value, "class_overrides" => class})

  defp node(type, id, props), do: %{"type" => type, "id" => id, "props" => props}
end
