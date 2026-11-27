# Metadata-heavy tests launch up to four child VMs per active module. Bound
# fanout by default; Mix's --max-cases remains an explicit override.
max_cases = System.schedulers_online() |> div(4) |> max(1) |> min(6)
ExUnit.start(exclude: [:integration, :slow], max_cases: max_cases)
