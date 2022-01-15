#!/usr/bin/env python3
# ===================================================================================
# Project:   DiskBuddy64 - Python Script - Read Disk Image to D64 File
# Version:   v1.0
# Year:      2022
# Author:    Stefan Wagner
# Github:    https://github.com/wagiminator
# License:   http://creativecommons.org/licenses/by-sa/3.0/
# ===================================================================================
#
# Description:
# ------------
# Reads disk image to D64 file
#
# Dependencies:
# -------------
# - adapter (included in libs folder)
#
# Operating Instructions:
# -----------------------
# - python disk-read.py [-h] [-b] [-d {8,9,10,11}] [-f FILE]
#   optional arguments:
#   -h, --help            show help message and exit
#   -b, --bamonly         only read blocks with BAM entry (recommended)
#   -d, --device          device number of disk drive (8-11, default=8)
#   -f FILE, --file FILE  output file (default=output.d64)
# - Example: python disk-read.py -b -f game.d64


import sys
import os
import time
import argparse
from libs.adapter import *


# ===================================================================================
# Main Function
# ===================================================================================


# Variables
tracks  = 35
bamcopy = 0
ramaddr = 0x0500
device  = 8


# Print Header
print('')
print('--------------------------------------------------')
print('DiskBuddy64 - Python Command Line Interface v1.0')
print('(C) 2022 by Stefan Wagner - github.com/wagiminator')
print('--------------------------------------------------')


# Get and check command line arguments
parser = argparse.ArgumentParser(description='Simple command line interface for DiskBuddy64')
parser.add_argument('-b', '--bamonly', action='store_true', help='only read blocks with BAM entry (recommended)')
parser.add_argument('-d', '--device', choices={8, 9, 10, 11}, type=int, default=8, help='device number of disk drive (default=8)')
parser.add_argument('-f', '--file', default='output.d64', help='output file (default=output.d64)')

args = parser.parse_args(sys.argv[1:])
if args.bamonly:  bamcopy  = 1
device   = args.device
filename = args.file


# Establish serial connection
print('Connecting to DiskBuddy64 ...')
diskbuddy = Adapter()

if not diskbuddy.is_open:
    raise AdpError('Adapter not found')

print('Adapter found on port', diskbuddy.port)
print('Firmware version:', diskbuddy.getversion())


# Check if IEC device ist present
if not diskbuddy.checkdevice(device):
    diskbuddy.close()
    raise AdpError('IEC device ' + str(device) + ' not found')


# Upload fast loader to disk drive RAM
print('Uploading fast loader ...')
if diskbuddy.uploadbin(ramaddr, 'libs/fastread.bin') > 0:
    diskbuddy.close()
    sys.exit(1)


# Create output file
print('Opening', filename, 'for writing ...')
try:
    f = open(filename, 'wb')
except:
    diskbuddy.close()
    raise AdpError('Could not open ' + filename)


# Fill output file with default values
for track in range(1, tracks + 1):
    for sector in range(getsectors(track)):
        f.write(b'\x4B' + b'\x01' * 255)


# Read BAM if necessary
if bamcopy > 0:
    print('Reading BAM ...')
    dbam = BAM(diskbuddy.readblock(ramaddr, 18, 0))
    if not dbam.bam:
        f.close()
        diskbuddy.close()
        sys.exit(1)


# Read disk
print('Reading disk ...')
starttime = time.time()
for track in range(1, tracks + 1):
    secnum      = getsectors(track)
    interleave  = secnum // 2;
    sectors     = [x for x in range(secnum)]
    seclist     = []

    # Cancel sectors without BAM entry
    if bamcopy > 0 and track < 36:
        for x in range(secnum):
            if dbam.blockisfree(track, x): sectors.remove(x)

    # Optimize order of sectors for speed
    sector  = 0
    counter = len(sectors)
    while counter:
        if sector >= secnum: sector -= secnum
        while not sector in sectors:
            sector += 1
            if sector >= secnum: sector = 0
        seclist.append(sector)
        sectors.remove(sector)
        sector  += interleave
        counter -= 1

    # Send command to disk drive, if there's something to read on track
    seclen = len(seclist)
    if seclen > 0:
        if diskbuddy.startfastiec('r', ramaddr, track, seclist) > 0:
            f.close()
            diskbuddy.close()
            sys.exit(1)

    # Read track
    trackline = ('Track ' + str(track) + ':').ljust(10) + '['
    sys.stdout.write(trackline + '-' * seclen + '0' * (secnum - seclen) + ']')
    sys.stdout.write('\r' + trackline)
    sys.stdout.flush()
    diskbuddy.timeout = 3
    for sector in seclist:
        f.seek(getfilepointer(track, sector))
        if not f.write(diskbuddy.read(256)) == 256:
            print('')
            f.close()
            diskbuddy.close()
            raise AdpError('Reading from disk failed')
        sys.stdout.write('#')
        sys.stdout.flush()
        diskbuddy.timeout = 1
    print('')


# Finish all up
duration = time.time() - starttime
print('Done.')
print('Duration:', round(duration), 'seconds')
print('')
f.close()
diskbuddy.close()
