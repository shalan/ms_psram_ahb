# SPDX-License-Identifier: Apache-2.0
# Author: Mohamed Shalan <mshalan@aucegypt.edu>

.PHONY: rtl-sim gl-sim gls-sdf synth syn-flat syn-hier sta clean

TOP      := ms_psram_ahb
PERIOD   := 8
CLK_PORT := hclk

YOSYS    := yosys
STA      := /nix/store/2ia51h09wfm9qpm9dg3zq52cr578ah61-opensta/bin/sta
IVERILOG := iverilog
VVP      := vvp

LIB_TT   := synth_flow/sky130/hd_124_ss.lib
LIB_FF   := $(shell ls /Users/mshalan/work/pdks/volare/ciel/sky130/versions/*/sky130A/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__ff_n40C_1v95.lib 2>/dev/null | head -1)
LIB_SS   := $(shell ls /Users/mshalan/work/pdks/volare/ciel/sky130/versions/*/sky130A/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__ss_100C_1v60.lib 2>/dev/null | head -1)
CELL_V   := synth_flow/sky130/sky130_hd-clean.v
ABC_CONSTR := synth_flow/sky130/abc_constr.txt

RTL_SRCS := rtl/psram_csr.v rtl/psram_cache.v rtl/psram_ctrl.v rtl/ahb_slave_if.v rtl/ms_psram_ahb.v

DV_DIR    := dv
TMP       := tmp

# =============================================================================
# RTL Simulation
# =============================================================================

TB_APS64    := tb_ms_psram_ahb
TB_23LC     := tb_ms_psram_ahb_23lc512
TB_CACHE    := tb_psram_cache
TB_CSR      := tb_psram_csr

rtl-sim: $(TMP)/$(TB_APS64).vvp $(TMP)/$(TB_23LC).vvp $(TMP)/$(TB_CACHE).vvp $(TMP)/$(TB_CSR).vvp
	@echo "=== RTL Simulation ==="
	@for tb in $(TB_APS64) $(TB_23LC) $(TB_CACHE) $(TB_CSR); do \
		echo "--- $$tb ---"; \
		$(VVP) -N $(TMP)/$$tb.vvp 2>&1 | grep -E 'PASS|FAIL|ERROR|check'; \
	done

$(TMP)/$(TB_APS64).vvp: $(RTL_SRCS) $(DV_DIR)/$(TB_APS64).v $(DV_DIR)/23A512.v | $(TMP)/
	$(IVERILOG) -g2005 -o $@ $(DV_DIR)/23A512.v $(RTL_SRCS) $(DV_DIR)/$(TB_APS64).v

$(TMP)/$(TB_23LC).vvp: $(RTL_SRCS) $(DV_DIR)/$(TB_23LC).v $(DV_DIR)/23LC512.v | $(TMP)/
	$(IVERILOG) -g2005 -o $@ $(DV_DIR)/23LC512.v $(RTL_SRCS) $(DV_DIR)/$(TB_23LC).v

$(TMP)/$(TB_CACHE).vvp: $(RTL_SRCS) $(DV_DIR)/$(TB_CACHE).v | $(TMP)/
	$(IVERILOG) -g2005 -o $@ $(RTL_SRCS) $(DV_DIR)/$(TB_CACHE).v

$(TMP)/$(TB_CSR).vvp: $(RTL_SRCS) $(DV_DIR)/$(TB_CSR).v | $(TMP)/
	$(IVERILOG) -g2005 -o $@ $(RTL_SRCS) $(DV_DIR)/$(TB_CSR).v

# =============================================================================
# Synthesis — flat and hierarchical via synth_flow.py
# =============================================================================

NETLIST := syn/$(TOP).gl.v
SDF     := syn/$(TOP).sdf
SWEEP_WORK   := work
SWEEP_RESULT := results

syn-flat: syn/synth_flat.yaml $(RTL_SRCS)
	@echo "=== Flat synthesis (recipe sweep) ==="
	python3 synth_flow/synth_flow.py --config syn/synth_flat.yaml \
		--work-dir $(SWEEP_WORK) --results-dir $(SWEEP_RESULT) \
		--no-gls
	@echo ""
	@echo "=== Flat Synthesis Results ==="
	@cat $(SWEEP_RESULT)/summary.md
	@echo ""
	@echo "=== Area Report ==="
	@python3 synth_flow/area_report.py \
		$(SWEEP_RESULT)/$(TOP)/winner.v $(LIB_TT)
	@echo ""
	@echo "Copying winner netlist → $(NETLIST)"
	@cp $(SWEEP_RESULT)/$(TOP)/winner.v $(NETLIST)

syn-hier: syn/synth_hier.yaml $(RTL_SRCS)
	@echo "=== Hierarchical synthesis (bottom-up recipe sweep) ==="
	python3 synth_flow/synth_flow.py --config syn/synth_hier.yaml \
		--hierarchical \
		--work-dir $(SWEEP_WORK) --results-dir $(SWEEP_RESULT) \
		--no-gls
	@echo ""
	@echo "=== Hierarchical Synthesis Results ==="
	@cat $(SWEEP_RESULT)/summary.md
	@echo ""
	@echo "=== Area Report ==="
	@python3 synth_flow/area_report.py \
		$(SWEEP_RESULT)/$(TOP)/winner.v $(LIB_TT)
	@echo ""
	@echo "Copying winner netlist → $(NETLIST)"
	@cp $(SWEEP_RESULT)/$(TOP)/winner.v $(NETLIST)

synth: $(NETLIST) $(TMP)/area_report.txt
	@echo ""
	@echo "=== Synthesis done: $(NETLIST) ==="
	@cat $(TMP)/area_report.txt

