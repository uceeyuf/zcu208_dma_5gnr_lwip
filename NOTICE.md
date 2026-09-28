# Provenance and third-party material

- This design is modified from the **Xilinx RFSoC starter design** (ZCU111 DMA play/capture, Rev A, 2020): the block
  design, the DMA play/capture application structure and the console (`vitis/src`: `main.c`, `cli.c`, `play_dma.c`,
  `cap_dma.c`, `cmd_*.c`, `adc*FreezeCal.c`, `rfdc_*.c`, `LMK/LMX_display.c`) come from it. Changes here: port to
  the ZCU208 and to Vivado/Vitis 2020.2, 5G NR sample rates and RF plan, and Ethernet (lwIP) control and data transfer.
  Original author tags in the file headers are kept.
- `xrfclk.c/.h`, `xrfclk_LMK_conf.h`, `xrfclk_LMX_conf.h`, `xrfdc_clk.c/.h` are Xilinx files under the permission
  notice in their headers.
- The Ethernet path (`net_server.c/.h`, the lwIP set-up in `main.c`) and the host MATLAB library are new.
- The 5G NR helper functions used by `host/matlab/demo_5gnr_loopback.m` (`hNRReferenceWaveformGenerator`,
  `hNRDownlinkEVM`) belong to MathWorks and are not included; the demo opens the MathWorks example that ships them.

## Licence scope

The new work in this repository is released under the BSD 3-Clause licence ([LICENSE](LICENSE)): the Ethernet server,
the lwIP integration, the build scripts, the host MATLAB library and the documentation. Files derived from the Xilinx
RFSoC starter design and the Xilinx-copyright files keep their original author and copyright headers and terms.
