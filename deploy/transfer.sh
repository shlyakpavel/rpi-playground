#!/bin/bash
# !!! Copy installation archives from /tmp/qt-build to this directory before running this script !!!
RPI_IP=192.168.10.115
DIST_PATH="/home/pi/super/"
rsync -Pav -e "ssh -i $HOME/.ssh/spsss_ssh_key.priv" . pi@$RPI_IP:$DIST_PATH --delete --exclude ".git"