$(NETLIST): $(RTL_SRCS) $(LIB_TT) $(ABC_CONSTR) | $(TMP)/
	$(YOSYS) -p " \
		read_verilog $(RTL_SRCS); \
		hierarchy -top $(TOP) \
			-chparam SPI_CLK_DIV 2 \
			-chparam QUAD_EN 1 \
			-chparam ADDR_WIDTH 23 \
			-chparam INIT_DLY 16'd5000 \
			-chparam RST_DLY 16'd2500 \
			-chparam CACHE_EN 1 \
			-chparam CACHE_INDEX_BITS 4; \
		synth -top $(TOP) -flatten -noabc; \
		write_verilog -noattr $(TMP)/$(TOP).syn.v; \
		dfflibmap -liberty $(LIB_TT); \
		abc -liberty $(LIB_TT) -constr $(ABC_CONSTR) -D $(PERIOD); \
		opt_clean; clean; opt; \
		tee -o $(TMP)/synth_stats.txt stat -liberty $(LIB_TT); \
		write_verilog -noattr -noexpr -nodec $@; \
	"

$(TMP)/area_report.txt: $(NETLIST) | $(TMP)/
	@python3 synth_flow/area_report.py $(NETLIST) $(LIB_TT) > $@

# =============================================================================
# STA (multi-corner: TT setup+hold, SS setup, FF hold)
# =============================================================================

sta: $(TMP)/sta_report.txt
	@echo "=== STA Results ==="
	@cat $<

$(TMP)/sta.tcl: | $(TMP)/
	@echo 'define_corners fast typical slow' > $@
	@echo 'read_liberty -corner fast $(LIB_FF)' >> $@
	@echo 'read_liberty -corner typical $(LIB_TT)' >> $@
	@echo 'read_liberty -corner slow $(LIB_SS)' >> $@
	@echo 'read_verilog $(NETLIST)' >> $@
	@echo 'link_design $(TOP)' >> $@
	@echo 'create_clock -name clk -period $(PERIOD) [get_ports $(CLK_PORT)]' >> $@
	@echo 'set_driving_cell -lib_cell sky130_fd_sc_hd__inv_1 [all_inputs]' >> $@
	@echo 'set_load 0.033 [all_outputs]' >> $@
	@echo 'set_input_delay  -clock clk [expr {$(PERIOD) * 0.2}] [all_inputs]' >> $@
	@echo 'set_output_delay -clock clk [expr {$(PERIOD) * 0.2}] [all_outputs]' >> $@
	@echo 'catch { set_false_path -from [get_ports hresetn] }' >> $@
	@echo 'catch { set_false_path -from [get_ports rst_n] }' >> $@
	@echo 'puts ">>> SETUP_SLOW_BEGIN"' >> $@
	@echo 'report_checks -path_delay max -corner slow -group_count 5 -format full_clock' >> $@
	@echo 'report_worst_slack -max' >> $@
	@echo 'report_tns' >> $@
	@echo 'puts ">>> SETUP_SLOW_END"' >> $@
	@echo 'puts ">>> SETUP_TYP_BEGIN"' >> $@
	@echo 'report_checks -path_delay max -corner typical -group_count 5 -format full_clock' >> $@
	@echo 'report_worst_slack -max' >> $@
	@echo 'report_tns' >> $@
	@echo 'puts ">>> SETUP_TYP_END"' >> $@
	@echo 'puts ">>> HOLD_FAST_BEGIN"' >> $@
	@echo 'report_checks -path_delay min -corner fast -group_count 5 -format full_clock' >> $@
	@echo 'report_worst_slack -min' >> $@
	@echo 'report_tns' >> $@
	@echo 'puts ">>> HOLD_FAST_END"' >> $@
	@echo 'puts ">>> HOLD_TYP_BEGIN"' >> $@
	@echo 'report_checks -path_delay min -corner typical -group_count 5 -format full_clock' >> $@
	@echo 'report_worst_slack -min' >> $@
	@echo 'report_tns' >> $@
	@echo 'puts ">>> HOLD_TYP_END"' >> $@
	@echo 'write_sdf -corner slow $(SDF)' >> $@
	@echo 'exit' >> $@

$(TMP)/sta_report.txt: $(NETLIST) $(TMP)/sta.tcl
	$(STA) -no_init -exit $(TMP)/sta.tcl > $@ 2>&1

# =============================================================================
# Gate-Level Simulation (no SDF)
# =============================================================================

TB_GLS := tb_ms_psram_ahb_gls

gl-sim: $(TMP)/gls.vvp
	@echo "=== GLS (no SDF) ==="
	$(VVP) -N $< 2>&1 | grep -E 'PASS|FAIL|ERROR|check'

$(TMP)/gls.vvp: $(NETLIST) $(DV_DIR)/$(TB_GLS).v $(CELL_V) | $(TMP)/
	$(IVERILOG) -g2005 -o $@ $(CELL_V) $(NETLIST) $(DV_DIR)/$(TB_GLS).v

# =============================================================================
# Gate-Level Simulation with SDF back-annotation
# =============================================================================

gls-sdf: $(TMP)/gls_sdf.vvp $(SDF)
	@echo "=== GLS with SDF ==="
	$(VVP) -N $< +sdf_$(TOP)=$(SDF) 2>&1 | grep -E 'PASS|FAIL|ERROR|check|SDF'

$(TMP)/gls_sdf.vvp: $(NETLIST) $(DV_DIR)/$(TB_GLS).v $(CELL_V) | $(TMP)/
	$(IVERILOG) -g2005 -o $@ $(CELL_V) $(NETLIST) $(DV_DIR)/$(TB_GLS).v

# =============================================================================
# Clean
# =============================================================================

clean:
	rm -rf $(TMP)/ $(SWEEP_WORK)/ $(SWEEP_RESULT)/

$(TMP)/:
	mkdir -p $@
