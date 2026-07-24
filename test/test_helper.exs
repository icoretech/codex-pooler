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

ExUnit.start()

ExUnit.after_suite(fn _result ->
  :ok = :logger.remove_handler_filter(:default, native_turn_console_filter)
end)

Ecto.Adapters.SQL.Sandbox.mode(CodexPooler.Repo, :manual)
