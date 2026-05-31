defmodule CodexPooler.Gateway.Admission do
  @moduledoc false

  alias CodexPooler.Gateway.Contracts
  alias CodexPooler.Gateway.Transports.Admission, as: TransportAdmission
  alias CodexPooler.RouteClass

  @type gateway_call_result ::
          {:ok, CodexPooler.Gateway.Contracts.gateway_result()}
          | {:error, CodexPooler.Gateway.Contracts.gateway_error()}
  @type admission_lease :: term()

  @spec run_admitted(String.t(), map(), (-> gateway_call_result())) :: gateway_call_result()
  def run_admitted(route_class, metadata, fun)
      when is_binary(route_class) and is_map(metadata) and is_function(fun, 0) do
    case TransportAdmission.acquire(route_class, metadata) do
      {:ok, lease} ->
        lease
        |> run_with_lease(fun)
        |> wrap_admitted_stream_result(lease)

      {:error, reason} ->
        {:error, TransportAdmission.overload_error(reason)}
    end
  end

  @spec admit_browser(map()) :: {:ok, admission_lease()} | {:error, Contracts.gateway_error()}
  def admit_browser(metadata) when is_map(metadata) do
    case TransportAdmission.acquire(RouteClass.admin_browser(), metadata) do
      {:ok, lease} -> {:ok, lease}
      {:error, reason} -> {:error, TransportAdmission.overload_error(reason)}
    end
  end

  @spec admit_mcp(map()) :: {:ok, admission_lease()} | {:error, Contracts.gateway_error()}
  def admit_mcp(metadata) when is_map(metadata) do
    metadata = Map.put(metadata, :route_class, RouteClass.mcp())

    case TransportAdmission.acquire(RouteClass.mcp(), metadata) do
      {:ok, lease} -> {:ok, lease}
      {:error, reason} -> {:error, TransportAdmission.overload_error(reason)}
    end
  end

  @spec release_admission(admission_lease()) :: :ok
  def release_admission(lease), do: TransportAdmission.release(lease)

  defp run_with_lease(lease, fun) do
    fun.()
  catch
    kind, reason ->
      TransportAdmission.release(lease)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp wrap_admitted_stream_result({:ok, %{stream: stream} = result}, lease) do
    wrapped = fn conn ->
      try do
        stream.(conn)
      after
        TransportAdmission.release(lease)
      end
    end

    {:ok, %{result | stream: wrapped}}
  end

  defp wrap_admitted_stream_result(result, lease) do
    TransportAdmission.release(lease)
    result
  end
end
