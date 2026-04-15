#!/bin/bash

# Sätter TRACE till första argumentet, eller NO om inget anges
TRACE=$1
if [ -z "$1" ]; then
  TRACE=NO
fi

# Första testet körs med YES som tredje argument
# Running Diagnostic Configurator
./build_hp2116.sh diagnostics/24296-60001_DSN000200_DIAGNOSTIC_CONFIGURATOR.abin 000200 YES $TRACE 

# Running Memory Reference Instruction Group diagnostic
./build_hp2116.sh diagnostics/24315-16001_DSN101100_MEMORY_REFERENCE_INSTRUCTION_GROUP.abin 101100 NO $TRACE

# Running Alter Skip Instruction Group diagnostic
./build_hp2116.sh diagnostics/24316-16001_DSN101001_ALTER_SKIP_INSTRUCTION_GROUP.abin 101001 NO $TRACE

# Running Shift Rotate Instruction Group diagnostic
./build_hp2116.sh diagnostics/24317-16001_DSN101002_SHIFT_ROTATE_INSTRUCTION_GROUP.abin 101002 NO $TRACE

# Running the old DMA test by loading it directly into memory
./build_hp2116.sh diagnostics/24296-60001_DSN000200_DIAGNOSTIC_CONFIGURATOR.abin 000200 YES $TRACE diagnostics/24185-60001_Rev-A.abin


# Running Core Memory diagnostic - taking too long to execute
#./build_hp2116.sh diagnostics/24323-16001_DSN102200_CORE_MEMORY_2100_16_15_14.abin 102200 NO $TRACE

# Running Semiconductor Memory diagnostic - diag failed
#./build_hp2116.sh diagnostics/24395-16001_DSN102104_SEMICONDUCTOR_MEMORY_21MX.abin 102104 NO $TRACE

# Running EAU Instruction Group diagnostic - diag failed - EAU not implemented
#./build_hp2116.sh diagnostics/24319-16001_DSN101004_EAU_INSTRUCTION_GROUP.abin 101004 NO $TRACE

# Running Floating Point Instruction Group diagnostic - diag failed - not implemented
#./build_hp2116.sh diagnostics/24320-16001_DSN101207_FLOATING_POINT_INSTRUCTION_GROUP.abin 101207 NO $TRACE

# Running Mem Prot/Parity Error diagnostic - diag failed - not implemented
#./build_hp2116.sh diagnostics/12892-16001_DSN102305_MEM_PROT_PARITY_ERROR_2100_21MX.abin 102305 NO $TRACE

# Running Power Fail Auto Restart diagnostic - waiting for input?
#./build_hp2116.sh diagnostics/24321-16001_DSN101206_POWER_FAIL_AUTO_RESTART.abin 101206 NO $TRACE

# Running I/O Instruction Group I/O Channel Extender diagnostic - diag failed - didn't load properly
#./build_hp2116.sh diagnostics/24318-16001_DSN141103_I_O_INSTR_GROUP_I_O_CHANNEL_EXTENDER.abin 141103 NO $TRACE

# Running General Purpose Register diagnostic - diag failed - not implemented
./build_hp2116.sh diagnostics/24391-16001_DSN143300_GENERAL_PURPOSE_REGISTER.abin 143300 NO $TRACE

# Running Direct Memory Access diagnostic - diag failed - not implemented
#./build_hp2116.sh diagnostics/24322-16002_DSN101220_DIRECT_MEMORY_ACCESS_2100_21MX.abin 101220 NO $TRACE

# Running Extended Instruction Group (Index) diagnostic - diag failed - not implemented
#./build_hp2116.sh diagnostics/12943-16002_DSN101011_EXT_INSTR_GROUP_INDEX.abin 101011 NO $TRACE

# Running Extended Instruction Group (Word, Byte, Bit) diagnostic - diag failed - not implemented
#./build_hp2116.sh diagnostics/12943-16001_DSN101112_EXT_INSTR_GROUP_WORDBYTEBIT.abin 101112 NO $TRACE

# Running 2100 Fast Fortran Package diagnostic - diag failed - not implemented
#./build_hp2116.sh diagnostics/12907-16003_DSN101110_2100_FAST_FORTRAN_PACKAGE.abin 101110 NO $TRACE

# Running M/E-Series Fast Fortran Package 1 diagnostic - diag failed - not implemented
#./build_hp2116.sh diagnostics/12977-16004_DSN101213_M_E_SERIES_FAST_FORTRAN_PACKAGE_1.abin 101213 NO $TRACE

