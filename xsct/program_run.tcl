# program_run.tcl -- program the PL, run the FSBL, start the lwIP application (Vitis 2020.2 xsct, hw_server running).
#   cd <repo>; xsct xsct/program_run.tcl      (hw_server running, board in JTAG boot mode)
# Requires xsct/build.tcl to have run. The board then serves 192.168.1.10:7000 (see docs); the waveform is
# written over Ethernet by the host, so no JTAG data download is needed here.
# -no-revision-check (as in the Vitis-generated launch script): skip the silicon-revision check of "fpga" (docs/board_revision.md).
set root [file normalize [file join [file dirname [info script]] ..]]
set ws   $root/build/vitis_ws
set bit  [lindex [concat [glob -nocomplain $ws/rfsoc/export/rfsoc/hw/*.bit] [glob -nocomplain $ws/rfsoc/hw/*.bit]] 0]
set fsbl $ws/rfsoc/export/rfsoc/sw/rfsoc/boot/fsbl.elf
set elf  $ws/app/5gnr.elf
foreach f [list $bit $fsbl $elf] { if {$f eq "" || ![file exists $f]} { error "missing build output '$f' -- run xsct/build.tcl first" } }

connect -url tcp:127.0.0.1:3121
source [file join $::env(XILINX_VITIS) scripts vitis util zynqmp_utils.tcl]
targets -set -nocase -filter {name =~ "APU*"}
rst -system
after 3000
targets -set -nocase -filter {name =~ "PSU"}
fpga -file $bit -no-revision-check
targets -set -nocase -filter {name =~ "APU*"}
loadhw -hw $ws/rfsoc/export/rfsoc/hw/design_1_wrapper.xsa -mem-ranges [list {0x80000000 0xbfffffff} {0x400000000 0x5ffffffff} {0x1000000000 0x7fffffffff}] -regs
configparams force-mem-access 1
targets -set -nocase -filter {name =~ "*A53*#0"}
rst -processor
dow $fsbl
set bp [bpadd -addr &XFsbl_Exit]
con -block -timeout 60
bpremove $bp
targets -set -nocase -filter {name =~ "*A53*#0"}
rst -processor
dow $elf
configparams force-mem-access 0
con
puts "RUNNING $elf"
