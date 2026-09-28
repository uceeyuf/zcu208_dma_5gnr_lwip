# project.tcl -- recreate the Vivado 2020.2 project from sources, build the bitstream and export the XSA.
#   cd <repo>
#   vivado -mode batch -source hw/project.tcl                      (full build, ~1 h)
#   vivado -mode batch -source hw/project.tcl -tclargs -bd_only    (project + block design only)
# Output: <repo>/build/vivado (project, runs), <repo>/build/design_1_wrapper.xsa (fixed platform, bitstream included).
set repo  [file normalize [file join [file dirname [info script]] ..]]
set build $repo/build
set bd_only [expr {[lsearch $argv -bd_only] >= 0}]
if {[version -short] ne "2020.2"} { puts "WARNING: written for Vivado 2020.2, running [version -short]" }
if {[file exists $build/vivado]} { error "$build/vivado exists -- delete it first (this script builds from scratch)" }

create_project zcu208_5gnr_lwip $build/vivado -part xczu48dr-fsvg1517-2-e
set_property board_part xilinx.com:zcu208:part0:2.0 [current_project]
set_property target_language Verilog [current_project]
add_files -fileset constrs_1 -norecurse $repo/hw/constraints/top.xdc

source $repo/hw/build_bd.tcl
cr_bd_design_1 ""                 ;# creates, validates, saves and closes design_1.bd
set bdf [get_files design_1.bd]
make_wrapper -files $bdf -top
add_files -norecurse [file join [file dirname $bdf] hdl design_1_wrapper.v]
set_property top design_1_wrapper [current_fileset]
update_compile_order -fileset sources_1
generate_target all $bdf
if {$bd_only} { puts "BD_ONLY_DONE"; return }

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} { error "implementation failed: [get_property STATUS [get_runs impl_1]]" }
open_run impl_1
report_timing_summary -file $build/timing_summary.rpt
report_utilization    -file $build/utilization.rpt
write_hw_platform -fixed -include_bit -force -file $build/design_1_wrapper.xsa
puts "HW_OK $build/design_1_wrapper.xsa"
