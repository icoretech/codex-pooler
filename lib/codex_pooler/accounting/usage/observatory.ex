defmodule CodexPooler.Accounting.Usage.Observatory do
  @moduledoc """
  Bounded, API-key-scoped reporting for an authenticated Observatory principal.

  The principal is the authority boundary. Authenticated dashboard principals
  are resolved to canonical records internally; caller-supplied API-key or Pool
  ids are never accepted.
  """

  alias CodexPooler.Access.APIKey
  alias CodexPooler.Access.DashboardSessions.Principal, as: DashboardPrincipal
  alias CodexPooler.Accounting.Usage.Observatory.{Presentation, Principal, Queries}
  alias CodexPooler.Pools.Pool

  @windows %{
    "1h" => %{duration_seconds: 3_600, bucket_seconds: 300, bucket_count: 12},
    "5h" => %{duration_seconds: 18_000, bucket_seconds: 900, bucket_count: 20},
    "24h" => %{duration_seconds: 86_400, bucket_seconds: 3_600, bucket_count: 24},
    "7d" => %{duration_seconds: 604_800, bucket_seconds: 21_600, bucket_count: 28}
  }

  @type error :: %{required(:code) => atom(), required(:message) => String.t()}
  @type identity :: %{required(:api_key_id) => Ecto.UUID.t(), required(:pool_id) => Ecto.UUID.t()}
  @type window :: %{
          required(:key) => String.t(),
          required(:started_at) => DateTime.t(),
          required(:ended_at) => DateTime.t(),
          required(:bucket_seconds) => pos_integer(),
          required(:bucket_count) => pos_integer()
        }

  @type principal :: DashboardPrincipal.t()

  @spec read(principal(), String.t()) :: {:ok, map()} | {:error, error()}
  def read(%DashboardPrincipal{} = principal, window_key),
    do: read(principal, window_key, [])

  def read(_principal, _window_key), do: unauthorized_error()

  @doc false
  @spec read(principal(), String.t(), keyword()) :: {:ok, map()} | {:error, error()}
  def read(%DashboardPrincipal{} = principal, window_key, opts) do
    with :ok <- validate_options(opts),
         {:ok, window} <- normalize_window(window_key, opts),
         {:ok, canonical_principal} <- Principal.load(principal),
         {:ok, identity} <- canonical_identity(canonical_principal) do
      summary = Queries.summary(identity, window)
      buckets = Queries.buckets(identity, window)
      models = Queries.models(identity, window)
      outcomes = Queries.outcomes(identity, window)

      {:ok, Presentation.build(window, summary, buckets, models, outcomes)}
    else
      {:error, :unauthorized} ->
        {:error,
         error(:unauthorized, "Observatory reporting requires an authenticated principal")}

      {:error, _reason} = error ->
        error
    end
  end

  def read(_principal, _window_key, _opts), do: unauthorized_error()

  defp validate_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) -- [:as_of] == [] do
      :ok
    else
      {:error, error(:invalid_input, "Observatory reporting options are invalid")}
    end
  end

  defp validate_options(_opts),
    do: {:error, error(:invalid_input, "Observatory reporting options are invalid")}

  defp normalize_window(window_key, opts) when is_binary(window_key) do
    with {:ok, config} <- Map.fetch(@windows, window_key),
         {:ok, ended_at} <- upper_bound(Keyword.get(opts, :as_of)) do
      {:ok,
       %{
         key: window_key,
         started_at: DateTime.add(ended_at, -config.duration_seconds, :second),
         ended_at: ended_at,
         bucket_seconds: config.bucket_seconds,
         bucket_count: config.bucket_count
       }}
    else
      :error -> {:error, error(:invalid_window, "window must be one of 1h, 5h, 24h, or 7d")}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_window(_window_key, _opts),
    do: {:error, error(:invalid_window, "window must be one of 1h, 5h, 24h, or 7d")}

  defp upper_bound(nil), do: {:ok, DateTime.utc_now() |> DateTime.truncate(:second)}

  defp upper_bound(%DateTime{} = as_of) do
    case DateTime.shift_zone(as_of, "Etc/UTC") do
      {:ok, utc} -> {:ok, DateTime.truncate(utc, :second)}
      {:error, _reason} -> {:error, error(:invalid_input, "as_of must be a UTC datetime")}
    end
  end

  defp upper_bound(_as_of),
    do: {:error, error(:invalid_input, "as_of must be a UTC datetime")}

  defp canonical_identity(%Principal{
         api_key: %APIKey{id: api_key_id, pool_id: pool_id},
         pool: %Pool{id: pool_id}
       })
       when is_binary(api_key_id) and is_binary(pool_id) do
    {:ok, %{api_key_id: api_key_id, pool_id: pool_id}}
  end

  defp canonical_identity(_principal), do: {:error, :unauthorized}

  defp unauthorized_error do
    {:error, error(:unauthorized, "Observatory reporting requires an authenticated principal")}
  end

  defp error(code, message), do: %{code: code, message: message}
end
