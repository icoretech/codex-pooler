defmodule CodexPooler.Gateway.Facade.Ollama.Catalog do
  @moduledoc """
  Stable local Ollama discovery contract for the immutable facade model.
  """

  alias CodexPooler.Access
  alias CodexPooler.Gateway.Facade
  alias CodexPooler.Gateway.Facade.Catalog, as: FacadeCatalog

  @contract_version "0.1.0"
  @contract_timestamp "2026-08-11T00:00:00Z"
  @capabilities ["completion", "tools", "vision", "thinking"]

  @type resolution :: FacadeCatalog.resolution()

  @spec resolve(map()) :: {:ok, resolution()} | {:error, map()}
  def resolve(auth) when is_map(auth) do
    case Access.normalize_api_key_policy(auth.api_key) do
      {:ok, policy} ->
        {:ok, FacadeCatalog.resolve(auth, policy)}

      {:error, _reason} ->
        {:error,
         %{
           status: 403,
           code: "facade_policy_conflict",
           message: "Request denied by local Pool policy"
         }}
    end
  end

  @spec tags_body(resolution()) :: map()
  def tags_body(%{available?: true}), do: %{"models" => [tag_entry()]}
  def tags_body(%{available?: false}), do: %{"models" => []}

  @spec ps_body(resolution()) :: map()
  def ps_body(%{available?: true}) do
    %{
      "models" => [
        tag_entry()
        |> Map.put("expires_at", @contract_timestamp)
        |> Map.put("size_vram", 0)
      ]
    }
  end

  def ps_body(%{available?: false}), do: %{"models" => []}

  @spec show_body(resolution()) :: map() | nil
  def show_body(%{available?: true}) do
    %{
      "model" => Facade.public_model(),
      "modified_at" => @contract_timestamp,
      "digest" => contract_digest(),
      "license" => "virtual",
      "modelfile" => "",
      "parameters" => "",
      "template" => "",
      "details" => details(),
      "model_info" => %{
        "general.architecture" => Facade.public_model(),
        "general.parameter_count" => 0
      },
      "capabilities" => @capabilities
    }
  end

  def show_body(%{available?: false}), do: nil

  @spec version_body() :: map()
  def version_body, do: %{"version" => @contract_version}

  @spec contract_digest() :: String.t()
  def contract_digest do
    public_contract =
      Enum.join(
        [
          "ollama-facade",
          @contract_version,
          Facade.public_model(),
          @contract_timestamp,
          Enum.join(@capabilities, ",")
        ],
        "|"
      )

    "sha256:" <> (:crypto.hash(:sha256, public_contract) |> Base.encode16(case: :lower))
  end

  defp tag_entry do
    %{
      "name" => Facade.public_model(),
      "model" => Facade.public_model(),
      "modified_at" => @contract_timestamp,
      "size" => 0,
      "digest" => contract_digest(),
      "details" => details()
    }
  end

  defp details do
    %{"family" => Facade.public_model(), "parameter_size" => "virtual"}
  end
end
