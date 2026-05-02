# SPDX-License-Identifier: Apache-2.0
# Author: Mohamed Shalan <mshalan@aucegypt.edu>
#
# SDC constraints for PSRAM AHB Controller
# Target: Sky130 HD, 8 ns period (125 MHz)

# Clock definition
create_clock -name hclk -period 8.0 [get_ports hclk]

# Clock uncertainty (jitter + margin)
set_clock_uncertainty -setup 0.5 [get_clocks hclk]
set_clock_uncertainty -hold  0.2 [get_clocks hclk]

# Reset is asynchronous
set_false_path -from [get_ports hresetn]

# AHB input delays — inputs arrive from same clock domain
set_input_delay -clock hclk -max 3.2 [get_ports {hsel haddr htrans hwrite hsize hburst hwdata hready}]
set_input_delay -clock hclk -min 0.8 [get_ports {hsel haddr htrans hwrite hsize hburst hwdata hready}]

# AHB output delays
set_output_delay -clock hclk -max 3.2 [get_ports {hrdata hreadyout hresp}]
set_output_delay -clock hclk -min 0.8 [get_ports {hrdata hreadyout hresp}]

# SPI outputs — off-chip, relaxed timing
set_output_delay -clock hclk -max 4.0 [get_ports {spi_cs_n spi_sclk spi_sio_o spi_sio_oe}]
set_output_delay -clock hclk -min 0.8 [get_ports {spi_cs_n spi_sclk spi_sio_o spi_sio_oe}]

# SPI inputs — off-chip, relaxed input timing
set_input_delay -clock hclk -max 4.0 [get_ports {spi_sio_i}]
set_input_delay -clock hclk -min 0.8 [get_ports {spi_sio_i}]

# Input transition times
set_input_transition -max 0.4 [all_inputs]
set_input_transition -min 0.1 [all_inputs]

# Output loads (picofarads)
set_load -max 0.033 [all_outputs]
set_load -min 0.005 [all_outputs]

# Driving cell
set_driving_cell -lib_cell sky130_fd_sc_hd__inv_1 [all_inputs]
