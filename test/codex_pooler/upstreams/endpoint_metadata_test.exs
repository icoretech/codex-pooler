defmodule CodexPooler.Upstreams.EndpointMetadataTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Upstreams.EndpointMetadata
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  describe "base_url/3" do
    test "prefers assignment metadata before identity metadata and default" do
      identity = identity(%{"base_url" => "https://identity.example.com"})
      assignment = assignment(%{"api_base_url" => "https://assignment.example.com/backend-api"})

      assert EndpointMetadata.base_url(identity, assignment) ==
               "https://assignment.example.com/backend-api"

      assert EndpointMetadata.endpoint_url(identity, assignment, "/backend-api/codex/responses") ==
               {:ok, "https://assignment.example.com/backend-api/codex/responses"}
    end

    test "falls back through identity metadata and caller default" do
      assert EndpointMetadata.base_url(
               identity(%{"upstream_base_url" => "https://identity.example.com"}),
               assignment(%{})
             ) == "https://identity.example.com"

      assert EndpointMetadata.base_url(identity(%{}), assignment(%{}), nil) == nil

      # Without an explicit default the configured provider base URL applies;
      # the test environment points it at a closed local port.
      assert EndpointMetadata.default_base_url() == "http://127.0.0.1:9"

      assert EndpointMetadata.base_url(identity(%{}), assignment(%{})) ==
               EndpointMetadata.default_base_url()

      assert EndpointMetadata.endpoint_url(
               identity(%{}),
               assignment(%{}),
               "/api/codex/usage",
               nil
             ) == {:error, :invalid_upstream_base_url}
    end
  end

  describe "usage_base_url/3" do
    test "keeps usage-specific metadata ahead of generic base url metadata" do
      identity =
        identity(%{
          "usage_base_url" => "https://identity-usage.example.com",
          "base_url" => "https://identity-generic.example.com"
        })

      assignment =
        assignment(%{
          "codex_usage_base_url" => "https://assignment-usage.example.com",
          "base_url" => "https://assignment-generic.example.com"
        })

      assert EndpointMetadata.usage_base_url(identity, assignment) ==
               "https://assignment-usage.example.com"
    end
  end

  test "rejects malformed HTTP bases before a transport can raise" do
    for base <- [
          "not-a-url",
          "   ",
          "https://",
          "ftp://example.com",
          "https://example.com:bad",
          42
        ] do
      assert EndpointMetadata.endpoint_url(
               identity(%{}),
               assignment(%{"base_url" => base}),
               "/backend-api/codex/models"
             ) == {:error, :invalid_upstream_base_url}
    end
  end

  test "retains valid HTTP bases including loopback, IPv6, ports and path prefixes" do
    for base <- ["http://127.0.0.1:4000", "http://[::1]:4000", "https://example.com/prefix"] do
      assert EndpointMetadata.endpoint_url(
               identity(%{}),
               assignment(%{"base_url" => " #{base}/backend-api/ "}),
               "/backend-api/codex/models"
             ) == {:ok, base <> "/backend-api/codex/models"}
    end
  end

  defp identity(metadata), do: %UpstreamIdentity{metadata: metadata}
  defp assignment(metadata), do: %PoolUpstreamAssignment{metadata: metadata}
end