# Running M/E-Series Fast Fortran Package 2 diagnostic - diag failed - not implemented
#./build_hp2116.sh diagnostics/12977-16005_DSN101114_M_E_SERIES_FAST_FORTRAN_PACKAGE_2.abin 101114 NO $TRACE

# Running F-Series FPP/SIS/FFP diagnostic  - diag failed - not implemented
#./build_hp2116.sh diagnostics/12740-16001_DSN101121_F_SERIES_FPP_SIS_FFP.abin 101121 NO $TRACE

# Running Memory Expansion Unit diagnostic - diag failed - not implemented
#./build_hp2116.sh diagnostics/12929-16001_DSN102103_MEMORY_EXPANSION_UNIT.abin 102103 NO $TRACE

# Running Semiconductor Memory, Microcoded F.21MX diagnostic - diag failed - not implemented
#./build_hp2116.sh diagnostics/24395-16002_DSN102006_SEMICONDUCTOR_MEMORY_MICROCODED_F21MX.abin 102006 NO $TRACE

# Running Time Base Generator diagnostic - diag failed - not implemented
#./build_hp2116.sh diagnostics/12539-16001_DSN103301_TIME_BASE_GENERATOR.abin 103301 NO $TRACE

# Running 12936 Privileged Interrupt diagnostic - diag failed - not implemented
#./build_hp2116.sh diagnostics/12936-16001_DSN103115_12936_PRIVILEGED_INTERRUPT.abin 103115 NO $TRACE

# Running 12908/12978 WCS 256 W. diagnostic - diag failed - not implemented
#./build_hp2116.sh diagnostics/12908-16001_DSN103105_12908_12978_WCS_256_W.abin 103105 NO $TRACE

# Running 13197 WCS 1024 W. diagnostic - diag failed - not implemented
#./build_hp2116.sh diagnostics/13197-16002_DSN103023_13197_WCS_1024_W.abin 103023 NO $TRACE

# Running 12889 Hardwired Serial Interface diagnostic - diag failed - not implemented
#./build_hp2116.sh diagnostics/24335-16001_DSN103207_12889_HARDWIRED_SERIAL_INTERFACE.abin 103207 NO $TRACE

# Running 59310 Interface Bus Interface diagnostic - diag failed - not implemented
#./build_hp2116.sh diagnostics/59310-16001_DSN103122_59310_INTERF_BUS_INTERFACE.abin 103122 NO $TRACE

# Running 12587 Asynchronous Data Set Interface diagnostic - diag failed - not implemented
#./build_hp2116.sh diagnostics/12587-16001_DSN103003_12587_ASYN_DATA_SET_INTERF.abin 103003 NO $TRACE

# Running 12920 Asynchronous Multiplexer (Data) diagnostic - diag failed - not implemented
#./build_hp2116.sh diagnostics/12920-16001_DSN103110_12920_ASYN_MULTIPLEXER_DATA.abin 103110 NO $TRACE

# Running 12920 Asynchronous Multiplexer (Control) diagnostic - diag failed - not implemented
#./build_hp2116.sh diagnostics/12920-16002_DSN103011_12920_ASYN_MULTIPLEXER_CNTL.abin 103011 NO $TRACE

# Running 12621 Synchronous Data Set (Receive) diagnostic - diag failed - not implemented
#./build_hp2116.sh diagnostics/12621-16001_DSN103012_12621_SYNC_DATA_SET_RECEIVE.abin 103012 NO $TRACE

# Running 12622 Synchronous Data Set (Send) diagnostic - diag failed - not implemented
#./build_hp2116.sh diagnostics/12622-16001_DSN103013_12622_SYNC_DATA_SET_SEND.abin 103013 NO $TRACE

# Running 12967 Sync Interface diagnostic  - diag failed - not implemented
#./build_hp2116.sh diagnostics/12967-16001_DSN103116_12967_SYNC_INTERFACE.abin 103116 NO $TRACE

# Running 12966 Async Data Set diagnostic - diag failed - not implemented
#./build_hp2116.sh diagnostics/12966-16001_DSN103017_12966_ASYN_DATA_SET.abin 103017 NO $TRACE

# Running 12968 Async Communication Interface diagnostic - diag failed - not implemented
#./build_hp2116.sh diagnostics/12968-16001_DSN103121_12968_ASYN_COMM_INTERFACE.abin 103121 NO $TRACE

# Running 12821 ICD Disc Interface diagnostic - diag failed - waiting for input
#./build_hp2116.sh diagnostics/12821-16001_DSN103024_12821_ICD_DISC_INTERFACE.abin 103024 NO $TRACE

# Running 2607 Line Printer diagnostic - diag failed - not implemented
#./build_hp2116.sh diagnostics/24340-16001_DSN105102_2607_LINE_PRINTER.abin 105102 NO $TRACE

