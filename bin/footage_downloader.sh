#!/bin/bash
#
# elphel-footage_downloader
#
# Copyright (c) 2014 FOXEL SA - http://foxel.ch
# Please read <http://foxel.ch/license> for more information.
#
# This file is part of the FOXEL project <http://foxel.ch>.
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
#
# Additional Terms:
#
#      You are required to preserve legal notices and author attributions in
#      that material or in the Appropriate Legal Notices displayed by works
#      containing it.
#
#      You are required to attribute the work as explained in the "Usage and
#      Attribution" section of <http://foxel.ch/license>.
#
# Author(s):
#
#      Luc Deschenaux <l.deschenaux@foxel.ch>

#set -e

BASE_IP=192.168.0
MASTER_IP=221
N=9

MUXES=(192.168.0.224 192.168.0.228)
MUX_MAX_INDEX=(4 5)
MUX_DONE=0
SUCCESS=0

SPOOL=/var/spool/elphel

[ -f /etc/defaults/footage_downloader ] && . /etc/defaults/footage_downloader

mkdir -p $SPOOL || exit 1

[ -n "$DEBUG" ] && set -x

export DISK_CONNECTING_TMP=$(mktemp)
export SSD_SERIAL_TMP=$(mktemp)
export REMOVED_DEVICES=$(mktemp)
export CONNECT_Q_TMP=$(mktemp)
export SCSIHOST_TMP=$(mktemp)
export MYPID=$BASHPID

trap "killtree -9 $MYPID" EXIT SIGINT SIGKILL SIGHUP

usage() {
  echo "usage: $(basename $0) <destination> <file_pattern>"
  exit $1
}

killtree() {
    local _pid=$2
    local _sig=$1
    local dontkillfather=$3
#    kill -stop ${_pid} # needed to stop quickly forking parent from producing children between child killing and parent killing
    for _child in $(ps -o pid --no-headers --ppid ${_pid}); do
        killtree ${_sig} ${_child}
    done
    [ -z "$dontkillfather" ] || kill ${_sig} ${_pid} 2>/dev/null
}

macaddr() {                
  _ADDR=$1                 
  arp -n $_ADDR | awk '/[0-9a-f]+:/{gsub(":","-",$3);print $3}'
}                          

umount_cf() {
  HOSTS=$USER_AT_HOST sshall << 'EOF'
if grep -q ' /usr/html/CF ' /proc/mounts ; then
  umount /usr/html/CF || exit 1
fi
exit 0
EOF
}

get_remote_disk_serial() {
  HOSTS=$USER_AT_HOST sshall /sbin/hdparm -i $1 \| sed -r -n -e "'s/.*SerialNo=([^ ]+).*/\1/p'"
}

get_local_disk_serial() {
  /sbin/hdparm -i $1 | sed -r -n -e 's/.*SerialNo=([^ ]+).*/\1/p'
}

get_hbtl() {
  grep DEVPATH= $1 | sed -r -n -e 's#.*/([0-9]:[0-9]:[0-9]:[0-9])/.*#\1#' -e T -e 's/:/ /gp' 
}

is_mounted() {
  DEVICE=$1
  grep -q "^$DEVICE " /proc/mounts
}

log() {
  echo $(date +%F_%r) $BASHPID $@
}

# format stdin for logginG
logstdout() {
  while read l ; do
    echo $(date +%F_%R:%S) $BASHPID $@ $l
  done
}

