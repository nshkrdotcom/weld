%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/weld/", "test/support/"],
        excluded: [~r"/_build/", ~r"/deps/", ~r"/doc/"]
      },
      strict: true
    }
  ]
}
