defmodule CodexPooler.Upstreams.Auth.AccessTokenExpiry do
  @moduledoc false

  alias CodexPooler.Upstreams.Auth.JwtPayload

  @type source :: :jwt_exp | :explicit | :expires_in | :unavailable
  @type state :: :known | :expired | :unknown
  @type resolution :: %{
          required(:state) => :known | :unknown,
          required(:source) => source(),
          required(:deadline) => DateTime.t() | nil
        }
  @type evaluation :: %{
          required(:state) => state(),
          required(:source) => source(),
          required(:deadline) => DateTime.t() | nil
        }

  @spec resolve(term()) :: resolution()
  def resolve(attrs) when is_map(attrs) do
    with :error <- jwt_deadline(value(attrs, :access_token)),
         :error <- explicit_deadline(explicit_expiry(attrs)),
         :error <- lifetime_deadline(value(attrs, :expires_in), value(attrs, :received_at)) do
      unknown()
    else
      {:ok, deadline, source} -> known(deadline, source)
    end
  end

  def resolve(_attrs), do: unknown()

  @spec evaluate(resolution(), DateTime.t()) :: evaluation()
  def evaluate(
        %{state: :known, source: source, deadline: %DateTime{} = deadline},
        %DateTime{} = at
      )
      when source in [:jwt_exp, :explicit, :expires_in] do
    if DateTime.compare(deadline, at) == :gt do
      known(deadline, source)
    else
      %{state: :expired, source: source, deadline: deadline}
    end
  end

  def evaluate(_resolution, _evaluated_at), do: unknown()

  @spec known(DateTime.t(), :jwt_exp | :explicit | :expires_in) :: resolution()
  def known(%DateTime{} = deadline, source) when source in [:jwt_exp, :explicit, :expires_in] do
    %{state: :known, source: source, deadline: normalize_datetime(deadline)}
  end

  @spec unknown() :: resolution()
  def unknown, do: %{state: :unknown, source: :unavailable, deadline: nil}

  @spec parse_datetime(term()) :: {:ok, DateTime.t()} | :error
  def parse_datetime(%DateTime{} = datetime), do: {:ok, normalize_datetime(datetime)}

  def parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, normalize_datetime(datetime)}
      {:error, _reason} -> :error
    end
  end

  def parse_datetime(_value), do: :error

  defp jwt_deadline(token) do
    with {:ok, claims} <- JwtPayload.decode(token),
         {:ok, deadline} <- unix_deadline(Map.get(claims, "exp")) do
      {:ok, deadline, :jwt_exp}
    else
      _invalid -> :error
    end
  end

  defp explicit_deadline(value) do
    case parse_datetime(value) do
      {:ok, deadline} -> {:ok, deadline, :explicit}
      :error -> :error
    end
  end

  defp lifetime_deadline(expires_in, %DateTime{} = received_at) do
    with {:ok, seconds} <- positive_integer(expires_in),
         {:ok, deadline} <- DateTime.from_unix(DateTime.to_unix(received_at, :second) + seconds) do
      {:ok, normalize_datetime(deadline), :expires_in}
    else
      _invalid -> :error
    end
  end

  defp lifetime_deadline(_expires_in, _received_at), do: :error

  defp unix_deadline(value) do
    with {:ok, seconds} <- integer(value),
         {:ok, deadline} <- DateTime.from_unix(seconds) do
      {:ok, normalize_datetime(deadline)}
    else
      _invalid -> :error
    end
  end

  defp positive_integer(value) do
    case integer(value) do
      {:ok, integer} when integer > 0 -> {:ok, integer}
      _invalid -> :error
    end
  end

  defp integer(value) when is_integer(value), do: {:ok, value}

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> {:ok, integer}
      _invalid -> :error
    end
  end

  defp integer(_value), do: :error

  defp value(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> value
      :error -> Map.get(attrs, Atom.to_string(key))
    end
  end

  defp explicit_expiry(attrs) do
    value(attrs, :explicit_expires_at) || value(attrs, :access_token_expires_at)
  end

  defp normalize_datetime(datetime) do
    datetime
    |> DateTime.shift_zone!("Etc/UTC")
    |> DateTime.truncate(:microsecond)
  end
end
