[
  workspace: [
    root: "../..",
    project_globs: ["core/*", "runtime/*"]
  ],
  artifacts: [
    composite_bundle: [
      roots: ["runtime/local"],
      package: [
        name: "composite_bundle",
        otp_app: :composite_bundle,
        version: "0.1.0",
        description: "Composite runtime fixture"
      ],
      output: [
        docs: ["README.md"]
      ],
      verify: [
        artifact_tests: ["packaging/weld/composite_bundle/test"]
      ]
    ]
  ]
]
