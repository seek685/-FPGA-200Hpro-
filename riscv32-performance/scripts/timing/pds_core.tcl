# Set CPU_RTL_DIR and CPU_TIMING_DIR before invoking pds_shell -file this file.
# Pure CPU only; no NPU sources, board project, or bitstream generation.
set rtl_dir [file normalize $env(CPU_RTL_DIR)]
set output_dir [file normalize $env(CPU_TIMING_DIR)]
set_arch -family Logos2 -device PG2L200H -speedgrade -6 -package FBB676
set source_names {
    alu.sv branch_predictor.sv branch_unit.sv control.sv ex_mem.sv
    forwarding.sv hazard_detection.sv id_ex.sv if_id.sv immgen.sv
    mem_wb.sv myCPU.sv pc.sv regfile.sv
}
foreach name $source_names {add_design [file join $rtl_dir $name]}
add_constraint [file join $output_dir cpu.fdc]
compile -system_verilog -beta_feature_for_verilog -loop_limit 8192 -top_module myCPU
synthesize -ads -frequency 150
dev_map -detail
pnr -number_of_router_thread 4 -action_timeout 5
report_timing -max_path 20 -nworst 2
puts "CPU_COMPARISON_COMPLETE: $output_dir"
exit
