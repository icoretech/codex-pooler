defmodule CodexPooler.ControlPlaneRoutes do
  @moduledoc false

  @type body_mode :: :no_body | :sdp | {:json, atom()}
  @type route :: %{
          required(:method) => atom(),
          required(:local_path) => String.t(),
          required(:upstream_path) => String.t(),
          required(:action) => atom(),
          required(:body_mode) => body_mode()
        }

  @routes [
    %{
      method: :get,
      local_path: "/backend-api/codex/thread/goal/get",
      upstream_path: "/codex/thread/goal/get",
      action: :thread_goal_get,
      body_mode: :no_body
    },
    %{
      method: :post,
      local_path: "/backend-api/codex/thread/goal/get",
      upstream_path: "/codex/thread/goal/get",
      action: :thread_goal_get_post,
      body_mode: {:json, :thread_goal_get}
    },
    %{
      method: :post,
      local_path: "/backend-api/codex/thread/goal/set",
      upstream_path: "/codex/thread/goal/set",
      action: :thread_goal_set,
      body_mode: {:json, :thread_goal_set}
    },
    %{
      method: :post,
      local_path: "/backend-api/codex/thread/goal/clear",
      upstream_path: "/codex/thread/goal/clear",
      action: :thread_goal_clear,
      body_mode: {:json, :thread_goal_clear}
    },
    %{
      method: :post,
      local_path: "/backend-api/codex/analytics-events/events",
      upstream_path: "/codex/analytics-events/events",
      action: :analytics_events,
      body_mode: {:json, :analytics_events}
    },
    %{
      method: :post,
      local_path: "/backend-api/codex/memories/trace_summarize",
      upstream_path: "/codex/memories/trace_summarize",
      action: :memories_trace_summarize,
      body_mode: {:json, :memories_trace_summarize}
    },
    %{
      method: :post,
      local_path: "/backend-api/codex/alpha/search",
      upstream_path: "/alpha/search",
      action: :alpha_search,
      body_mode: {:json, :alpha_search}
    },
    %{
      method: :post,
      local_path: "/backend-api/codex/realtime/calls",
      upstream_path: "/codex/realtime/calls",
      action: :realtime_calls,
      body_mode: :sdp
    },
    %{
      method: :post,
      local_path: "/backend-api/codex/safety/arc",
      upstream_path: "/codex/safety/arc",
      action: :safety_arc,
      body_mode: {:json, :safety_arc}
    },
    %{
      method: :get,
      local_path: "/backend-api/codex/agent-identities/jwks",
      upstream_path: "/codex/agent-identities/jwks",
      action: :agent_identities_jwks,
      body_mode: :no_body
    },
    %{
      method: :get,
      local_path: "/backend-api/wham/agent-identities/jwks",
      upstream_path: "/wham/agent-identities/jwks",
      action: :wham_agent_identities_jwks,
      body_mode: :no_body
    }
  ]

  @routes_by_action Map.new(@routes, &{&1.action, &1})
  @local_paths MapSet.new(Enum.map(@routes, & &1.local_path))

  @spec all() :: [route()]
  def all, do: @routes

  @spec local_path?(String.t()) :: boolean()
  def local_path?(path) when is_binary(path), do: MapSet.member?(@local_paths, path)
  def local_path?(_path), do: false

  @spec fetch_by_action(atom()) :: {:ok, route()} | :error
  def fetch_by_action(action) when is_atom(action), do: Map.fetch(@routes_by_action, action)

  @spec fetch_by_action!(atom()) :: route()
  def fetch_by_action!(action) when is_atom(action), do: Map.fetch!(@routes_by_action, action)
end
