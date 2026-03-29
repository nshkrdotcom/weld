[
  workspace: [
    root: "../.."
  ],
  classify: [
    tooling: [".", "tooling/test_support"],
    proofs: ["proofs/demo"]
  ],
  publication: [
    internal_only: ["tooling/test_support"],
    optional: [
      demo: ["proofs/demo"]
    ]
  ],
  artifacts: [
    web_bundle: [
      roots: ["apps/web"],
      package: [
        name: "root_web_bundle",
        otp_app: :root_web_bundle,
        version: "0.1.0",
        description: "Root web bundle"
      ],
      output: [
        docs: ["README.md"]
      ],
      verify: [
        artifact_tests: ["packaging/weld/web_bundle/test"]
      ]
    ],
    core_bundle: [
      roots: ["apps/core"],
      package: [
        name: "root_core_bundle",
        otp_app: :root_core_bundle,
        version: "0.1.0",
        description: "Root core bundle"
      ],
      output: [
        docs: ["README.md"]
      ],
      verify: [
        artifact_tests: ["packaging/weld/core_bundle/test"]
      ]
    ]
  ]
]
