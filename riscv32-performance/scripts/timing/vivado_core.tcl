# Pure CPU comparison only. This is not a board-level timing signoff.
# vivado -mode batch -source vivado_core.tcl -tclargs RTL_DIR OUTPUT_DIR PERIOD_NS
if {$argc < 2} {
    error "Usage: vivado_core.tcl RTL_DIR OUTPUT_DIR ?PERIOD_NS?"
}
set rtl_dir [file normalize [lindex $argv 0]]
set output_dir [file normalize [lindex $argv 1]]
set period_ns 6.667
if {$argc >= 3} {set period_ns [lindex $argv 2]}
file mkdir $output_dir
set_param general.maxThreads 4
create_project -in_memory -part xc7k325tffg900-2
set source_names {
    alu.sv branch_predictor.sv branch_unit.sv control.sv ex_mem.sv
    forwarding.sv hazard_detection.sv id_ex.sv if_id.sv immgen.sv
    mem_wb.sv myCPU.sv pc.sv regfile.sv
}
foreach name $source_names {read_verilog -sv [file join $rtl_dir $name]}
synth_design -top myCPU -mode out_of_context -flatten_hierarchy rebuilt
create_clock -name cpu_clk -period $period_ns [get_ports cpu_clk]
# External memories/peripherals are absent: report CPU register paths separately.
set_false_path -from [get_ports cpu_rst]
set nonclock_inputs [get_ports -filter {DIRECTION == IN && NAME != cpu_clk && NAME != cpu_rst}]
set_input_delay 0.0 -clock cpu_clk $nonclock_inputs
set_output_delay 0.0 -clock cpu_clk [all_outputs]
report_utilization -hierarchical -file [file join $output_dir utilization_synth.rpt]
write_checkpoint -force [file join $output_dir cpu_synth.dcp]
opt_design
place_design -directive Explore
phys_opt_design -directive Explore
route_design -directive Explore
report_utilization -hierarchical -file [file join $output_dir utilization_routed.rpt]
report_timing_summary -delay_type min_max -report_unconstrained -max_paths 10 \
    -file [file join $output_dir timing_summary.rpt]
set cpu_registers [all_registers -clock cpu_clk]
report_timing -from $cpu_registers -to $cpu_registers \
    -max_paths 30 -nworst 2 -path_type full_clock_expanded \
    -file [file join $output_dir cpu_register_paths.rpt]
set report_file [open [file join $output_dir cpu_paths.tsv] w]
set tab [format %c 9]
puts $report_file [join {slack_ns datapath_delay_ns logic_levels startpoint endpoint} $tab]
foreach timing_path [get_timing_paths -from $cpu_registers -to $cpu_registers -delay_type max -max_paths 30 -nworst 2] {
    puts $report_file [join [list [get_property SLACK $timing_path] [get_property DATAPATH_DELAY $timing_path] [get_property LOGIC_LEVELS $timing_path] [get_property STARTPOINT_PIN $timing_path] [get_property ENDPOINT_PIN $timing_path]] $tab]
}
close $report_file
write_checkpoint -force [file join $output_dir cpu_routed.dcp]
puts "CPU_COMPARISON_COMPLETE: $output_dir"
exit
