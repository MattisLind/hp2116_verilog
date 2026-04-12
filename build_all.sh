#!/bin/bash
# Running pre test only
TRACE=$1
if [ -z "$1" ]; then
  TRACE=NO
fi
./build_hp2116.sh 24396-1.abs 101100 YES $TRACE
# Running memory referece instruction group diagnostic
./build_hp2116.sh 24396-1.abs 101100 NO $TRACE
# Running Alter / Skip instruction group diagnostic
./build_hp2116.sh 24396-1.abs 101001 NO $TRACE
# Running Shift / Rotate instruction group diagnostic
./build_hp2116.sh 24396-13601_file3_with_trailer.abin 101002 NO $TRACE