[
  schema: 2,
  workspace: [
    root: "../..",
    projects: ["core/*", "apps/*"]
  ],
  dependencies: [
    external_lib: [requirement: "~> 1.2.0"],
    git_only: [requirement: "~> 0.5.0"]
  ],
  artifacts: [
    app_bundle: [
      layout: :components,
      roots: ["apps/app"],
      package: [
        name: "app_bundle",
        otp_app: :app_bundle,
        version: "0.1.0",
        description: "External dependency fixture"
      ],
      files: [
        docs: ["README.md"]
      ]
    ]
  ]
]
