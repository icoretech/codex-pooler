alias CodexPooler.Pools.Pool
alias CodexPooler.Repo
alias CodexPooler.Upstreams
alias CodexPooler.Upstreams.Assignments.PoolAssignments
alias CodexPooler.Upstreams.Lifecycle.IdentityLifecycle
alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
alias CodexPooler.Upstreams.Schemas.EncryptedSecret
alias CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment

import Ecto.Query

mode = System.fetch_env!("QUOTA_PROOF_MODE")

unless mode in ["equivalent", "changed-second"] do
  raise "unsupported proof mode"
end

{:ok, _started} = Application.ensure_all_started(:codex_pooler)

account_values = if mode == "equivalent", do: [22, 14, 14], else: [22, 14, 13]
model_values = if mode == "equivalent", do: [22, 1, 1], else: [22, 1, 2]
reset_at = DateTime.utc_now() |> DateTime.add(7_200, :second) |> DateTime.to_unix()
{:ok, responses} = Agent.start_link(fn -> Enum.zip(account_values, model_values) end)

{:ok, listener} =
  :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true, ip: {0, 0, 0, 0}])

{:ok, port} = :inet.port(listener)

server =
  spawn_link(fn ->
    Stream.repeatedly(fn -> :gen_tcp.accept(listener) end)
    |> Enum.reduce_while(:ok, fn
      {:ok, socket}, :ok ->
        {:ok, request} = :gen_tcp.recv(socket, 0, 5_000)
        [request_line | _headers] = String.split(request, "\r\n")
        [_method, path, _version] = String.split(request_line, " ")

        result =
          Agent.get_and_update(responses, fn
            [{account, model} | remaining] -> {{account, model}, remaining}
            [] -> {:exhausted, []}
          end)

        case {path, result} do
          {"/backend-api/wham/usage", {account, model}} ->
            payload = %{
              "rate_limit" => %{
                "primary_window" => %{
                  "used_percent" => account,
                  "limit_window_seconds" => 18_000,
                  "reset_at" => reset_at
                }
              },
              "additional_rate_limits" => [
                %{
                  "limit_name" => "Example Model",
                  "metered_feature" => "example_model",
                  "rate_limit" => %{
                    "primary_window" => %{
                      "used_percent" => model,
                      "limit_window_seconds" => 18_000,
                      "reset_at" => reset_at
                    }
                  }
                }
              ]
            }

            body = Jason.encode!(payload)

            :ok =
              :gen_tcp.send(
                socket,
                "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n" <>
                  "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"
              )

            :gen_tcp.close(socket)
            {:cont, :ok}

          {_path, _result} ->
            body = Jason.encode!(%{"error" => "unexpected proof request"})

            :ok =
              :gen_tcp.send(
                socket,
                "HTTP/1.1 500 Internal Server Error\r\ncontent-type: application/json\r\n" <>
                  "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"
              )

            :gen_tcp.close(socket)
            {:halt, :unexpected_request}
        end

      {:error, :closed}, :ok ->
        {:halt, :ok}
    end)
  end)

now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
suffix = System.unique_integer([:positive])

pool =
  %Pool{}
  |> Pool.changeset(%{
    slug: "quota-proof-#{suffix}",
    name: "Quota proof",
    status: "active",
    created_at: now,
    updated_at: now
  })
  |> Repo.insert!()

{:ok, identity} =
  IdentityLifecycle.create_upstream_identity(%{
    chatgpt_account_id: "quota-proof-#{suffix}",
    account_label: "Quota proof",
    onboarding_method: "import",
    metadata: %{"base_url" => "http://127.0.0.1:#{port}"}
  })

{:ok, identity} = IdentityLifecycle.activate_upstream_identity(identity)
{:ok, assignment} = PoolAssignments.create_pool_assignment(pool, identity)
{:ok, assignment} = PoolAssignments.activate_pool_assignment(assignment)

{:ok, _secret} =
  Upstreams.store_encrypted_secret(identity, %{
    secret_kind: "access_token",
    plaintext: "quota-proof-synthetic-credential"
  })

metadata_fields =
  "quota_scope,quota_family,quota_key,window_kind,source,source_precision," <>
    "freshness_state,observed_at,reset_at,used_percent"

window_percent = fn scope ->
  identity
  |> QuotaWindows.list_quota_windows()
  |> Enum.find(&(&1.quota_scope == scope))
  |> Map.fetch!(:used_percent)
  |> Decimal.to_string(:normal)
end

try do
  snapshots =
    Enum.map(1..3, fn _index ->
      {:ok, %{status: :succeeded}} = Upstreams.reconcile_pool_account(pool, assignment)
      {window_percent.("account"), window_percent.("model")}
    end)

  Enum.each([{"account", 0}, {"model", 1}], fn {scope, index} ->
    values = Enum.map(snapshots, &(&1 |> elem(index)))
    initial = if scope == "account", do: "22", else: "22"

    expected =
      if mode == "equivalent", do: if(scope == "account", do: "14", else: "1"), else: initial

    [first, second, third] = values

    passed =
      Decimal.equal?(Decimal.new(first), Decimal.new(initial)) and
        Decimal.equal?(Decimal.new(second), Decimal.new(initial)) and
        Decimal.equal?(Decimal.new(third), Decimal.new(expected))

    IO.puts(
      Enum.join(
        [
          "transition",
          mode,
          scope,
          first,
          second,
          third,
          if(passed, do: "passed", else: "failed")
        ],
        "\t"
      )
    )
  end)

  rows =
    Repo.query!(
      """
      SELECT quota_scope, quota_family, quota_key, window_kind, source,
             source_precision, freshness_state, observed_at, reset_at, used_percent::text
      FROM account_quota_windows
      WHERE upstream_identity_id::text = $1
      ORDER BY quota_scope
      """,
      [identity.id]
    ).rows

  unless length(rows) == 2, do: raise("metadata projection row count mismatch")

  Enum.each(rows, fn [
                       scope,
                       family,
                       key,
                       kind,
                       source,
                       precision,
                       freshness,
                       observed,
                       reset,
                       percent
                     ] ->
    IO.puts(
      Enum.join(
        [
          "row",
          scope,
          family,
          key,
          kind,
          source,
          precision,
          freshness,
          DateTime.to_iso8601(observed),
          DateTime.to_iso8601(reset),
          percent
        ],
        "\t"
      )
    )
  end)

  unless Agent.get(responses, & &1) == [],
    do: raise("synthetic provider responses were not exhausted")

  IO.puts("projection\t#{metadata_fields}\tpassed")
after
  :gen_tcp.close(listener)
  Process.exit(server, :normal)
  Agent.stop(responses)

  Repo.delete_all(
    from secret in EncryptedSecret, where: secret.upstream_identity_id == ^identity.id
  )

  Repo.delete_all(
    from assignment in PoolUpstreamAssignment, where: assignment.id == ^assignment.id
  )

  Repo.delete_all(
    from window in CodexPooler.Upstreams.Quota.AccountQuotaWindow,
      where: window.upstream_identity_id == ^identity.id
  )

  Repo.delete!(identity)
  Repo.delete!(pool)
  IO.puts("cleanup\tproof-fixture\tpassed")
end
