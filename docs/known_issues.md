# Known issues

**Clone into a short path (Windows).** The RF data converter IP generates file names of about 150 characters under
`build/vivado/*.gen/`. A checkout in a deep folder exceeds the 260-byte Windows path limit, and `hw/project.tcl` fails
with `[Common 17-680] Path length exceeds 260-Byte maximum`. A path such as `C:\w\zcu208_5gnr` works.

**Vitis `app create` stalls when run headless.** On Vitis 2020.2 (Windows), `xsct` with `app create` generates the
application template and then waits forever with an idle CPU. `xsct/build.tcl` therefore creates only the platform and
BSP with XSCT, and compiles and links the application directly with the Vitis aarch64 toolchain. The flags match the
Vitis Debug configuration. The resulting ELF matches a Vitis-IDE build of the same sources to within 76 bytes of text.

**`fpga -no-revision-check`.** `xsct/program_run.tcl` programs the bitstream with `-no-revision-check`, as the
Vitis-generated launch script does. See `board_revision.md`.

**DAC and ADC NCOs are not co-sourced.** The transmit and receive mixers are programmed independently, so the capture
carries a small residual frequency offset. The EVM receiver in `demo_5gnr_loopback.m` corrects coarse and fine
frequency offset. Do not assume a fixed phase between playback and capture.

**Capture buffer check.** `play_capture_eth.m` writes a canary pattern into the capture buffer before `adcCapture`. If
the canary is still present after read-back, the ADC DMA did not write, and the function warns.

**READ only from memory, not from AXI-Lite registers.** The server sends READ data straight from the requested address
with the Ethernet DMA. That works for DDR and for block RAM behind an AXI BRAM controller. A READ of an AXI-Lite
peripheral such as an AXI GPIO register makes the connection fail, and the network stack may need a reboot to recover.
Read such registers through the processor instead, for example with `xsct mrd` over JTAG or with a console command.
WRITE to AXI-Lite registers is fine: the server writes word by word with the processor.

**lwIP buffer pool.** Every RX descriptor holds one pool buffer. `pbuf_pool_size` must therefore be well above
`n_rx_descriptors` (`xsct/build.tcl` sets 4096 against 256). A pool equal to the descriptor count leaves no spare
buffer ("unable to alloc pbuf in recv_handler" on the UART), frames are dropped under load, and connections fail.
Note that `pbuf_pool_bufsize` is the size of each buffer, not their number.

**Host network.** The board uses the static address 192.168.1.10, port 7000. Give the host NIC a static address in
192.168.1.0/24, and allow outbound TCP to that port in the host firewall.
