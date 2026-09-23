%{
  configs: [
    %{
      name: "default",
      # Credo's default file set omits dev_support, which the dev and test builds compile.
      files: %{included: ["lib/", "test/", "dev_support/"], excluded: [~r"/_build/", ~r"/deps/", ~r"/node_modules/"]},
      checks: %{disabled: [{Credo.Check.Readability.MaxLineLength, []}]}
    }
  ]
}
