defmodule Bench do
  @moduledoc """
  Bench harness for the bondy_oplog/bondy_db layer.

  Wires the rebar3-built umbrella beams into the Elixir VM, starts the
  `:bondy_db` application (which pulls `:bondy_oplog` + `:bondy_mst` +
  `:leveled`), and exposes shared helpers used by the benchmark scripts
  in `benchmarks/`. The MST-library-only benchmarks live in the
  `bondy_mst` repo's own `bench/`.
  """

  # Erlang modules from rebar3-built deps are loaded at runtime via
  # `Code.prepend_path/1`, so Mix's compiler can't see them.
  @compile {:no_warn_undefined, [:bondy_db, :bondy_oplog, :bondy_mst]}

  @root_app :bondy_db
  # __DIR__ is bench/lib, so the bondy umbrella root is two up.
  @project_root Path.expand("../..", __DIR__)
  @rebar_default_lib Path.join([@project_root, "_build", "default", "lib"])
  # Some umbrella deps (e.g. bondy_mst) are rebar3 checkouts, which build to
  # _build/default/checkouts/<dep>/ebin rather than .../lib — scan both.
  @rebar_default_checkouts Path.join([
                             @project_root,
                             "_build",
                             "default",
                             "checkouts"
                           ])
  @output_dir Path.join([@project_root, "bench", "_output"])

  @doc """
  Ensures the rebar3 default + bench profiles are compiled, prepends
  every beam directory to the code path, and starts `:bondy_mst`.

  Safe to call multiple times in one VM.
  """
  def setup do
    ensure_compiled!()
    prepend_beam_paths!()
    start_app!()
    File.mkdir_p!(@output_dir)
    :ok
  end

  @doc """
  Returns `true` when the leveled beams are on the path. In the umbrella
  `leveled` is a normal dependency of `:bondy_db`, so it is always present
  once the umbrella is compiled.
  """
  def leveled_available? do
    File.dir?(Path.join([@rebar_default_lib, "leveled", "ebin"])) and
      Code.ensure_loaded?(:leveled_bookie)
  end

  @doc "Absolute path to the bench HTML/JSON output directory."
  def output_dir, do: @output_dir

  @doc """
  Default Benchee options used across every script in this project.

  Captures the percentiles requested for the HTML report and pins
  the formatters to JSON + HTML side-by-side so the static report
  links to its underlying data.
  """
  def benchee_opts(name, opts \\ []) do
    sub_dir = Path.join(@output_dir, name)
    File.mkdir_p!(sub_dir)

    defaults = [
      time: 5,
      warmup: 2,
      memory_time: 2,
      reduction_time: 2,
      percentiles: [50, 75, 90, 95, 99],
      print: [benchmarking: true, configuration: false, fast_warning: false],
      formatters: [
        {Benchee.Formatters.HTML,
         file: Path.join(sub_dir, "index.html"),
         auto_open: false,
         inline_assets: true},
        {Benchee.Formatters.JSON, file: Path.join(sub_dir, "data.json")},
        Benchee.Formatters.Console
      ]
    ]

    Keyword.merge(defaults, opts)
  end

  @doc """
  Generates `count` deterministic binary keys of the form
  `"k:00000001"`. Stable across runs so different benchmarks measure
  the same workload.
  """
  def gen_keys(count) when is_integer(count) and count > 0 do
    width = max(8, byte_size(Integer.to_string(count)))

    for i <- 1..count do
      "k:" <> String.pad_leading(Integer.to_string(i), width, "0")
    end
  end

  @doc """
  Returns `count` deterministically-shuffled keys for read benchmarks.
  Uses a fixed seed so each run hits the same access pattern.
  """
  def gen_keys_shuffled(count, seed \\ 42) do
    keys = gen_keys(count)
    _ = :rand.seed(:exsss, {seed, seed + 1, seed + 2})
    Enum.shuffle(keys)
  end

  @doc """
  Builds an MST containing `count` items using the supplied store
  module and store options. Returns the populated tree.
  """
  def build_tree(count, store_mod \\ :bondy_mst_map_store, store_opts \\ %{}) do
    tree =
      :bondy_mst.new(%{
        store: store_mod,
        store_opts: store_opts
      })

    keys = gen_keys(count)

    Enum.reduce(keys, tree, fn k, acc ->
      :bondy_mst.put(acc, k, k)
    end)
  end

  defp ensure_compiled! do
    unless File.dir?(@rebar_default_lib) do
      compile!(["compile"], "default")
    end
  end

  defp compile!(args, profile) do
    IO.puts("[bench] compiling bondy umbrella (rebar3 profile: #{profile})...")
    {out, status} = System.cmd("rebar3", args, cd: @project_root)

    if status != 0 do
      IO.puts(out)
      raise "rebar3 compile (profile #{profile}) failed (status #{status})"
    end
  end

  defp prepend_beam_paths! do
    # The rebar3 `default` profile lib holds every production dep including
    # leveled (a normal dependency of :bondy_db in this umbrella); the
    # checkouts dir holds rebar3 checkout deps (e.g. bondy_mst). (A separate
    # `bench` profile root was once listed here but never defined; dropped to
    # fix a nil File.ls/1 crash.)
    Enum.each([@rebar_default_lib, @rebar_default_checkouts], fn root ->
      case File.ls(root) do
        {:ok, deps} ->
          Enum.each(deps, fn dep ->
            ebin = Path.join([root, dep, "ebin"])
            if File.dir?(ebin), do: Code.prepend_path(ebin)
          end)

        _ ->
          :ok
      end
    end)
  end

  defp start_app! do
    {:ok, _} = Application.ensure_all_started(@root_app)
    :ok
  end
end
