defmodule CodexPooler.Gateway.OpenAICompatibility.AudioTestSupport do
  @moduledoc false

  import Ecto.Query
  import ExUnit.Assertions

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo

  def input_audio_part(format, data) do
    %{
      "type" => "input_audio",
      "input_audio" => %{"data" => data, "format" => format}
    }
  end

  def with_ascii_whitespace(encoded), do: " \t\r\n" <> encoded

  def expected_audio_summary(mime, source) do
    %{
      type: "input_audio",
      mime: mime,
      canonical_whitespace_free?: true,
      decoded_bytes: byte_size(source),
      sha256: :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)
    }
  end

  def safe_audio_part_summary(part) when is_map(part) and map_size(part) == 2 do
    with %{"type" => type, "audio_url" => audio_url} when is_binary(audio_url) <- part,
         ["data:" <> metadata, encoded] <- String.split(audio_url, ",", parts: 2),
         [mime, "base64"] <- String.split(metadata, ";", parts: 2),
         {:ok, decoded} <- Base.decode64(encoded) do
      {:ok,
       %{
         type: type,
         mime: mime,
         canonical_whitespace_free?: encoded == Base.encode64(decoded),
         decoded_bytes: byte_size(decoded),
         sha256: :crypto.hash(:sha256, decoded) |> Base.encode16(case: :lower)
       }}
    else
      _value -> {:error, :unexpected_audio_shape}
    end
  end

  def safe_audio_part_summary(_part), do: {:error, :unexpected_audio_shape}

  def adapter_audio_error(message) do
    %{status: 400, code: "invalid_request", message: message, param: "input"}
  end

  def public_audio_error(message) do
    %{
      "type" => "invalid_request_error",
      "code" => "invalid_request",
      "message" => message,
      "param" => "input"
    }
  end

  def assert_adapter_audio_error!(result, expected) do
    case result do
      {:error, ^expected} -> :ok
      {:error, _reason} -> flunk("expected exact sanitized audio adapter error")
      {:ok, _result} -> flunk("expected audio adapter rejection")
    end
  end

  def assert_captured_audio_summary!(upstream, expected) do
    case FakeUpstream.requests(upstream) do
      [captured] ->
        case captured_audio_summary(captured) do
          {:ok, ^expected} ->
            :ok

          {:ok, _summary} ->
            flunk("captured audio summary did not match expected metadata")

          {:error, :unexpected_audio_shape} ->
            flunk("captured request lacked safe audio metadata")
        end

      _requests ->
        flunk("expected one captured request with safe audio metadata")
    end
  end

  def assert_sanitized_audio_error_response!(response, expected_error, forbidden_values) do
    unless response.status == 400 do
      flunk("expected sanitized audio validation status")
    end

    case Jason.decode(response.resp_body) do
      {:ok, decoded} ->
        unless decoded == %{"error" => expected_error} do
          flunk("expected exact OpenAI-shaped sanitized audio validation error")
        end

      _other ->
        flunk("expected OpenAI-shaped sanitized audio validation error")
    end

    if Enum.any?(forbidden_values, &String.contains?(response.resp_body, &1)) do
      flunk("audio validation response echoed input data")
    end
  end

  def assert_no_audio_side_effects!(upstream) do
    unless FakeUpstream.count(upstream) == 0 do
      flunk("audio validation unexpectedly dispatched upstream")
    end

    unless Repo.aggregate(Request, :count) == 0 do
      flunk("audio validation unexpectedly created a Request row")
    end

    unless Repo.aggregate(Attempt, :count) == 0 do
      flunk("audio validation unexpectedly created an Attempt row")
    end
  end

  def assert_audio_accounting_metadata_only!(pool, protected_values) do
    requests = Repo.all(from(r in Request, where: r.pool_id == ^pool.id))

    if length(requests) != 1 do
      flunk("expected one accounted request")
    end

    request = hd(requests)
    attempts = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))

    if length(attempts) != 1 do
      flunk("expected one accounted attempt")
    end

    attempt = hd(attempts)

    unless request.status == "succeeded" and attempt.status == "succeeded" do
      flunk("expected successful metadata-only accounting")
    end

    persistence_text = inspect({request.request_metadata, attempt.response_metadata})

    if String.contains?(persistence_text, "data:") or
         String.contains?(persistence_text, "audio_url") or
         Enum.any?(protected_values, &String.contains?(persistence_text, &1)) do
      flunk("audio accounting contained raw payload data")
    end
  end

  defp captured_audio_summary(%{json: %{"input" => [%{"content" => content}]}})
       when is_list(content) do
    case Enum.find(content, &match?(%{"type" => "input_audio"}, &1)) do
      nil -> {:error, :unexpected_audio_shape}
      part -> safe_audio_part_summary(part)
    end
  end

  defp captured_audio_summary(_captured), do: {:error, :unexpected_audio_shape}
end