# return array index of serial
get_ssd_index() {
  _SERIAL=$1
  for (( i=0 ; $i < ${#SSD_SERIAL[@]} ; ++i )) ; do
    if [ "${SSD_SERIAL[$i]}" = "$_SERIAL" ] ; then
      echo $i
      break
    fi
  done
}

# cache scsi address associated with mux index
save_scsihost() {
  MUX_INDEX=$1
  shift
  SCSIHOST=$@
  grep -q $MUX_INDEX $SCSIHOST_TMP || echo $MUX_INDEX $SCSIHOST >> $SCSIHOST_TMP
}

# read cached scsi address associated with mux index
get_scsihost() {
  MUX_INDEX=$1
  grep $MUX_INDEX $SCSIHOST_TMP | sed -r -e 's/^[0-9]+ (.*)/\1/' 
}

# wait udev generated files in spool folder before mounting disk and launching backup in background
wait_and_backup() {

  inotifywait -m -e close_write $SPOOL | while read l ; do

    log INOTIFY $l

    # second string returned by inotifywait is filename (disk serial)
    event=($l)
    SERIAL=${event[2]}

    # get spool filename
    UDEVINFO=$SPOOL/${event[2]}

    # get scsi host from spool filename
    SCSIHOST=$(grep DEVPATH= $UDEVINFO | sed -r -n -e 's#.*/host([0-9]+)/.*#\1#p')
    SCSIHOST=$(get_hbtl $UDEVINFO)
    [ -z "$SCSIHOST" ] && killtree -KILL $MYPID

    # get saved connecting disk info
    DISK_CONNECTING_INFO=($(cat $DISK_CONNECTING_TMP))
    MUX_INDEX=${DISK_CONNECTING_INFO[0]}
    MUX_REMOTE_SSD_INDEX=${DISK_CONNECTING_INFO[1]} 
    SINGLE=${DISK_CONNECTING_INFO[2]} 
    DEVICE=$(grep DEVNAME "$UDEVINFO" | cut -f 2 -d '=')

    log $MUX_INDEX $MUX_REMOTE_SSD_INDEX $SCSIHOST $SERIAL $DEVICE

    # cache mux index and scsi host association
    save_scsihost $MUX_INDEX $SCSIHOST

    # if disk is already connected, ignore
    [ -f /tmp/${MUX_INDEX}_${MUX_REMOTE_SSD_INDEX}_connected ] && continue

    # unpause connect queue
    touch /tmp/${MUX_INDEX}_${MUX_REMOTE_SSD_INDEX}_connecting || killtree -KILL $MYPID

    # set already connected flag
    touch /tmp/${MUX_INDEX}_${MUX_REMOTE_SSD_INDEX}_connected || killtree -KILL $MYPID
    echo $SCSIHOST $SERIAL $DEVICE > /tmp/${MUX_INDEX}_${MUX_REMOTE_SSD_INDEX}_connected 

    # launch backup in background
    backup $MUX_INDEX $MUX_REMOTE_SSD_INDEX $SCSIHOST $SERIAL $DEVICE $SINGLE &

  done
}

# backup filesystem then enqueue next ssd backup for this mux
backup() {
  MUX_INDEX=$1
  REMOTE_SSD_INDEX=$2
  SCSIHOST="$3 $4 $5 $6"
  SERIAL=$7
  DEVICE=$8
  SINGLE=$9

  # skip if already backuped
  [ -f /tmp/${MUX_INDEX}_${REMOTE_SSD_INDEX}_backuped ] && killtree -KILL $MYPID

  log backup $@
  PARTNUM=1
  MOUNTPOINT=/mnt/$(basename ${DEVICE})$PARTNUM
  mkdir -p $MOUNTPOINT || killtree -KILL $MYPID

  # disable ncq
  log disabling NCQ $SERIAL ${DEVICE}$PARTNUM
  echo 1 > /sys/block/$(basename $DEVICE)/device/queue_depth

  # repair filesystem
  log checking $SERIAL ${DEVICE}$PARTNUM integrity
  fsck -y ${DEVICE}$PARTNUM 2>&1 | logstdout
  FSCK_STATUS=$?
  [ $FSCK_STATUS -gt 1 ] && killtree -KILL $MYPID

  # mount device
  mount -o ro,sync ${DEVICE}$PARTNUM $MOUNTPOINT || killtree -KILL $MYPID

  # actual backup
  log backuping mux $MUX_INDEX index $REMOTE_SSD_INDEX serial $SERIAL partition ${DEVICE}$PARTNUM

  RSYNCDEST=$DEST/mov/$(($(get_ssd_index $SERIAL)+1))
  rsync -av $MOUNTPOINT/$FILE_PATTERN $RSYNCDEST 2>&1 | logstdout $RSYNCDEST $MOUNTPOINT 
  STATUS=$?

  log backup_status $STATUS mux ${MUX_INDEX} index ${REMOTE_SSD_INDEX}

  # unmount device
  log umount $MOUNTPOINT
  umount $MOUNTPOINT 

  # remove flag
  rm /tmp/${MUX_INDEX}_${REMOTE_SSD_INDEX}_connected || killtree -KILL $MYPID

  # sync filesystems
  log syncing
  sync

  # remove scsi host (will be added in connect_q_run after requesting connection for next ssd of this mux)
  log removing device mux $MUX_INDEX index $REMOTE_SSD_INDEX
  [ -n "$SCSIHOST" ] || killtree -KILL $MYPID
  echo "scsi remove-single-device $SCSIHOST" | tee /proc/scsi/scsi 2>&1 | logstdout

  # set backuped flag
  touch /tmp/${MUX_INDEX}_${REMOTE_SSD_INDEX}_backuped || killtree -KILL $MYPID
  echo $SCSIHOST $SERIAL $DEVICE $STATUS > /tmp/${MUX_INDEX}_${REMOTE_SSD_INDEX}_backuped

  # enqueue this mux's next ssd for backup (ignore this step if SINGLE is set because it is a retry)
  if [ "$SINGLE" = "" ] ; then
    if [ -a $REMOTE_SSD_INDEX -lt ${MUX_MAX_INDEX[$MUX_INDEX]} ] ; then 
      echo $MUX_INDEX $((REMOTE_SSD_INDEX+1)) >> $CONNECT_Q_TMP
    else
      # no more ssd for this mux
      ((++MUX_DONE))
    fi
  else
    # TODO: check here that next ssd has been requested for this mux, or that mux_done is incremented if no ssd left for this mux after the current "single" one
    echo TODO: check here that next ssd has been requested for this mux, or that mux_done is incremented if no ssd left for this mux after the current "single" one
  fi

  # exit when nothing left to do
  [ $STATUS -eq 0 ] && ((++SUCCESS))
  if [ "$MUX_DONE" = "$N" ] ; then
    if [ "$SUCCESS" = "$N" ] ; then
      log exit_status 0
    else
      log exit_status 1
    fi
    killtree -TERM $MYPID
  fi
}
 
# switch esata connections sequentially reading from $CONNECT_Q_TMP
connect_q_run() {
  
  tail -f $CONNECT_Q_TMP | while read INDEXES ; do
    
    # parse queue request
    INDEXES=($INDEXES)
    MUX_INDEX=${INDEXES[0]}
    REMOTE_SSD_INDEX=${INDEXES[1]}
    SINGLE=${INDEXES[2]}

    # requeue again if other disk of this mux is already connected
    if [ -f /tmp/${MUX_INDEX}_*_connected ] ; then
      echo $MUX_INDEX $REMOTE_SSD_INDEX $SINGLE >> $CONNECT_Q_TMP
      sleep 10
      continue
    fi

    while true ; do

      # before requesting disk connection, setup inotifywait and timemout to pause queue until disk is connected or timeout occurs
      touch /tmp/${MUX_INDEX}_${REMOTE_SSD_INDEX}_connecting || killtree -KILL $MYPID
      timeout -k 10 30 inotifywait -e close_write /tmp/${MUX_INDEX}_${REMOTE_SSD_INDEX}_connecting &
      TIMEOUTPID=$!
      # TODO wait for "watches established" instead of sleep 1
      sleep 1

      # before requesting disk connection, save connecting disk info
      echo $MUX_INDEX $REMOTE_SSD_INDEX $SINGLE> $DISK_CONNECTING_TMP

      # request disk connection
      log requesting sata disk mux $MUX_INDEX index $REMOTE_SSD_INDEX
      log wget http://${MUXES[$MUX_INDEX]}/103697.php?c:host4=ssd$REMOTE_SSD_INDEX
      wget -q http://${MUXES[$MUX_INDEX]}/103697.php?c:host4=ssd$REMOTE_SSD_INDEX -O /dev/null || killtree -KILL $MYPID

      # add scsi device, if previously removed after previous ssd backup for this mux
      hbtl=$(get_scsihost $MUX_INDEX)
      if [ -n "$hbtl" ] ; then
        log "adding scsi device (scsi host known because previously mounted)"
        echo "scsi add-single-device $hbtl" | tee /proc/scsi/scsi 2>&1 | logstdout
      fi

      # wait for inotifywait and timeout setup above
      log waiting for mux $MUX_INDEX disk $REMOTE_SSD_INDEX
      wait $TIMEOUTPID
      timeout_status=$?

      log timeout status $timeout_status wating for mux $MUX_INDEX disk $REMOTE_SSD_INDEX

      rm /tmp/${MUX_INDEX}_${REMOTE_SSD_INDEX}_connecting

      # exit loop if there was no timeout
      [ "$timeout_status" != "124" ] && break

      # timeout on retry ? exit
      [ -n "$SINGLE" ] && killtree -KILL $MYPID

      # re-enqueue this mux/ssd pair for later
      log requeue mux $MUX_INDEX index $REMOTE_SSD_INDEX single
      echo $MUX_INDEX $REMOTE_SSD_INDEX single >> $CONNECT_Q_TMP

      # ask next ssd index for this mux
      [ $REMOTE_SSD_INDEX -lt ${MUX_MAX_INDEX[$MUX_INDEX]} ] || break
      ((++REMOTE_SSD_INDEX))

    done
  done
}

# remount ssd on cameras
reset_eyesis_ide() {
  log reset eyesis_ide
  for (( i=0 ; $i < ${#MUXES[@]} ; ++i )) do
    log wget http://${MUXES[$i]}/eyesis_ide.php
    wget -q http://${MUXES[$i]}/eyesis_ide.php -O /dev/null || exit 1
  done
}

# unmount ssd on cameras
umount_all() {
  STATUS=()
  umount_cf 2>&1 | tee | while read l ; do
    msg=($l)
    [ ${msg[0]} = "sshall:" ] || continue
    LOGIN=${msg[1]}
    [ -z "$LOGIN" ] && echo umount_all: $l && killtree -KILL $MYPID
    WHAT=${msg[2]}
    [ "$WHAT" != "status" ] && continue
    IP=$(echo $LOGIN | sed -r -n -e 's/.*@[0-9]+\.[0-9]+\.[0-9]+\.([0-9]+).*/\1/p')
    INDEX=$(expr $IP - $MASTER_IP)
    STATUS[$INDEX]=${msg[3]}
    [ "${STATUS[$INDEX]}" != "0" ] && echo umount_cf $IP && killtree -KILL $MYPID
  done
}

SCSIHOST=()

[ -z "$DESTINATION" ] && DESTINATION=$1
[ -z "$FILE_PATTERN" ] && FILE_PATTERN="$2"

for opt in $@ ; do
  [ "$opt" = "-h" ] && usage 0
done

if [ -z "$DESTINATION" ] ; then
  usage 1
fi

# get camera master ip mac address
ping -w 5 -c 1 $BASE_IP.$MASTER_IP > /dev/null || exit 1
MACADDR=$(macaddr $BASE_IP.$MASTER_IP)
[ -z "$MACADDR" ] && exit 1

# set destination folder
DEST="$DESTINATION/$MACADDR"
mkdir -p "$DEST/mov" || exit 1

# build sshall login list
for (( i=0 ; $i < $N ; ++i )) ; do
  USER_AT_HOST="$USER_AT_HOST "root@$BASE_IP.$((MASTER_IP + i))
done

# get camera ssd serials
STATUS=()
log get ssd serials
export SSD_SERIAL=()
get_remote_disk_serial /dev/hda 2>&1 | tee | while read l ; do
  msg=($l)
  [ ${msg[0]} = "sshall:" ] || continue
  LOGIN=${msg[1]}
  [ -z "$LOGIN" ] && log get_remote_disk_serial: $l && killtree -KILL $MYPID
  IP=$(echo $LOGIN | sed -r -n -e 's/.*@[0-9]+\.[0-9]+\.[0-9]+\.([0-9]+).*/\1/p')
  INDEX=$(expr $IP - $MASTER_IP)
  WHAT=${msg[2]}
  case "$WHAT" in
  status)
    STATUS[$INDEX]=${msg[3]}
    [ "${STATUS[$INDEX]}" != "0" ] && log get_remote_serial: $IP && killtree -KILL $MYPID
    ;;
  stdout)
    SERIAL=${msg[3]}
    echo SSD_SERIAL[$INDEX]=$SERIAL >> $SSD_SERIAL_TMP
    ;;
  esac
done  

cat $SSD_SERIAL_TMP
. $SSD_SERIAL_TMP

log got ${#SSD_SERIAL[@]} SSD serials

[ ${#SSD_SERIAL[@]} -ne $N ] && exit 1

rm $SSD_SERIAL_TMP

# unmount camera ssd
log umount CF
umount_all

rm /tmp/*_backuped 2> /dev/null
rm /tmp/*_connected 2> /dev/null
rm /tmp/*_connecting 2> /dev/null

# run backgroud task waiting for disks and launching backups
wait_and_backup &

# queue first ssd for each mux
for (( i=0 ; i < ${#MUXES[@]} ; ++i )) ; do
  echo $i 1 >> $CONNECT_Q_TMP
done

# run queue in background
log starting queue processing
connect_q_run &

wait

log resetting eyesis ide
reset_eyesis_ide || exit 1

