defmodule CodexPooler.Jobs.FailureLogTest do
  use CodexPooler.DataCase, async: false

  import ExUnit.CaptureLog

  # findings#206 row 206-90: Oban prunes finished jobs after a day and the job
  # roles export no metrics, so a failed or discarded job must leave a bounded
  # warning line. The workers run through Oban.Testing.perform_job/3, which
  # drives Oban's real executor and its job telemetry; the handler under test
  # is the one the application attaches at boot.

  defmodule ErrorWorker do
    use Oban.Worker, queue: :jobs, max_attempts: 3

    @impl Oban.Worker
    def timeout(_job), do: :timer.seconds(5)

    @impl Oban.Worker
    def perform(%Oban.Job{args: %{"mode" => "error"}}), do: {:error, {:upstream_unavailable, "sk-live-secret-in-reason"}}
    def perform(%Oban.Job{args: %{"mode" => "string"}}), do: {:error, "failure text with sk-live-secret-in-reason"}
    def perform(%Oban.Job{args: %{"mode" => "raise"}}), do: raise("boom with sk-live-secret-in-message")
    def perform(%Oban.Job{args: %{"mode" => "discard"}}), do: {:discard, :account_deleted}
    def perform(%Oban.Job{args: %{"mode" => "cancel"}}), do: {:cancel, :no_longer_needed}
    def perform(%Oban.Job{args: %{"mode" => "ok"}}), do: :ok
  end

  @secret_arg "sk-live-secret-in-args"

  test "a returned error logs one bounded warning without args or the returned term" do
    log = capture_log(fn -> assert {:error, _} = perform(%{"mode" => "error"}, attempt: 1) end)

    assert [line] = failure_lines(log)
    assert line =~ "oban job failed worker=CodexPooler.Jobs.FailureLogTest.ErrorWorker queue=jobs"
    assert line =~ "attempt=1 max_attempts=3 kind=error error=Oban.PerformError reason=upstream_unavailable duration_ms="
    assert line =~ ~r/job_id=\d+ /
    refute log =~ @secret_arg
    refute log =~ "sk-live-secret-in-reason"
  end

  test "the last attempt of a failing job logs as discarded" do
    log = capture_log(fn -> assert {:error, _} = perform(%{"mode" => "error"}, attempt: 3) end)

    assert [line] = failure_lines(log)
    assert line =~ "oban job discarded worker=CodexPooler.Jobs.FailureLogTest.ErrorWorker"
    assert line =~ "attempt=3 max_attempts=3 kind=error error=Oban.PerformError reason=upstream_unavailable"
  end

  test "a raised exception logs its class, never its message; a returned string is not a reason code" do
    raised =
      capture_log(fn ->
        assert_raise RuntimeError, fn -> perform(%{"mode" => "raise"}, attempt: 1) end
      end)

    assert [line] = failure_lines(raised)
    assert line =~ "oban job failed" and line =~ "kind=error error=RuntimeError duration_ms="
    refute line =~ "reason="
    refute raised =~ "sk-live-secret-in-message"

    string = capture_log(fn -> assert {:error, _} = perform(%{"mode" => "string"}, attempt: 1) end)
    assert [string_line] = failure_lines(string)
    assert string_line =~ "error=Oban.PerformError duration_ms="
    refute string =~ "sk-live-secret-in-reason"
  end

  test "an explicit discard logs; a cancel and a success do not" do
    log =
      capture_log(fn ->
        assert {:discard, :account_deleted} = perform(%{"mode" => "discard"}, attempt: 1)
        assert {:cancel, :no_longer_needed} = perform(%{"mode" => "cancel"}, attempt: 1)
        assert :ok = perform(%{"mode" => "ok"}, attempt: 1)
      end)

    assert [line] = failure_lines(log)
    assert line =~ "oban job discarded worker=CodexPooler.Jobs.FailureLogTest.ErrorWorker"
    assert line =~ "reason=account_deleted"
    refute log =~ @secret_arg
  end

  defp perform(args, opts) do
    perform_job(ErrorWorker, Map.put(args, "token", @secret_arg), opts)
  end

  defp failure_lines(log) do
    log
    |> String.split("\n")
    |> Enum.filter(&(&1 =~ ~r/oban job (failed|discarded) worker=CodexPooler\.Jobs\.FailureLogTest\./))
  end
end
