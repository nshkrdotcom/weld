[
  schema: 2,
  workspace: [
    root: "../..",
    projects: ["core/*", "runtime/*"]
  ],
  artifacts: [
    composite_bundle: [
      layout: :components,
      roots: ["runtime/local"],
      package: [
        name: "composite_bundle",
        otp_app: :composite_bundle,
        version: "0.1.0",
        description: "Composite runtime fixture"
      ],
      files: [
        docs: ["README.md"]
      ],
      verify: [
        hex_publish_check: false,
        artifact_tests: ["packaging/weld/composite_bundle/test"]
      ]
    ]
  ]
]