# Running 2613/17/18 Line Printer diagnostic - diag failed - not implemented
#./build_hp2116.sh diagnostics/02618-16001_DSN145103_2613_17_18_LINE_PRINTER.abin 145103 NO $TRACE

# Running 2631 Printer diagnostic - diag failed - not implemented
#./build_hp2116.sh diagnostics/02631-16001_DSN105106_2631_PRINTER.abin 105106 NO $TRACE

# Running 2635 Printing Terminal diagnostic - diag failed - not implemented
#./build_hp2116.sh diagnostics/02635-16001_DSN105107_2635_PRINTING_TERMINAL.abin 105107 NO $TRACE

# Running 2608 Line Printer diagnostic - diag failed - not implemented
#./build_hp2116.sh diagnostics/02608-16001_DSN105105_2608_LINE_PRINTER.abin 105105 NO $TRACE

# Running 9866 Line Printer diagnostic - diag failed - not implemented
#./build_hp2116.sh diagnostics/12996-16001_DSN105104_9866_LINE_PRINTER.abin 105104 NO $TRACE

# Running 12732 Flexible Disc Subsystem diagnostic - diag failed - not implemented
#./build_hp2116.sh diagnostics/12732-16003_DSN111104_12732_FLEXIBLE_DISC_SUBSYSTEM.abin 111104 NO $TRACE

# Running 7900/01 Cartridge Disc diagnostic  - diag failed - not implemented
#./build_hp2116.sh diagnostics/12960-16001_DSN151302_7900_01_CARTRIDGE_DISC.abin 151302 NO $TRACE

# Running 7905/06/20/25 Disc diagnostic  - diag failed - not implemented
#./build_hp2116.sh diagnostics/12962-16001_DSN151403_7905_06_20_25_DISC.abin 151403 NO $TRACE

# Running 92900 Terminal Subsystem diagnostic  - diag failed - not implemented
#./build_hp2116.sh diagnostics/92900-16001_DSN104117_92900_TERMINAL_SUBSYS_307040280.abin 104117 NO $TRACE

# Running 9-Track Mag Tape diagnostic  - diag failed - not implemented
#./build_hp2116.sh diagnostics/13181-16001_DSN112200_9_TRACK_MAG_TAPE_7970_13181_3.abin 112200 NO $TRACE

# Running 7/9 Track Mag Tape diagnostic  - diag failed - not implemented
#./build_hp2116.sh diagnostics/13184-16001_DSN112102_7_9_TRACK_MAG_TAPE_13184_INTF.abin 112102 NO $TRACE

# Running Diagnostic Cross Link diagnostic  - diag failed - not implemented
#./build_hp2116.sh diagnostics/24296-16003_DSN010000_DIAGNOSTIC_CROSS_LINK.abin 010000 NO $TRACE

# Running 7900/05/20 Disc Initialization diagnostic - waiting for input 
#./build_hp2116.sh diagnostics/24296-16002_DSN011000_7900_05_20_DISC_INITIALIZATION.abin 011000 NO $TRACE

# Running Paper Tape Reader-Punch diagnostic  - diag failed 
./build_hp2116.sh diagnostics/12597-16001_DSN146200_PAPER_TAPE_READER_PUNCH.abin 146200 NO $TRACE

# Running Dig. Plotter Interface (Calcomp) diagnostic  - diag failed - not implemented
#./build_hp2116.sh diagnostics/12560-16001_DSN107000_DIG_PLOTTER_INTERFACE_CALCOMP.abin 107000 NO $TRACE

# Running 2892 Card Reader diagnostic   - diag failed - not implemented
#./build_hp2116.sh diagnostics/12924-16001_DSN113100_2892_CARD_READER.abin 113100 NO $TRACE

# Running 2894 Card Reader Punch diagnostic  - diag failed - not implemented
#./build_hp2116.sh diagnostics/12989-16001_DSN113001_2894_CARD_READER_PUNCH.abin 113001 NO $TRACE

# Running Teleprinter diagnostic  - diag failed - probably need to set the sc code when starting diag
./build_hp2116.sh diagnostics/12531-16001_DSN104003_TELEPRINTER.abin 104003 NO $TRACE

# Running 2615 Video Terminal diagnostic  - diag failed - not implemented
#./build_hp2116.sh diagnostics/24351-16001_DSN104007_2615_VIDEO_TERMINAL.abin 104007 NO $TRACE

# Running 12909B PROM Writer diagnostic   - diag failed - not implemented
#./build_hp2116.sh diagnostics/24360-16001_DSN103006_12909B_PROM_WRITER.abin 103006 NO $TRACE