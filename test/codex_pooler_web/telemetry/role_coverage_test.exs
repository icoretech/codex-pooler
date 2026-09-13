defmodule CodexPoolerWeb.Telemetry.RoleCoverageTest do
  # The Prometheus reporter is switched off for OBAN_MODE=worker and scheduler,
  # and the chart's ServiceMonitor scrapes only the app pods, so a telemetry
  # event emitted from a job never becomes a series. Everything an author can
  # check still passes: the event fires, in-process handlers see it, the metric
  # is declared, a panel renders. The graph is empty forever and reads as "this
  # never happens".
  #
  # This file derives, from the compiled application, the set of declared
  # metrics with an emission an Oban job can reach, and requires it to equal
  # what CodexPoolerWeb.Telemetry.RoleCoverage declares. A metric added on a job
  # path therefore fails here until someone declares it and writes the caveat
  # into the metric and its dashboard panels. That the guard notices a new one
  # is itself covered, against a synthetic worker compiled inside the test.
  #
  # Touching OBAN_MODE is process-global, so this module is serial. Reading the
  # whole application's debug info costs a second or two of setup_all, which is
  # the property under test: the claim is about every compiled module, not a
  # sample.
  use ExUnit.Case, async: false

  alias CodexPoolerWeb.Telemetry
  alias CodexPoolerWeb.Telemetry.RoleCoverage

  @dashboard Path.expand(
               "../../../docs-site/public/operators/monitoring/codex-pooler-runtime-triage.json",
               __DIR__
             )

  # TelemetryMetricsPrometheus.Core exports a distribution as three series.
  @distribution_suffixes ["_bucket", "_sum", "_count"]

  defmodule CallGraph do
    @moduledoc false
    # An intra-process call graph read out of compiled BEAM debug info, plus the
    # telemetry events each function can emit. Remote calls, local calls,
    # function captures and inline closures are edges; a message to another
    # process is not, because the receiving process runs wherever it was started
    # and is usually not the job's role.

    defstruct graph: %{}, emitters: %{}, literals: %{}, workers: []

    @type t :: %__MODULE__{}

    # `elixirc_paths` puts test support and development helpers in the same ebin
    # as the application, and one of those helpers is an Oban worker. Rooting the
    # derivation at a test harness would let test code claim a production
    # emission, so the graph is built from modules compiled out of `lib/` only.
    @application_source ~r{(^|/)lib/}

    @spec scan([Path.t()]) :: t()
    def scan(ebin_dirs) do
      ebin_dirs
      |> Enum.flat_map(&Path.wildcard(Path.join(&1, "*.beam")))
      |> Enum.reduce(%__MODULE__{}, &scan_beam/2)
    end

    defp scan_beam(path, acc) do
      case :beam_lib.chunks(String.to_charlist(path), [:abstract_code]) do
        {:ok, {module, [abstract_code: {:raw_abstract_v1, forms}]}} ->
          if application_module?(forms), do: add_module(acc, module, forms), else: acc

        _no_debug_info ->
          acc
      end
    end

    defp application_module?(forms) do
      Enum.any?(forms, fn
        {:attribute, _line, :file, {source, _l}} ->
          Regex.match?(@application_source, List.to_string(source))

        _other ->
          false
      end)
    end

    defp add_module(acc, module, forms) do
      behaviours = for {:attribute, _line, :behaviour, behaviour} <- forms, do: behaviour

      {graph, emitters, literals} =
        for {:function, _line, name, arity, clauses} <- forms,
            reduce: {acc.graph, acc.emitters, MapSet.new()} do
          {graph, emitters, literals} ->
            {calls, emits?, found} = walk(clauses, module, {[], false, []})
            mfa = {module, name, arity}
            found = MapSet.new(found)

            {
              Map.put(graph, mfa, Enum.uniq(calls)),
              if(emits?, do: Map.put(emitters, mfa, found), else: emitters),
              MapSet.union(literals, found)
            }
        end

      %{
        acc
        | graph: graph,
          emitters: emitters,
          literals: Map.put(acc.literals, module, literals),
          workers: if(Oban.Worker in behaviours, do: [module | acc.workers], else: acc.workers)
      }
    end

    # Returns {calls, emits_telemetry?, atom-list literals seen}.
    defp walk({:call, _line, {:remote, _l, {:atom, _lm, m}, {:atom, _lf, f}}, args}, mod, acc) do
      {calls, emits?, literals} = acc
      emits? = emits? or (m == :telemetry and f == :execute)
      walk(args, mod, {[{m, f, length(args)} | calls], emits?, literals})
    end

    defp walk({:call, _line, {:atom, _l, f}, args}, mod, {calls, emits?, literals}) do
      walk(args, mod, {[{mod, f, length(args)} | calls], emits?, literals})
    end

    defp walk({:fun, _l, {:function, {:atom, _, m}, {:atom, _, f}, {:integer, _, a}}}, _mod, acc) do
      {calls, emits?, literals} = acc
      {[{m, f, a} | calls], emits?, literals}
    end

    defp walk({:fun, _l, {:function, f, a}}, mod, {calls, emits?, literals})
         when is_atom(f) and is_integer(a) do
      {[{mod, f, a} | calls], emits?, literals}
    end

    defp walk({:cons, _l, {:atom, _la, _head}, _tail} = node, mod, acc) do
      {calls, emits?, literals} = walk(Tuple.to_list(node), mod, acc)

      case atom_list(node) do
        nil -> {calls, emits?, literals}
        list -> {calls, emits?, [list | literals]}
      end
    end

    defp walk(list, mod, acc) when is_list(list),
      do: Enum.reduce(list, acc, &walk(&1, mod, &2))

    defp walk(tuple, mod, acc) when is_tuple(tuple),
      do: walk(Tuple.to_list(tuple), mod, acc)

    defp walk(_other, _mod, acc), do: acc

    defp atom_list({nil, _line}), do: []

    defp atom_list({:cons, _line, {:atom, _l, head}, tail}) do
      case atom_list(tail) do
        nil -> nil
        rest -> [head | rest]
      end
    end

    defp atom_list(_other), do: nil

    @doc """
    Emission sites per event: functions calling `:telemetry.execute/3` whose own
    literals name the event. A function naming no candidate event takes the name
    from its module's literals instead, which is how an emitter receiving the
    event as an argument — a module attribute, or a prefix plus a suffix — is
    still attributed. Falling back at module level unconditionally would give
    every emitter in a module all of that module's events, which is how the
    first run of this guard confused stream finalization with stream outcome.
    """
    @spec emission_sites(t(), [[atom()]]) :: %{[atom()] => [mfa()]}
    def emission_sites(%__MODULE__{} = graph, events) do
      for {{module, _f, _a} = mfa, own} <- graph.emitters,
          reduce: Map.new(events, &{&1, []}) do
        acc ->
          named =
            case named_events(own, events) do
              [] -> named_events(Map.get(graph.literals, module, MapSet.new()), events)
              named -> named
            end

          Enum.reduce(named, acc, fn event, inner -> Map.update!(inner, event, &[mfa | &1]) end)
      end
    end

    defp named_events(literals, events),
      do: for(event <- events, Enum.any?(literals, &names_event?(&1, event)), do: event)

    defp names_event?(literal, event),
      do: literal == event or (literal != [] and List.starts_with?(event, literal))

    @doc "One entrypoint per Oban worker module that defines `perform/1`."
    @spec worker_entrypoints(t()) :: [mfa()]
    def worker_entrypoints(%__MODULE__{} = graph) do
      graph.workers
      |> Enum.map(&{&1, :perform, 1})
      |> Enum.filter(&Map.has_key?(graph.graph, &1))
      |> Enum.sort()
    end

    @doc "Every function reachable from `roots` without crossing a process boundary."
    @spec reachable(t(), [mfa()]) :: MapSet.t(mfa())
    def reachable(%__MODULE__{} = graph, roots),
      do: graph |> parents(roots) |> Map.keys() |> MapSet.new()

    @doc "Shortest call path from one of `roots` to `target`, or nil when unreachable."
    @spec witness(t(), [mfa()], mfa()) :: [mfa()] | nil
    def witness(%__MODULE__{} = graph, roots, target) do
      parents = parents(graph, roots)

      if Map.has_key?(parents, target) do
        target
        |> Stream.iterate(&Map.get(parents, &1))
        |> Enum.take_while(&(&1 != nil))
        |> Enum.reverse()
      end
    end

    defp parents(%__MODULE__{graph: graph}, roots) do
      {parents, _frontier} =
        {%{}, Enum.map(roots, &{&1, nil})}
        |> Stream.iterate(fn {parents, frontier} ->
          fresh = Enum.reject(frontier, fn {mfa, _parent} -> Map.has_key?(parents, mfa) end)
          parents = Enum.reduce(fresh, parents, fn {mfa, p}, acc -> Map.put_new(acc, mfa, p) end)

          next =
            Enum.flat_map(fresh, fn {mfa, _parent} ->
              graph |> Map.get(mfa, []) |> Enum.map(&{&1, mfa})
            end)

          {parents, next}
        end)
        |> Enum.find(fn {_parents, frontier} -> frontier == [] end)

      parents
    end
  end

  setup_all do
    graph = CallGraph.scan([Mix.Project.compile_path()])
    roots = CallGraph.worker_entrypoints(graph)

    # A derivation that found nothing would satisfy "no new member" without
    # proving anything, so bind its scale.
    assert map_size(graph.graph) > 5_000,
           "the call graph is empty or tiny; compiled debug info is probably missing"

    assert length(roots) >= 10, "no Oban workers were found to root the derivation from"

    {:ok,
     graph: graph,
     roots: roots,
     reachable: CallGraph.reachable(graph, roots),
     sites: CallGraph.emission_sites(graph, declared_metric_events())}
  end

  describe "the premise" do
    test "the reporter is disabled for exactly the OBAN_MODE values RoleCoverage declares" do
      original = System.fetch_env("OBAN_MODE")

      on_exit(fn ->
        case original do
          {:ok, value} -> System.put_env("OBAN_MODE", value)
          :error -> System.delete_env("OBAN_MODE")
        end
      end)

      for mode <- RoleCoverage.unscraped_oban_modes() do
        System.put_env("OBAN_MODE", mode)

        refute Telemetry.prometheus_reporter_enabled?(),
               "RoleCoverage calls OBAN_MODE=#{mode} unscraped, but the reporter starts there"
      end

      for mode <- ~w(web all) do
        System.put_env("OBAN_MODE", mode)

        assert Telemetry.prometheus_reporter_enabled?(),
               "OBAN_MODE=#{mode} no longer runs the reporter; RoleCoverage needs to say so"
      end

      System.delete_env("OBAN_MODE")
      assert Telemetry.prometheus_reporter_enabled?()
    end
  end

  describe "derived role coverage" do
    test "every metric with a job-reachable emission is declared", context do
      undeclared =
        context
        |> derive_unscraped_events()
        |> Enum.reject(fn {event, _sites} -> RoleCoverage.declared?(event) end)

      assert undeclared == [],
             """
             These telemetry events have a declared metric and an emission an Oban job can reach,
             so their series lose everything the job emits on any deployment that is not
             OBAN_MODE=all. Declare each one in CodexPoolerWeb.Telemetry.RoleCoverage, name the
             durable rows an operator should read instead, and put the caveat in the metric
             description and in every dashboard panel that charts it.

             """ <>
               Enum.map_join(undeclared, "\n\n", &describe_derivation(context, &1))
    end

    test "no declaration outlives the emission it was written for", context do
      derived = derived_events(context)
      stale = Enum.reject(RoleCoverage.declared_events(), &(&1 in derived))

      assert stale == [],
             "no Oban job reaches an emission of #{inspect(stale)} any more; drop the " <>
               "RoleCoverage declaration and the caveats it forced onto the metric and panels"
    end

    test "each declaration names the jobs that actually reach it", context do
      mismatched =
        for {event, declaration} <- RoleCoverage.unscraped_emissions(),
            declared = Enum.sort(declaration.entrypoints),
            derived = derived_entrypoints(context, event),
            declared != derived,
            do: {event, declared, derived}

      assert mismatched == [],
             "RoleCoverage entrypoints disagree with the call graph: " <>
               Enum.map_join(mismatched, "; ", fn {event, declared, derived} ->
                 "#{inspect(event)} declares #{inspect(declared)} but #{inspect(derived)} reach it"
               end)
    end
  end

  describe "the caveat an operator has to see" do
    test "every declared event's metrics say so in their description" do
      silent =
        for metric <- Telemetry.prometheus_metrics(),
            RoleCoverage.declared?(metric.event_name),
            not RoleCoverage.caveat_present?(metric.description),
            do: Enum.join(metric.name, ".")

      assert silent == [],
             "these metrics are emitted from an unscraped role and their description does not " <>
               "mention #{RoleCoverage.caveat_marker()}: #{Enum.join(silent, ", ")}"
    end

    test "every operator dashboard panel charting one says so in its description" do
      series = declared_series()

      charting =
        Enum.filter(dashboard_panels(), fn panel ->
          Enum.any?(panel_series(panel), &MapSet.member?(series, &1))
        end)

      # A dashboard that stopped charting these would pass vacuously.
      assert length(charting) >= 4,
             "the operator dashboard no longer charts the metrics RoleCoverage declares; " <>
               "either the panels were dropped or this test stopped finding them"

      silent =
        for panel <- charting,
            not RoleCoverage.caveat_present?(Map.get(panel, "description")),
            do: Map.get(panel, "title", "<untitled>")

      assert silent == [],
             "these operator dashboard panels chart a metric emitted from an unscraped role and " <>
               "their description does not mention #{RoleCoverage.caveat_marker()}, so an empty " <>
               "graph reads as \"this never happens\": #{Enum.join(silent, ", ")}"
    end
  end

  describe "the guard itself" do
    test "a metric added on a new job path is derived even though nothing declares it", context do
      {dir, modules} = compile_synthetic_worker()

      on_exit(fn ->
        Enum.each(modules, fn module ->
          :code.purge(module)
          :code.delete(module)
        end)

        File.rm_rf!(dir)
      end)

      graph = CallGraph.scan([Mix.Project.compile_path(), dir])
      roots = CallGraph.worker_entrypoints(graph)
      event = [:codex_pooler, :role_coverage_guard, :probe]

      probe = %{
        graph: graph,
        roots: roots,
        reachable: CallGraph.reachable(graph, roots),
        sites: CallGraph.emission_sites(graph, [event | declared_metric_events()])
      }

      # The synthetic worker stands in for the next metric someone adds on a job
      # path: a declared metric whose only emitter is reached from a perform/1.
      assert length(roots) == length(context.roots) + 1
      refute RoleCoverage.declared?(event)

      derived = derive_unscraped_events(probe)

      assert List.keymember?(derived, event, 0),
             "the guard did not derive a synthetic job-only emission, so it would not catch " <>
               "the next metric added on a job path"

      # The same scan still sees the real application, so the probe is not
      # passing by scanning nothing but itself.
      assert derived |> Enum.map(&elem(&1, 0)) |> Enum.sort() ==
               Enum.sort([event | RoleCoverage.declared_events()])
    end
  end

  defp derive_unscraped_events(%{sites: sites, reachable: reachable}) do
    for {event, event_sites} <- Enum.sort(sites),
        reached = Enum.filter(event_sites, &MapSet.member?(reachable, &1)),
        reached != [],
        do: {event, Enum.sort(reached)}
  end

  defp derived_events(context),
    do: context |> derive_unscraped_events() |> Enum.map(&elem(&1, 0))

  defp derived_entrypoints(%{graph: graph, roots: roots, sites: sites}, event) do
    sites = Map.fetch!(sites, event)

    roots
    |> Enum.filter(fn root ->
      from_root = CallGraph.reachable(graph, [root])
      Enum.any?(sites, &MapSet.member?(from_root, &1))
    end)
    |> Enum.map(fn {module, _f, _a} -> module end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp describe_derivation(%{graph: graph, roots: roots}, {event, sites}) do
    witness =
      sites
      |> Enum.find_value(&CallGraph.witness(graph, roots, &1))
      |> Enum.map_join("\n    ", &inspect/1)

    "#{inspect(event)} reached by:\n    #{witness}"
  end

  defp declared_metric_events,
    do: Telemetry.prometheus_metrics() |> Enum.map(& &1.event_name) |> Enum.uniq()

  defp declared_series do
    for metric <- Telemetry.prometheus_metrics(),
        RoleCoverage.declared?(metric.event_name),
        base = Enum.map_join(metric.name, "_", &Atom.to_string/1),
        name <- [base | Enum.map(@distribution_suffixes, &(base <> &1))],
        into: MapSet.new(),
        do: name
  end

  defp dashboard_panels do
    @dashboard
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("panels")
    |> Enum.flat_map(fn panel -> [panel | Map.get(panel, "panels") || []] end)
  end

  defp panel_series(panel) do
    panel
    |> Map.get("targets", [])
    |> Enum.flat_map(&Regex.scan(~r/\bcodex_pooler_[a-z0-9_]+\b/, Map.get(&1, "expr", "")))
    |> Enum.map(&hd/1)
  end

  defp compile_synthetic_worker do
    dir =
      Path.join(System.tmp_dir!(), "role_coverage_guard_#{System.unique_integer([:positive])}")

    # The probe is compiled from a lib/ path because the guard builds its graph
    # from application sources only.
    source_dir = Path.join(dir, "lib")
    File.mkdir_p!(source_dir)
    suffix = System.unique_integer([:positive])

    source = """
    defmodule RoleCoverageGuardProbe.Emitter#{suffix} do
      @event [:codex_pooler, :role_coverage_guard, :probe]

      def record(value) do
        :telemetry.execute(@event, %{count: 1}, %{value: value})
      end
    end

    defmodule RoleCoverageGuardProbe.Worker#{suffix} do
      @behaviour Oban.Worker

      alias RoleCoverageGuardProbe.Emitter#{suffix}, as: Emitter

      @impl Oban.Worker
      def perform(%{args: args}), do: handle(args)

      defp handle(args), do: Emitter.record(args)
    end
    """

    # The guard reads abstract code, so the probe has to carry it whatever the
    # ambient compiler options are.
    debug_info = Code.get_compiler_option(:debug_info)
    Code.put_compiler_option(:debug_info, true)

    source_path = Path.join(source_dir, "role_coverage_guard_probe.ex")
    File.write!(source_path, source)

    {compiled, _stderr} =
      try do
        ExUnit.CaptureIO.with_io(:stderr, fn -> Code.compile_file(source_path) end)
      after
        Code.put_compiler_option(:debug_info, debug_info)
      end

    for {module, binary} <- compiled do
      path = Path.join(dir, "#{module}.beam")
      File.write!(path, binary)

      assert {:ok, {^module, [abstract_code: {:raw_abstract_v1, _forms}]}} =
               :beam_lib.chunks(String.to_charlist(path), [:abstract_code]),
             "the probe module compiled without debug info, so it proves nothing"
    end

    {dir, Enum.map(compiled, &elem(&1, 0))}
  end
end
