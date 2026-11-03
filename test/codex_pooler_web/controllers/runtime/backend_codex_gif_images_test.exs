defmodule CodexPoolerWeb.Runtime.BackendCodexGifImagesTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport, only: [model_serving_scope: 0, set_model_serving_mode!: 3]

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.{FakeUpstream, Pools, Repo}

  @image_model "gpt-image-2"
  @prompt "synthetic animated image contract"
  @png_base64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
  @image_url "data:image/png;base64," <> @png_base64
  # Two 1x1 frames, black then white, each displayed for 20 ms and looping.
  @gif_base64 "R0lGODlhAQABAIEAAAAAAAAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQAAgAAACwAAAAAAQABAAAIBAABBAQAIfkEAQIAAQAsAAAAAAEAAQCB////AAAAAAAAAAAACAQAAQQEADs="

  for action <- ["generations", "edits"],
      mode <- ["full", "lite"],
      {controls_name, controls} <- [
        {"API defaults", %{}},
        {"both controls", %{"frame_count" => 2, "frame_duration_ms" => 20}},
        {"frame count only", %{"frame_count" => 16}},
        {"frame duration only", %{"frame_duration_ms" => 2000}}
      ] do
    @scenario {action, mode, controls}
    test("#{mode} native GIF #{action} preserves #{controls_name} and animated output", %{conn: conn}, do: assert_gif_contract(conn, @scenario))
  end

  for action <- ["generations", "edits"] do
    @action action
    test("native GIF #{action} requires authentication before dispatch or reservation", %{conn: conn}, do: assert_gif_refusal(conn, @action, :unauthenticated))
    test("native GIF #{action} respects the Pool image policy before dispatch or reservation", %{conn: conn}, do: assert_gif_refusal(conn, @action, :image_disabled))
  end

  defp assert_gif_contract(conn, {action, mode, controls}) do
    expected = %{
      "created" => 1_717_171_717,
      "data" => [%{"b64_json" => @gif_base64, "generation_id" => "synthetic-gif-generation"}],
      "output_format" => "gif",
      "usage" => %{"input_tokens" => 17, "output_tokens" => 23, "total_tokens" => 40}
    }

    upstream = start_upstream(FakeUpstream.json_response(expected))
    setup = gateway_setup(upstream)
    set_model_serving_mode!(model_serving_scope(), setup, mode)
    path = "/backend-api/codex/images/#{action}"
    payload = Map.merge(image_payload(action), controls)

    response = conn |> auth(setup) |> put_req_header("content-type", "application/json") |> post(path, payload)

    assert response.status == 200
    returned = Jason.decode!(response.resp_body)
    assert digest(returned) == digest(expected)
    encoded = get_in(returned, ["data", Access.at(0), "b64_json"])
    assert digest(Base.decode64!(encoded)) == digest(Base.decode64!(@gif_base64))
    assert FakeUpstream.count(upstream) == 1
    captured = upstream |> FakeUpstream.requests() |> hd()
    assert captured.method == "POST"
    assert captured.path == path
    assert digest(captured.json) == digest(payload)
    refute Map.has_key?(captured.json, "n")
    refute Map.has_key?(captured.json, "gif")

    for key <- ["frame_count", "frame_duration_ms"] do
      assert Map.has_key?(captured.json, key) == Map.has_key?(controls, key)
    end

    assert_image_accounting(setup, path, mode)
  end

  defp assert_gif_refusal(conn, action, refusal) do
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)

    {conn, status, error_code} =
      case refusal do
        :unauthenticated ->
          {conn, 401, "api_key_missing"}

        :image_disabled ->
          setup.pool |> Pools.ensure_routing_settings() |> Ecto.Changeset.change(allow_image_generation: false) |> Repo.update!()
          {auth(conn, setup), 403, "image_generation_disabled"}
      end

    response = conn |> put_req_header("content-type", "application/json") |> post("/backend-api/codex/images/#{action}", image_payload(action))

    assert response.status == status
    assert get_in(Jason.decode!(response.resp_body), ["error", "code"]) == error_code
    assert FakeUpstream.count(upstream) == 0
    request_ids = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id, select: r.id))
    assert Repo.aggregate(from(a in Attempt, where: a.request_id in ^request_ids), :count) == 0
    assert Repo.aggregate(from(l in LedgerEntry, where: l.pool_id == ^setup.pool.id), :count) == 0
  end

  defp image_payload(action) do
    payload = %{"model" => @image_model, "prompt" => @prompt, "output_format" => "gif", "background" => "auto", "quality" => "auto", "size" => "auto"}

    case action do
      "generations" -> payload
      "edits" -> Map.put(payload, "images", [%{"image_url" => @image_url}])
    end
  end

  defp assert_image_accounting(setup, path, mode) do
    requests = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert length(requests) == 1
    request = hd(requests)
    assert request.endpoint == path
    assert request.status == "succeeded"
    assert request.response_status_code == 200
    assert request.transport == "http_json"
    assert request.model_id == setup.model.id
    assert request.requested_model == @image_model
    assert request.request_metadata["requested_model"] == @image_model
    assert request.request_metadata["effective_model"] == @image_model
    attempts = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert length(attempts) == 1
    attempt = hd(attempts)
    assert attempt.attempt_number == 1
    assert attempt.status == "succeeded"
    assert attempt.response_metadata["routing"]["model_serving_mode"] == mode
    assert attempt.upstream_status_code == 200
    assert attempt.pool_upstream_assignment_id == setup.assignment.id
    assert attempt.upstream_identity_id == setup.identity.id
    assert attempt.model_id == setup.model.id
    settlements = Repo.all(from(l in LedgerEntry, where: l.request_id == ^request.id and l.entry_kind == "settlement"))
    assert length(settlements) == 1
    settlement = hd(settlements)
    assert settlement.model_id == setup.model.id
    assert settlement.attempt_id == attempt.id
    assert settlement.request_count == 1
    metadata = Jason.encode!([request.request_metadata, attempt.response_metadata, settlement.details])

    for value <- [@prompt, @image_url, @png_base64, @gif_base64, Base.decode64!(@png_base64), Base.decode64!(@gif_base64)] do
      assert :binary.match(metadata, value) == :nomatch
    end
  end

  defp digest(value), do: :crypto.hash(:sha256, :erlang.term_to_binary(value))
end
