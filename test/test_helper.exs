native_turn_console_filter = :codex_pooler_test_native_turn_console_filter

# This filter belongs only to Logger's default console handler. ExUnit's
# separate CaptureLog handler still receives these expected native-turn events.
:ok =
  :logger.add_handler_filter(
    :default,
    native_turn_console_filter,
    {fn
       %{msg: {:string, "websocket native turn failed" <> _rest}}, _extra -> :stop
       log_event, _extra -> log_event
     end, nil}
  )

# Most waits in this suite observe a signal from another process, and the four
# CI partitions oversubscribe the runner badly enough for a single process to
# stall for seconds. ExUnit's 100ms default turns those stalls into failures
# that reproduce nowhere else, so the floor sits inside the range the
# load-sensitive files already pick explicitly. Assertions that must stay tight
# keep passing their own budget; refute_receive keeps the fast default so
# proving a message never arrives stays cheap.
ExUnit.start(assert_receive_timeout: 5_000)

# The cache process can start while the reset test database is still being
# migrated. Publish one authoritative snapshot before manual sandbox ownership
# makes background retries unable to read the Repo.
settings = CodexPooler.InstanceSettings.ensure_singleton!()
:ok = CodexPooler.InstanceSettings.Cache.put_for_test(settings)

Ecto.Adapters.SQL.Sandbox.mode(CodexPooler.Repo, :manual)
