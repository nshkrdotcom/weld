[
  schema: 2,
  workspace: [root: "..", projects: ["."]],
  artifacts: [
    weld_native_probe: [
      layout: :preserve,
      roots: ["."],
      preserve: [
        files: ~w(mix.exs Makefile checksums.sha256 c_src data lib test README.md LICENSE),
        inputs: [[path: "checksums.sha256", type: :file], [path: "Makefile", type: :file]]
      ],
      verify: [
        hex_publish_check: false,
        context: ["native_cc", "native_source_pins"],
        smoke: [entry_file: "build_support/smoke.ex"]
      ]
    ]
  ]
]
