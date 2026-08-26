defmodule CodexPooler.Dev.CodexCompactionSmokeFixture.Journal do
  @moduledoc false

  @max_file_bytes 65_536
  @journal_keys ~w(version run_id state pool_id identity_id assignment_id model_id api_key_id)
  @secret_keys ~w(version run_id api_key api_key_id pool_id model)

  @type paths :: %{root: String.t(), journal: String.t(), secret: String.t()}

  @spec paths(String.t(), String.t()) :: paths()
  def paths(parent, run_id) do
    root = Path.join(parent, run_id)

    %{
      root: root,
      journal: Path.join(root, "journal.json"),
      secret: Path.join(root, "secret.json")
    }
  end

  @spec prepared(String.t()) :: map()
  def prepared(run_id) do
    %{
      "version" => 1,
      "run_id" => run_id,
      "state" => "preparing",
      "pool_id" => nil,
      "identity_id" => nil,
      "assignment_id" => nil,
      "model_id" => nil,
      "api_key_id" => nil
    }
  end

  @spec put_resource(map(), atom(), String.t()) :: map()
  def put_resource(journal, kind, id)
      when kind in [:pool, :identity, :assignment, :model, :api_key] and is_binary(id) do
    Map.put(journal, "#{kind}_id", id)
  end

  @spec ready(map()) :: map()
  def ready(journal), do: Map.put(journal, "state", "ready")

  @spec new(String.t(), String.t(), String.t(), String.t(), String.t()) :: map()
  def new(run_id, pool_id, identity_id, assignment_id, model_id) do
    run_id
    |> prepared()
    |> put_resource(:pool, pool_id)
    |> put_resource(:identity, identity_id)
    |> put_resource(:assignment, assignment_id)
    |> put_resource(:model, model_id)
    |> Map.put("state", "prepared")
  end

  @spec secret(String.t(), String.t(), String.t(), String.t(), String.t()) :: map()
  def secret(run_id, api_key, api_key_id, pool_id, model) do
    %{
      "version" => 1,
      "run_id" => run_id,
      "api_key" => api_key,
      "api_key_id" => api_key_id,
      "pool_id" => pool_id,
      "model" => model
    }
  end

  @spec write_journal(paths(), map()) :: :ok
  def write_journal(paths, journal), do: write_private(paths, paths.journal, journal)

  @spec write_secret(paths(), map()) :: :ok
  def write_secret(paths, secret), do: write_private(paths, paths.secret, secret)

  @spec read_journal(paths(), String.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def read_journal(paths, run_id, options \\ []),
    do: read_private(paths, paths.journal, run_id, :journal, options)

  @spec read_secret(paths(), String.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def read_secret(paths, run_id, options \\ []),
    do: read_private(paths, paths.secret, run_id, :secret, options)

  @spec remove_secret(paths()) :: :ok
  def remove_secret(paths), do: remove(paths.secret)

  @spec remove_all(paths()) :: :ok
  def remove_all(paths) do
    case File.lstat(paths.root) do
      {:ok, %File.Stat{type: :directory, uid: uid}} ->
        if uid == current_uid(),
          do: File.rm_rf!(paths.root),
          else: raise("fixture root owner changed")

      {:error, :enoent} ->
        :ok

      _unsafe ->
        raise "fixture root is not an owned directory"
    end

    :ok
  end

  defp write_private(paths, path, value) do
    ensure_root(paths.root)
    reject_existing_unsafe(path)
    temporary = path <> ".tmp-" <> random_suffix()

    try do
      {:ok, file} = :file.open(String.to_charlist(temporary), [:write, :binary, :raw, :exclusive])

      try do
        :ok = :file.write(file, Jason.encode!(value) <> "\n")
        :ok = :file.sync(file)
      after
        :ok = :file.close(file)
      end

      File.chmod!(temporary, 0o600)
      File.rename!(temporary, path)
      :ok
    after
      File.rm(temporary)
    end
  end

  defp read_private(paths, path, run_id, kind, options) do
    expected_uid = Keyword.get(options, :expected_uid, current_uid())

    with {:ok, body} <- descriptor_read(paths.root, Path.basename(path), expected_uid),
         {:ok, %{} = value} <- Jason.decode(body),
         ^run_id <- value["run_id"],
         :ok <- validate_schema(kind, value) do
      {:ok, value}
    else
      {:error, :enoent} -> {:error, :missing}
      {:error, :unsafe_owner} -> {:error, :unsafe_owner}
      {:error, :unsafe_file} -> {:error, :unsafe_file}
      {:error, _reason} -> {:error, :invalid}
      _other -> {:error, :invalid}
    end
  end

  defp descriptor_read(root, basename, expected_uid) do
    script = """
    import os, stat, sys
    root, name, expected_uid, max_bytes = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
      parent = os.open(root, flags | getattr(os, "O_DIRECTORY", 0))
      try:
        parent_stat = os.fstat(parent)
        if not stat.S_ISDIR(parent_stat.st_mode) or parent_stat.st_uid != expected_uid or stat.S_IMODE(parent_stat.st_mode) != 0o700:
          sys.exit(42)
        fd = os.open(name, flags, dir_fd=parent)
        try:
          opened = os.fstat(fd)
          linked = os.stat(name, dir_fd=parent, follow_symlinks=False)
          if not stat.S_ISREG(opened.st_mode) or opened.st_uid != expected_uid or stat.S_IMODE(opened.st_mode) != 0o600:
            sys.exit(42)
          if (opened.st_dev, opened.st_ino) != (linked.st_dev, linked.st_ino):
            sys.exit(43)
          body = os.read(fd, max_bytes + 1)
          if len(body) > max_bytes:
            sys.exit(44)
          os.write(1, body)
        finally:
          os.close(fd)
      finally:
        os.close(parent)
    except FileNotFoundError:
      sys.exit(2)
    except OSError:
      sys.exit(43)
    """

    case System.cmd(
           "python3",
           [
             "-c",
             script,
             root,
             basename,
             Integer.to_string(expected_uid),
             Integer.to_string(@max_file_bytes)
           ],
           stderr_to_stdout: true
         ) do
      {body, 0} -> {:ok, body}
      {_output, 2} -> {:error, :enoent}
      {_output, 42} -> {:error, :unsafe_owner}
      {_output, 43} -> {:error, :unsafe_file}
      {_output, _status} -> {:error, :invalid}
    end
  end

  defp validate_schema(:journal, value) do
    valid_ids? =
      Enum.all?(~w(pool_id identity_id assignment_id model_id api_key_id), fn key ->
        is_nil(value[key]) or is_binary(value[key])
      end)

    valid_states = ~w(preparing prepared ready)

    if Enum.sort(Map.keys(value)) == Enum.sort(@journal_keys) and value["version"] == 1 and
         value["state"] in valid_states and valid_ids?,
       do: :ok,
       else: {:error, :schema}
  end

  defp validate_schema(:secret, value) do
    if Enum.sort(Map.keys(value)) == Enum.sort(@secret_keys) and value["version"] == 1 and
         Enum.all?(
           ~w(run_id api_key api_key_id pool_id model),
           &(is_binary(value[&1]) and value[&1] != "")
         ),
       do: :ok,
       else: {:error, :schema}
  end

  defp ensure_root(root) do
    uid = current_uid()

    case File.lstat(root) do
      {:ok, %File.Stat{type: :directory, uid: ^uid}} -> :ok
      {:error, :enoent} -> File.mkdir_p!(root)
      _unsafe -> raise "fixture root is not a current-uid directory"
    end

    File.chmod!(root, 0o700)
  end

  defp reject_existing_unsafe(path) do
    uid = current_uid()

    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, uid: ^uid}} -> :ok
      {:error, :enoent} -> :ok
      _unsafe -> raise "fixture file is not a current-uid regular file"
    end
  end

  defp remove(path) do
    uid = current_uid()

    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, uid: ^uid}} -> File.rm!(path)
      {:error, :enoent} -> :ok
      _unsafe -> raise "fixture file is not an owned regular file"
    end
  end

  defp current_uid do
    {value, 0} = System.cmd("id", ["-u"])
    value |> String.trim() |> String.to_integer()
  end

  defp random_suffix, do: 6 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
end
