#!/bin/bash

readonly LEN_OFF_POWERCYCLE=20 # powercycle
sudo rtcwake -s ${LEN_OFF_POWERCYCLE} -m off  
