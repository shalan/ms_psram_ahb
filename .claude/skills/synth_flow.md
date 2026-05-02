---
name: synth_flow
description: Run synthesis, STA, and GLS via synth_flow.py
triggers:
  - synthesize
  - synthesis
  - run sta
  - run sta
  - timing analysis
  - multi-corner
  - gate-level simulation
  - gls
  - hierarchical synthesis
  - recipe sweep
  - ppa
---

# synth_flow Skill

## Overview

This project uses `synth_flow/synth_flow.py` — a generic ASIC synthesis + STA + GLS
orchestrator built on Yosys + ABC, OpenSTA, and iverilog.

## Key Files

- **Tool**: `synth_flow/synth_flow.py`
- **Config**: `synth.yaml` (project root)
- **Recipes**: `synth_flow/recipes/*.abc`
- **Results**: `results/summary.{md,json,csv}`, `results/<module>/winner.v`

## Commands

### Flat synthesis (single top module)

```bash
python3 synth_flow/synth_flow.py --config synth.yaml -vv
```

### Hierarchical bottom-up synthesis

```bash
python3 synth_flow/synth_flow.py --config synth.yaml --hierarchical \
    --modules psram_ctrl ahb_slave_if psram_cache psram_csr ms_psram_ahb -vv
```

### List auto-detected modules

```bash
python3 synth_flow/synth_flow.py --config synth.yaml --list-modules
```

### Specific objective or recipes

```bash
python3 synth_flow/synth_flow.py --config synth.yaml --objective area -vv
python3 synth_flow/synth_flow.py --config synth.yaml --objective delay --recipes fast balanced retime_delay -vv
```

### Skip STA or GLS

```bash
python3 synth_flow/synth_flow.py --config synth.yaml --no-sta -vv
python3 synth_flow/synth_flow.py --config synth.yaml --no-gls -vv
```

## Config (synth.yaml)

The config file contains:
- `rtl_files`: list of RTL source files (supports globs)
- `lib_typ`, `lib_fast`, `lib_slow`: liberty files for TT/FF/SS corners
- `cell_blackbox`: Verilog blackbox stubs for library cells (needed for hierarchical mode)
- `top`: top module name
- `period_ps`: target clock period in picoseconds
- `clock_port`: clock port name
- `objective`: `delay` | `area` | `fastest` | `pareto` | `balanced`
- `driving_cell`, `load_ff`: ABC constraints
- `run_sta`, `run_gls`: enable/disable steps

## Objectives

- `delay`: maximize timing slack (WNS), then minimize area
- `area`: minimize area among recipes that meet timing (WNS >= 0)
- `fastest`: max WNS among timing-meeting recipes (lowest delay)
- `balanced`: equal-weight rank score on WNS and area
- `pareto`: report Pareto front, pick max-WNS representative

## Recipes

14 ABC recipes in `synth_flow/recipes/`. Not all recipes work with every ABC
build — some require commands like `rewrite`, `refactor`, `balance` that may
be missing. Failed recipes are excluded from winner selection automatically.

Working recipes for this project's ABC build: `fast`, `balanced`, `delay4`,
`delay_choice`, `retime_delay`.

## STA Corners

The tool runs 4 STA checks on each winning netlist:

| Check | Corner | Condition |
|-------|--------|-----------|
| Setup | SS | 100°C, 1.60V |
| Setup | TT | 25°C, 1.80V |
| Hold | FF | -40°C, 1.95V |
| Hold | TT | 25°C, 1.80V |

OpenSTA 2.6.0 limitation: `report_worst_slack` does not accept `-corner`.
For SS/FF sections the global worst is correct (slow=worst setup, fast=worst
hold). For TT sections, slack is parsed from `report_checks -corner typical`
path output.

## Hierarchical Mode Details

When `--hierarchical` is enabled:
1. Auto-detects module instantiation dependencies from RTL
2. Topological sort: leaves synthesized first, root last
3. Parent modules read sub-module winner netlists (gate-level) + remaining RTL
4. Parameter overrides (`#(.PARAM(val))`) are automatically stripped from
   instantiations of pre-synthesized sub-modules
5. Requires `cell_blackbox` in config pointing to library blackbox Verilog

## Exit Codes

- 0: success
- 1: synthesis failed
- 2: timing violation (setup at SS)
- 3: GLS failed
- 4: config error

## Modifying the Tool

When modifying `synth_flow/synth_flow.py`:
- Always test with `python3 synth_flow/synth_flow.py --config synth.yaml -vv`
- The tool must remain generic — no project-specific logic
- Config changes go in the `Config` dataclass + `from_yaml()` + `validate()`
- New STA features go in `CORNER_STA_TCL` template + `CornerResult` + parsing
- New Yosys flows go in driver templates (`YOSYS_DRIVER_STD`, etc.)
- Run `python3 -c "import synth_flow.synth_flow"` to check for syntax errors

## Common Workflows

### Quick area check during RTL development
```bash
python3 synth_flow/synth_flow.py --config synth.yaml --objective area --recipes fast --no-gls -vv
```

### Full PPA sweep for tape-off
```bash
python3 synth_flow/synth_flow.py --config synth.yaml --objective pareto -vv
```

### Per-module area breakdown
```bash
python3 synth_flow/synth_flow.py --config synth.yaml --hierarchical \
    --modules psram_ctrl ahb_slave_if psram_cache psram_csr ms_psram_ahb \
    --no-gls -vv
```

### Check results after run
```bash
cat results/summary.md
```
