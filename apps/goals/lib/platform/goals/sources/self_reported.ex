defmodule Platform.Goals.Sources.SelfReported do
  @moduledoc "Values logged by people. The context reads the latest logged reading."
  @behaviour Platform.Goals.Source
  @impl true
  def key, do: "self_reported"
  @impl true
  def label, do: "Self-reported"
  @impl true
  def kind, do: :logged
  @impl true
  def population(_goal), do: {:ok, "self_reported"}
end
