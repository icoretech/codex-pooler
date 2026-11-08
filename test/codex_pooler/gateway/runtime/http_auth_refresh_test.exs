defmodule CodexPooler.Gateway.Runtime.HttpAuthRefreshTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Runtime.Dispatch.HttpAuthRefresh
  alias CodexPooler.Gateway.Transports.RejectionBody

  describe "auth_failure?/1" do
    test "ordinary 401 responses remain refreshable regardless of body shape" do
      assert HttpAuthRefresh.auth_failure?(response(401, ""))
      assert HttpAuthRefresh.auth_failure?(response(401, "not json"))
      assert HttpAuthRefresh.auth_failure?(response(401, error_body("unauthorized")))
    end

    test "403 is an auth failure only with an auth-refresh body code" do
      assert HttpAuthRefresh.auth_failure?(response(403, error_body("invalid_api_key")))
      assert HttpAuthRefresh.auth_failure?(response(403, error_body("invalid_authentication")))
      refute HttpAuthRefresh.auth_failure?(response(403, error_body("insufficient_quota")))
      refute HttpAuthRefresh.auth_failure?(response(403, ""))
      refute HttpAuthRefresh.auth_failure?(response(403, "not json"))
    end

    test "a drained streaming rejection body is honored" do
      drained = RejectionBody.put(response(403, ""), error_body("invalid_api_key"))
      assert HttpAuthRefresh.auth_failure?(drained)
    end

    for code <- ~w(runtime_assertion_invalid runtime_instance_paused runtime_instance_revoked invalid_agent_instance_assertion), status <- [401, 403] do
      test "#{status} #{code} in the body prevents credential refresh" do
        refute HttpAuthRefresh.auth_failure?(response(unquote(status), error_body(unquote(code))))
        drained = RejectionBody.put(response(unquote(status), error_body("invalid_api_key")), error_body(unquote(code)))
        refute HttpAuthRefresh.auth_failure?(drained)
      end

      test "#{status} #{code} in x-error-json overrides a credential body" do
        response = response(unquote(status), error_body("invalid_api_key")) |> Req.Response.put_header("x-error-json", Base.encode64(error_body(unquote(code))))
        refute HttpAuthRefresh.auth_failure?(response)
      end
    end

    test "unavailable verification and unknown runtime codes keep ordinary credential handling" do
      for code <- ["runtime_verification_unavailable", "runtime_assertion_invalid_extra", "token_expired"] do
        for status <- [401, 403] do
          response = response(status, error_body("invalid_authentication")) |> Req.Response.put_header("x-error-json", Base.encode64(error_body(code)))
          assert HttpAuthRefresh.auth_failure?(response)
        end

        assert HttpAuthRefresh.auth_failure?(response(401, error_body(code)))
        refute HttpAuthRefresh.auth_failure?(response(403, error_body(code)))
      end
    end

    test "malformed and oversized identity headers do not suppress ordinary refresh" do
      terminal = error_body("runtime_instance_revoked")

      for header <- ["not base64!", Base.encode64("not json"), Base.encode64("null"), Base.encode64(CodexPooler.JSON.encode!(%{"error" => %{"code" => ["runtime_instance_revoked"]}})), Base.encode64(terminal <> String.duplicate(" ", 8_192))] do
        response = response(401, error_body("invalid_api_key")) |> Req.Response.put_header("x-error-json", header)
        assert HttpAuthRefresh.auth_failure?(response)
      end
    end

    test "literal and URL-safe headers do not match standard base64 identity errors" do
      body = CodexPooler.JSON.encode!(%{"error" => %{"code" => "runtime_assertion_invalid"}, "padding" => "???"})
      standard = Base.encode64(body)
      url_safe = Base.url_encode64(body)
      refute standard == url_safe
      response = response(401, error_body("invalid_api_key"))
      refute HttpAuthRefresh.auth_failure?(Req.Response.put_header(response, "x-error-json", standard))

      for header <- ["runtime_assertion_invalid", body, url_safe] do
        assert HttpAuthRefresh.auth_failure?(Req.Response.put_header(response, "x-error-json", header))
      end
    end

    test "only the exact nested error code is a runtime denial" do
      for body <- [%{"code" => "runtime_assertion_invalid"}, %{"error" => %{"type" => "runtime_assertion_invalid"}}, %{"error" => %{"message" => "runtime_assertion_invalid"}}, %{"error" => [%{"code" => "runtime_assertion_invalid"}]}] do
        json = CodexPooler.JSON.encode!(body)
        assert HttpAuthRefresh.auth_failure?(response(401, json))
        response = response(403, error_body("invalid_authentication")) |> Req.Response.put_header("x-error-json", Base.encode64(json))
        assert HttpAuthRefresh.auth_failure?(response)
      end
    end

    test "nonzero base64 padding bits are malformed and cannot suppress refresh" do
      encoded = Base.encode64(CodexPooler.JSON.encode!(%{"error" => %{"code" => "runtime_assertion_invalid"}}))
      assert String.ends_with?(encoded, "fQ==")
      malformed = String.replace_suffix(encoded, "fQ==", "fR==")
      response = response(401, error_body("invalid_api_key")) |> Req.Response.put_header("x-error-json", malformed)
      assert HttpAuthRefresh.auth_failure?(response)
    end

    test "a terminal body remains authoritative when the identity header is malformed or ordinary" do
      for header <- ["not base64!", Base.encode64(error_body("token_expired"))] do
        response = response(401, error_body("runtime_instance_paused")) |> Req.Response.put_header("x-error-json", header)
        refute HttpAuthRefresh.auth_failure?(response)
      end
    end

    test "the identity header byte limit is inclusive" do
      body = error_body("runtime_instance_paused")
      header = Base.encode64(body <> String.duplicate(" ", 6_144 - byte_size(body)))
      assert byte_size(header) == 8_192
      response = response(401, error_body("invalid_api_key"))
      refute HttpAuthRefresh.auth_failure?(Req.Response.put_header(response, "x-error-json", header))
      assert HttpAuthRefresh.auth_failure?(Req.Response.put_header(response, "x-error-json", header <> "AAAA"))
    end

    test "the materialized and drained body byte limit is inclusive" do
      body = error_body("runtime_instance_revoked")
      bounded = body <> String.duplicate(" ", 65_536 - byte_size(body))
      refute HttpAuthRefresh.auth_failure?(response(401, bounded))
      refute HttpAuthRefresh.auth_failure?(RejectionBody.put(response(401, ""), bounded))
      assert HttpAuthRefresh.auth_failure?(response(401, bounded <> " "))
      assert HttpAuthRefresh.auth_failure?(RejectionBody.put(response(401, ""), bounded <> " "))
    end

    test "a non-string body code does not suppress credential refresh" do
      assert HttpAuthRefresh.auth_failure?(response(401, CodexPooler.JSON.encode!(%{"error" => %{"code" => ["runtime_instance_revoked"]}})))
    end

    test "other statuses never refresh" do
      refute HttpAuthRefresh.auth_failure?(response(400, error_body("invalid_api_key")))
      refute HttpAuthRefresh.auth_failure?(response(429, error_body("invalid_api_key")))
      refute HttpAuthRefresh.auth_failure?(response(200, ""))
    end
  end

  defp response(status, body), do: %Req.Response{status: status, body: body}

  defp error_body(code) do
    CodexPooler.JSON.encode!(%{"error" => %{"code" => code, "message" => "sentinel"}})
  end
end
