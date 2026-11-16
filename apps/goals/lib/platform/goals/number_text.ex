defmodule Platform.Goals.NumberText do
  @moduledoc """
  The goal's number line, in one place (task 01a1dfc1-dffb, Goals 7/8
  stage 4). The goal list, the goal page and the space update all say the
  same sentence, so it is built here and nowhere else:

    * a reading and a target: "{value} of {target} {unit}";
    * no reading (no source, an unknown source, a source that refuses, no
      reading yet) and a target: "Target: {target} {unit}", with no reading
      value and no reason text;
    * no target or no unit: "No number to follow yet".

  The target is the current stop's `target_value`, else the goal's; the unit
  is the goal's. `parts/3` returns the pieces for a caller that marks them
  up (the goal page bolds the value); `sentence/3` joins them as plain text.
  Neither reads anything: the caller passes the result of
  `Platform.Goals.goal_number/2`.
  """

  alias Platform.Goals.NumberFormatting

  @none "No number to follow yet"

  @type parts ::
          %{kind: :none}
          | %{kind: :reading, value: String.t(), target: String.t(), unit: String.t()}
          | %{kind: :target, target: String.t(), unit: String.t()}

  @doc "The number sentence as plain text."
  @spec sentence(map(), map() | nil, term()) :: String.t()
  def sentence(goal, current_stop, number_result) do
    case parts(goal, current_stop, number_result) do
      %{kind: :reading} = p -> "#{p.value} of #{p.target} #{p.unit}"
      %{kind: :target} = p -> "Target: #{p.target} #{p.unit}"
      %{kind: :none} -> @none
    end
  end

  @doc "The sentence's pieces, formatted, for a caller that marks them up."
  @spec parts(map(), map() | nil, term()) :: parts()
  def parts(goal, current_stop, number_result) do
    target = target(current_stop, goal)
    unit = Map.get(goal, :unit)

    cond do
      is_nil(target) or blank?(unit) ->
        %{kind: :none}

      value = reading_value(number_result) ->
        %{
          kind: :reading,
          value: NumberFormatting.format(value),
          target: NumberFormatting.format(target),
          unit: unit
        }

      true ->
        %{kind: :target, target: NumberFormatting.format(target), unit: unit}
    end
  end

  defp target(%{target_value: %Decimal{} = t}, _goal), do: t
  defp target(_stop, %{target_value: %Decimal{} = t}), do: t
  defp target(_stop, _goal), do: nil

  defp reading_value({:ok, result}), do: reading_value(result)
  defp reading_value({:reading, %{latest: %{value: value}}}), do: value
  defp reading_value(_cannot_measure), do: nil

  defp blank?(unit), do: not is_binary(unit) or String.trim(unit) == ""
end
