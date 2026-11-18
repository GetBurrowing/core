defmodule Platform.Social.Trends.Wikimedia do
  @moduledoc "Parses Wikimedia's daily English Wikipedia pageview ranking."

  @source "wikimedia_pageviews"
  @namespaces ~w(special wikipedia portal file image help category template talk user mediawiki draft module book timedtext project wp wt)

  def fetch(%Date{} = date, %DateTime{} = observed_at, limit, opts) do
    contact = Keyword.get(opts, :contact)

    if is_binary(contact) and String.valid?(contact) and String.trim(contact) != "" and
         byte_size(contact) <= 300 and not String.contains?(contact, ["\r", "\n", <<0>>]) do
      url =
        "https://wikimedia.org/api/rest_v1/metrics/pageviews/top/en.wikipedia/all-access/" <>
          Calendar.strftime(date, "%Y/%m/%d")

      req = Req.new(Keyword.get(opts, :req_options, []))

      bounded_body = fn {:data, data}, {request, response} ->
        body = if is_binary(response.body), do: response.body, else: ""

        if byte_size(body) + byte_size(data) > 1_000_000 do
          {:halt, {request, %{response | body: :too_large}}}
        else
          {:cont, {request, %{response | body: body <> data}}}
        end
      end

      timeout = Keyword.get(opts, :timeout_ms, 10_000)

      task =
        Task.async(fn ->
          try do
            Req.get(req,
              url: url,
              headers: [{"user-agent", "BurrowSocialTrendsBot/1.0 (#{contact})"}],
              receive_timeout: timeout,
              request_timeout: timeout,
              retry: false,
              redirect: false,
              compressed: false,
              decode_body: false,
              into: bounded_body
            )
          rescue
            _ -> {:error, :request_failed}
          end
        end)

      result =
        case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
          {:ok, response} -> response
          _ -> {:error, :deadline}
        end

      case result do
        {:ok, %{status: status, headers: headers}} when status in [429, 503] ->
          {:error, {:throttled, Map.get(headers, "retry-after", [])}}

        {:ok, %{body: :too_large}} ->
          {:error, :response_too_large}

        {:ok, %{status: 200, body: body}} ->
          case Jason.decode(body) do
            {:ok, decoded} -> parse_response(decoded, date, observed_at, limit)
            _ -> {:error, :invalid_response}
          end

        {:ok, %{status: 404}} ->
          {:error, :not_yet_available}

        {:ok, %{status: status}} ->
          {:error, {:http, status}}

        {:error, _} ->
          {:error, :unavailable}
      end
    else
      {:error, :missing_contact}
    end
  end

  def parse_response(%{"items" => [entry]}, %Date{} = date, %DateTime{} = observed_at, limit)
      when is_map(entry) and is_integer(limit) and limit in 1..100 do
    expected = %{
      "project" => "en.wikipedia",
      "access" => "all-access",
      "year" => Calendar.strftime(date, "%Y"),
      "month" => Calendar.strftime(date, "%m"),
      "day" => Calendar.strftime(date, "%d")
    }

    articles = entry["articles"]

    if Enum.all?(expected, fn {k, v} -> entry[k] == v end) and
         is_list(articles) and length(articles) == 1000 and valid_articles?(articles) do
      items =
        articles
        |> Enum.reject(&excluded?(&1["article"]))
        |> Enum.take(limit)
        |> Enum.map(fn item ->
          id = item["article"]

          %{
            id: id,
            rank: item["rank"],
            title: String.replace(id, "_", " "),
            url: "https://en.wikipedia.org/wiki/" <> URI.encode(id, &URI.char_unreserved?/1),
            pageviews: item["views"]
          }
        end)

      if length(items) == limit do
        {:ok,
         %{
           source: @source,
           limit: limit,
           complete: true,
           reporting_date: date,
           observed_at: observed_at,
           items: items
         }}
      else
        {:error, :invalid_response}
      end
    else
      {:error, :invalid_response}
    end
  end

  def parse_response(_, _, _, _), do: {:error, :invalid_response}

  defp valid_articles?(articles) do
    Enum.with_index(articles, 1)
    |> Enum.all?(fn
      {%{"article" => name, "rank" => rank, "views" => views}, expected}
      when is_binary(name) and is_integer(views) and views >= 0 ->
        String.valid?(name) and byte_size(name) in 1..255 and not String.contains?(name, <<0>>) and
          is_integer(rank) and rank > 0 and rank <= expected

      _ ->
        false
    end) and Enum.map(articles, & &1["rank"]) == Enum.sort(Enum.map(articles, & &1["rank"])) and
      length(Enum.uniq_by(articles, & &1["article"])) == length(articles)
  end

  defp excluded?("Main_Page"), do: true
  defp excluded?("-"), do: true

  defp excluded?(name) do
    case String.split(name, ":", parts: 2) do
      [prefix, _] ->
        normalized = prefix |> String.replace("_", " ") |> String.downcase()
        base = String.replace_suffix(normalized, " talk", "")
        normalized in @namespaces or (base != normalized and base in @namespaces)

      _ ->
        false
    end
  end
end
