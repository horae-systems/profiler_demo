# Static WCET

Generate static WCET estimates and compare them with measured execution cycles.
Settings and justified flow facts are stored in `wcet\wcet_targets.json`.

The default configuration analyzes the eight `bench_*` functions in
`build\Debug\profiler_demo.elf` using the Cortex-M0+ timing model at 16 MHz.
The runner discovers loop offsets from the input ELF and applies the configured bounds;
there are no checked-in ELF-specific loop offsets or checksum.

The project [WCET Tool Validation report](../../../bb/hr/fusa/docs/reference/markdown/wcet_tool_validation.md)
assesses these benchmark records as validation inputs. Historical comparisons
do not automatically validate the application Cortex-M33 timing model.

## Usage

Run commands from the project root.
Requires WSL, the configured OTAWA environment, and a sibling `sewcet` checkout
(or its location in `SEWCET_DIR`). Comparison-only currently also initializes
that environment, but does not regenerate WCET or require an ELF input.

Generate a WCET CSV:

```powershell
.\wcet\run_wcet.ps1 -e .\build\Debug\profiler_demo.elf
```

Compare an existing measurement CSV against an existing WCET CSV:

```powershell
.\wcet\run_wcet.ps1 -cmp .\measured.csv .\wcet\wcet.csv
```

## Options

| Option | Aliases | Behavior |
|---|---|---|
| `-Elf <file.elf>` | `-e` | Generate WCET from the firmware ELF; a positional ELF is also accepted. Omit for comparison-only. |
| `-Out <file.csv>` | `-o`, `-Output` | Select the WCET output, or the comparison output in comparison-only mode. |
| `-Compare <measured.csv> [<wcet.csv>]` | `-cmp`, `-c` | With `-Elf`, compare measurements against the generated WCET. Without `-Elf`, supply both CSVs, measured first. |

Options are case-insensitive. Command-line relative paths use the current
directory. Without `-Out`, the WCET output uses `output_csv`, relative to the
configuration directory. Comparisons default to `wcet_<csv1>_vs_<csv2>.csv`
beside the second CSV, using filenames without extensions (for example,
`wcet_measured_vs_wcet.csv`). With `-Elf` and `-Compare`, `-Out` selects only
the WCET output; the comparison filename is generated automatically.

## Results and validity

The default output is `wcet\wcet.csv`, not the historical `1w.csv`/`2w.csv`.
A successful PowerShell generation also writes `wcet.csv.analysis.json` containing
ELF, configuration, and CSV SHA-256 hashes, timing model, clock, hook policy, and
function count. Keep the two files together; rerun after rebuilding the firmware.
Generated results and intermediate `work` files are Git-ignored.

The configured input bounds are conditional: `bench_fixed_loop_sum(count)` assumes
`count <= 25`, and `bench_crc8_fixed_block(data, length)` assumes `length <= 16`
with eight bit iterations per byte. These are demo-call constraints, not bounds for
arbitrary callers. Review the generated `.ff` files in `wcet\work` whenever code or
loop structure changes; shorthand bounds follow discovered loop order.

The WCET CSV contains one estimate per function: `calls` is 1 and
`total_cycles`, `min_cycles`, `max_cycles`, and `avg_cycles` hold the estimate.
Comparison matches function names and checks measured `max_cycles` against
the WCET, including any configured call-site or switch-overhead adjustments.

| Status | Meaning |
|---|---|
| `OK` | The observed maximum does not exceed the estimate. This does not prove the bound is valid. |
| `VIOLATION` | The observed maximum exceeds the estimate; investigate the model, flow facts, and measurement assumptions. |
| `NO_WCET` | No usable WCET value is available for a measured function. |

`ratio` is WCET divided by measured maximum; larger values indicate more margin.
The command returns a nonzero exit code on a violation or execution error.
Missing WCET values alone do not cause a nonzero exit code.

Measurements must correspond to the analyzed firmware and timing assumptions.
Check `instrumentation.include_profiler_hooks` for hook accounting; interrupt
preemption is not included in static WCET unless modeled through
`interference_functions`. Timing-model details are documented in the `sewcet` README.

Profiler hooks are explicitly excluded from static analysis. This does not make
the result directly equivalent to calibrated runtime telemetry: confirm build flags,
probe compensation, memory wait states, and execution scope before comparison.
Interrupt preemption is not modeled by the default configuration.
The nominal 100/500/1000-cycle benchmark bodies include function/prologue costs in
static analysis, so estimates need not equal their names.

After rebuilding, rerun `run_wcet.ps1`, review its flow facts and logs, and retain the
new analysis record. Do not interpret a successful run or an observed maximum below
an estimate as proof of a valid WCET bound.
