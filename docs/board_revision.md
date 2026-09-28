# Board and silicon revision

The design was built and tested on one ZCU208 with this device (read over JTAG):

| Register | Value | Meaning |
|---|---|---|
| JTAG IDCODE (`0xFFCA0040`) | `0x047FB093` | XCZU48DR, IDCODE revision field 0 |
| CSU_VERSION (`0xFFCA0044`) | `0x00000513` | PS version field 3 |

The block design sets `PSU_VALUE_SILVERSION` to 3 in the Zynq UltraScale+ PS configuration.

`xsct/program_run.tcl` programs the bitstream with `fpga -file ... -no-revision-check`. This is how the
Vitis-generated launch scripts for this board program it. The option skips the tool's silicon-revision check. If
your board carries a different silicon revision, check the PS configuration (`PSU_VALUE_SILVERSION`) in
`hw/build_bd.tcl` against it before building.

To read your own values:

```tcl
connect
targets -set -nocase -filter {name =~ "PSU"}
mrd -force 0xFFCA0040
mrd -force 0xFFCA0044
```
