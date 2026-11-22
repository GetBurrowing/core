defmodule PlatformWeb.SocialRetryTime do
  @moduledoc false

  def parse(value) when is_binary(value) do
    value = if byte_size(value) == 16, do: value <> ":00", else: value

    with {:ok, naive} <- NaiveDateTime.from_iso8601(value),
         {:ok, at} <- DateTime.from_naive(naive, "Etc/UTC"),
         :gt <- DateTime.compare(at, DateTime.utc_now()) do
      {microsecond, _precision} = at.microsecond
      {:ok, %{at | microsecond: {microsecond, 6}}}
    else
      _ -> {:error, :invalid_retry_time}
    end
  end

  def parse(_), do: {:error, :invalid_retry_time}

  # Present on every newly rendered action, including the no-job branch.
  # This is an optimistic expectation, never authority or an adapter target.
  def expected_job(%{"expected_job" => id}) when is_binary(id),
    do: {:ok, if(id == "", do: nil, else: id)}

  def expected_job(_), do: {:error, :publish_job_changed}

  def prefill(%DateTime{} = at) do
    if DateTime.compare(at, DateTime.utc_now()) == :gt,
      do: Calendar.strftime(at, "%Y-%m-%dT%H:%M:%S"),
      else: ""
  end

  def prefill(_), do: ""
end
