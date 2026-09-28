# build.tcl -- headless Vitis 2020.2 build of the lwIP 5G-NR play/capture application from sources only.
#   cd <repo>; xsct xsct/build.tcl            (after hw/project.tcl, or: xsct xsct/build.tcl <path/to/file.xsa>)
# 1) platform "rfsoc" from build/design_1_wrapper.xsa (standalone, A53-0, 64-bit) with the lwIP 2.1.1 BSP settings below
#    (skipped when build/vitis_ws/rfsoc/export already exists; settings in docs/lwip_settings.md);
# 2) the application is compiled and linked directly with the Vitis aarch64 toolchain against the exported BSP
#    (same flags as the Vitis-managed Debug build). The Vitis "app create" step is not used: run headless it stalls
#    after template generation (2026-09-27), and a plain compile is easier to reproduce.
# Output: build/vitis_ws/app/5gnr.elf and the platform FSBL. No JTAG access.
set root [file normalize [file join [file dirname [info script]] ..]]
set ws   $root/build/vitis_ws
set xsa  [expr {[llength $argv] ? [file normalize [lindex $argv 0]] : "$root/build/design_1_wrapper.xsa"}]
set src  $root/vitis/src
set bsp  $ws/rfsoc/export/rfsoc/sw/rfsoc/standalone_domain

if {![file exists $bsp/bsplib/lib/liblwip4.a]} {
    if {![file exists $xsa]} { error "XSA $xsa not found -- run hw/project.tcl first or pass an XSA path" }
    if {[file exists $ws]} { error "workspace $ws exists without a generated platform -- delete it first" }
    setws $ws
    platform create -name rfsoc -hw $xsa -proc psu_cortexa53_0 -os standalone -arch 64-bit -fsbl-target psu_cortexa53_0
    platform active rfsoc
    domain active standalone_domain
    bsp setlib -name lwip211
    foreach {k v} {
        api_mode            RAW_API
        lwip_dhcp           false
        dhcp_does_arp_check false
        tcp_snd_buf         65535
        tcp_wnd             65535
        mem_size            524288
        memp_n_pbuf         2048
        memp_n_tcp_seg      1024
        pbuf_pool_size      4096
        n_tx_descriptors    256
        n_rx_descriptors    256
    } { bsp config $k $v }
    bsp write
    bsp regenerate
    platform generate
}
foreach f [list $bsp/bsplib/lib/libxil.a $bsp/bsplib/lib/liblwip4.a $bsp/bsplib/lib/libmetal.a] {
    if {![file exists $f]} { error "BSP library $f missing -- platform generation failed" }
}

# ---- application: compile + link with the Vitis toolchain ----
set tc  [file join $::env(XILINX_VITIS) gnu aarch64 nt aarch64-none bin]
set gcc [file join $tc aarch64-none-elf-gcc.exe]
set out $ws/app
file mkdir $out/obj
set objs {}
foreach c [lsort [glob -directory $src *.c]] {
    set o $out/obj/[file rootname [file tail $c]].o
    exec -ignorestderr $gcc -Wall -O0 -g3 -c -fmessage-length=0 -D __BAREMETAL__ -I$bsp/bspinclude/include -o $o $c
    lappend objs $o
}
set elf $out/5gnr.elf
exec -ignorestderr $gcc -Wl,-T -Wl,$src/lscript.ld -L$bsp/bsplib/lib -o $elf {*}$objs \
    -lm -Wl,--start-group,-lxil,-llwip4,-lmetal,-lgcc,-lc,--end-group
puts [exec [file join $tc aarch64-none-elf-size.exe] $elf]
puts "BUILD_OK $elf"
