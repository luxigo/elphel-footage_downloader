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

if [ $UID -ne 0 ] ; then
  echo error: $(basename $0) must be run as root
  exit 1
fi

BASE_IP=192.168.0
MASTER_IP=221
N=9

MUXES=(192.168.0.224 192.168.0.228)
MUX_MAX_INDEX=(4 5)

SPOOL=/var/spool/elphel

[ -f /etc/defaults/footage_downloader ] && . /etc/defaults/footage_downloader

mkdir -p $SPOOL || exit 1
[ -n "$DEBUG" ] && set -x

trap "killtree -9 $MYPID yes" EXIT SIGINT SIGKILL SIGTERM SIGHUP

assertcommands() {
  while [ $# -ne 0 ] ; do
    local CMD=$1
    shift
    [ -z "$(which $CMD)" ] && echo command $CMD not found && exit 1
  done
}

checkdependencies() {
  assertcommands fsck rsync inotifywait arp wget ssh sshall
}

usage() {
  echo "usage: $(basename $0) <destination> [ <file_pattern> ]"
  exit $1
}

wait_fsck() {
  log ${LINENO} wait_fsck
  while killall -0 fsck 2>/dev/null || killall -0 fsck.ext2  2>/dev/null ; do
    sleep 10
  done
}

# kill child processes, and optionally the root process
killtree() {

    # disable ctrl-c
    trap '' SIGINT

    local _pid=$2
    local _sig=$1
    local killroot=$3

    # avoid fsck race condition
    if [ $(cat $QUITTING_TMP) -ne 1 ] ; then
      echo 1 > $QUITTING_TMP
      sleep 2
      wait_fsck
    fi

    # stop parents children production between child killing and parent killing
    #[ "${_pid}" != "$MYPID" ] && kill -STOP ${_pid}
    for _child in $(ps -o pid --no-headers --ppid ${_pid} 2>/dev/null); do
        killtree ${_sig} ${_child} yes
    done
    [ -n "$killroot" ] && kill ${_sig} ${_pid} 2>/dev/null
}

macaddr() {
  _ADDR=$1
  arp -n $_ADDR | awk '/[0-9a-f]+:/{gsub(":","-",$3);print $3}'
}

umount_cf() {
  HOSTS=$USER_AT_HOST sshall << 'EOF'
if grep -q ' /usr/html/CF ' /proc/mounts ; then
  sync
  umount /usr/html/CF || exit 1
  sync
fi
exit 0
EOF
}

get_remote_disk_serial() {
  HOSTS=$USER_AT_HOST sshall /sbin/hdparm -i $1 \| sed -r -n -e "'s/.*SerialNo=([^ ]+).*/\1/p'"
}

get_hbtl() {
  grep DEVPATH= $1 | sed -r -n -e 's#.*/([0-9]:[0-9]:[0-9]:[0-9])/.*#\1#' -e T -e 's/:/ /gp'
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

modtime() {
  expr $(date +%s) - $(stat -c %Y "$1")
}

get_camera_uptime() {
  ssh root@$BASE_IP.$MASTER_IP cat /proc/uptime | cut -f 1 -d '.'
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

# get module number for ssd serial
get_module_index() {
  local SERIAL=$1
  echo $(($(get_ssd_index $SERIAL)+1))
}

# check that specified module address match saved one
check_module_address() {
  local MUX_INDEX=$1
  local REMOTE_SSD_INDEX=$2
  local SERIAL=$3
  # return error if serial is not matching saved one for mux/ssd pair
  grep -q -E -e " $MUX_INDEX $REMOTE_SSD_INDEX $SERIAL\$" $MODULES_FILE
}

# wait udev generated files in spool folder before mounting disk and launching backup in background
wait_and_backup() {

  log ${LINENO} "<= wait_and_backup"

  inotifywait -m -e close_write $SPOOL | while read l ; do

    log ${LINENO} $SPOOL INOTIFY $l

    # second string returned by inotifywait is filename (disk serial)
    event=($l)
    SERIAL=${event[2]}

    # get spool filename
    UDEVINFO=$SPOOL/${event[2]}

    # get scsi host from spool filename
    SCSIHOST=$(get_hbtl $UDEVINFO)
    [ -z "$SCSIHOST" ] && killtree -KILL $MYPID

    # get saved connecting disk info
    DISK_CONNECTING_INFO=($(cat $DISK_CONNECTING_TMP))
    MUX_INDEX=${DISK_CONNECTING_INFO[0]}
    REMOTE_SSD_INDEX=${DISK_CONNECTING_INFO[1]}
    ISRETRY=${DISK_CONNECTING_INFO[2]}
    DEVICE=$(grep DEVNAME "$UDEVINFO" | cut -f 2 -d '=')

    log ${LINENO} device_connected $MUX_INDEX $REMOTE_SSD_INDEX $SCSIHOST $SERIAL $DEVICE

    # assert previously saved module address match the connecting disk
    if ! check_module_address $MUX_INDEX $REMOTE_SSD_INDEX $SERIAL ; then
      log ${LINENO} invalid_address "saved serial for mux $MUX_INDEX ssd $REMOTE_SSD_INDEX is not matching  $SERIAL"
      killtree -KILL $MYPID 
    fi

    # cache mux index and scsi host association
    save_scsihost $MUX_INDEX $SCSIHOST

    # if disk is already connected, ignore
    [ -f $TMP/${MUX_INDEX}_${REMOTE_SSD_INDEX}_connected ] && continue

    log ${LINENO} unpause connect queue
    touch $TMP/${MUX_INDEX}_${REMOTE_SSD_INDEX}_connecting || killtree -KILL $MYPID

    # set already connected flag
    touch $TMP/${MUX_INDEX}_${REMOTE_SSD_INDEX}_connected || killtree -KILL $MYPID
    echo $SCSIHOST $SERIAL $DEVICE > $TMP/${MUX_INDEX}_${REMOTE_SSD_INDEX}_connected

    # launch backup in background
    backup $MUX_INDEX $REMOTE_SSD_INDEX $SCSIHOST $SERIAL $DEVICE $ISRETRY &

  done
}

check_filesystem() {

  # if process is exiting, just wait for kill
  while [ "$(cat $QUITTING_TMP)" -eq 1 ] ; do sleep 100000 ; done

  # else check filesystem
  log ${LINENO} checking $SERIAL ${DEVICE}$PARTNUM integrity
  # -p is safe
  fsck -p ${DEVICE}$PARTNUM

  return $?
}

# backup filesystem then enqueue next ssd backup for this mux
backup() {

  MUX_INDEX=$1
  REMOTE_SSD_INDEX=$2
  SCSIHOST="$3 $4 $5 $6"
  SERIAL=$7
  DEVICE=$8
  ISRETRY=$9
  MUX_DONE=$(cat $MUX_DONE_TMP)

  # quit if already backuped - should not happend
  [ -f $TMP/${MUX_INDEX}_${REMOTE_SSD_INDEX}_backuped ] && killtree -KILL $MYPID

  log ${LINENO} backup $@
  PARTNUM=1
  MOUNTPOINT=/mnt/$(basename ${DEVICE})$PARTNUM
  mkdir -p $MOUNTPOINT || killtree -KILL $MYPID

  # disable ncq
  log ${LINENO} disabling NCQ $SERIAL ${DEVICE}$PARTNUM
  echo 1 > /sys/block/$(basename $DEVICE)/device/queue_depth

  # check / repair filesystem
  check_filesystem | logstdout ${LINENO}
  if [ $? -gt 1 ] ; then
    log ${LINENO} fsck_failed module $(get_module_index $SERIAL)
    return 1
  fi

# TODO: if fsck -p fails, make a disk image and fsck -y the disk image,
# then mount it
#
# fsck exit code is the sum of the following conditions
#            0    - No errors
#            1    - Filesystem errors corrected
#            2    - System should be rebooted
#            4    - Filesystem errors left uncorrected
#            8    - Operational error
#            16   - Usage or syntax error
#            32   - Fsck canceled by user request
#            128  - Shared-library error
  
  # mount device read-only
  if ! mount -o ro ${DEVICE}$PARTNUM $MOUNTPOINT ; then
     log ${LINENO} mount_failed module $(get_module_index $SERIAL)
     return 1
  fi

  # backup files
  log ${LINENO} backuping mux $MUX_INDEX index $REMOTE_SSD_INDEX serial $SERIAL partition ${DEVICE}$PARTNUM
  RSYNCDEST=$DEST/rsync/$(get_module_index $SERIAL)
  rsync -av $MOUNTPOINT/$FILE_PATTERN $RSYNCDEST 2>&1 | logstdout ${LINENO} $RSYNCDEST $MOUNTPOINT
  STATUS=$?

  log ${LINENO} backup_status $STATUS module $(get_module_index $SERIAL) mux ${MUX_INDEX} index ${REMOTE_SSD_INDEX}

  # unmount device
  log ${LINENO} umount $MOUNTPOINT
  sync
  umount ${DEVICE}$PARTNUM || umount -f ${DEVICE}$PARTNUM
  sync

  # remove flag
  rm $TMP/${MUX_INDEX}_${REMOTE_SSD_INDEX}_connected || killtree -KILL $MYPID

  # sync filesystems
  log ${LINENO} syncing
  sync

  # remove scsi host (will be added in connect_q_run after requesting connection for next ssd of this mux)
  log ${LINENO} removing device mux $MUX_INDEX index $REMOTE_SSD_INDEX
  [ -n "$SCSIHOST" ] || killtree -KILL $MYPID
  echo "scsi remove-single-device $SCSIHOST" | tee /proc/scsi/scsi 2>&1 | logstdout ${LINENO}
  echo $SCSIHOST >> $REMOVED_SCSI_TMP

  # set backuped flag
  touch $TMP/${MUX_INDEX}_${REMOTE_SSD_INDEX}_backuped || killtree -KILL $MYPID
  echo $SCSIHOST $SERIAL $DEVICE $STATUS > $TMP/${MUX_INDEX}_${REMOTE_SSD_INDEX}_backuped

  # show progression
  if [ $STATUS -eq 0 ] ; then
    echo $SERIAL >> $SERIAL_DONE_TMP
    log ${LINENO} backup_done_count $(sort -u $SERIAL_DONE_TMP | wc -l)
  fi

  # enqueue this mux's next ssd for backup (ignore this step for retries)
  if [ "$ISRETRY" = "" -a $REMOTE_SSD_INDEX -lt ${MUX_MAX_INDEX[$MUX_INDEX]} ] ; then
    log ${LINENO} enqueue mux $MUX_INDEX ssd $((REMOTE_SSD_INDEX+1))
    echo $MUX_INDEX $((REMOTE_SSD_INDEX+1)) >> $CONNECT_Q_TMP
  else
    # check mux done
    if ! is_any_ssd_left_in_queue_for_mux $MUX_INDEX ; then
      echo $((++MUX_DONE)) > $MUX_DONE_TMP
    fi
    log ${LINENO} mux_done_count $MUX_DONE
  fi

  # exit when nothing left to do
  if [ "$MUX_DONE" = "${#MUXES[@]}" ] ; then
    if [ $(sort -u $SERIAL_DONE_TMP | wc -l) -eq $N ] ; then
      log ${LINENO} exit_status 0
      echo 0 > $EXIT_CODE_TMP
    else
      log ${LINENO} exit_status 1
      echo 1 > $EXIT_CODE_TMP
    fi
    killtree -KILL $MYPID
  fi
}

is_any_ssd_left_in_queue_for_mux() {
   export MUX_INDEX=$1
   QSEQ=$(cat $QSEQ_TMP)
   tail -n +$(($QSEQ+1)) $CONNECT_Q_TMP | cut -f 1 -d ' ' | grep -q -e '^'$MUX_INDEX'$'
}

wait_watches_established() {

  local INOTIFY_STDERR=$1
  local msg

  FIFO=$(mktemp -u).$$
  mkfifo $FIFO
  tail -f $INOTIFY_STDERR > $FIFO 2>&1 &
  TAIL_PID=$!

  while read msg ; do
    echo $msg | logstdout ${LINENO}
    [[ "$msg" =~ "Watches established" ]] && break
  done < $FIFO

  kill $TAIL_PID > /dev/null 2>&1

  rm $INOTIFY_STDERR $FIFO
}

# switch esata connections sequentially reading from $CONNECT_Q_TMP
connect_q_run() {

  log ${LINENO} "<= connect_q_run"

  local FIFO=$(mktemp -u).$$
  mkfifo $FIFO
  tail -f $CONNECT_Q_TMP > $FIFO 2>&1 &
  local TAIL_PID=$!

  while read INDEXES ; do

    # increment queue sequence number
    echo $((++QSEQ)) > $QSEQ_TMP

    # parse queue request
    INDEXES=($INDEXES)
    MUX_INDEX=${INDEXES[0]}
    REMOTE_SSD_INDEX=${INDEXES[1]}
    ISRETRY=${INDEXES[2]}

    # requeue again if other disk of this mux is already connected
    if [ -f $TMP/${MUX_INDEX}_*_connected ] ; then
      echo $MUX_INDEX $REMOTE_SSD_INDEX $ISRETRY >> $CONNECT_Q_TMP
      sleep 10
      continue
    fi

    log ${LINENO} connect_q_run processing mux $MUX_INDEX ssd $REMOTE_SSD_INDEX

    while true ; do

      # before requesting disk connection, setup inotifywait and timemout to pause queue until disk is connected or timeout occurs
      touch $TMP/${MUX_INDEX}_${REMOTE_SSD_INDEX}_connecting || killtree -KILL $MYPID

      INOTIFY_STDERR=$(mktemp)
      timeout -k 10 30 inotifywait -e close_write $TMP/${MUX_INDEX}_${REMOTE_SSD_INDEX}_connecting 2> $INOTIFY_STDERR &
      TIMEOUTPID=$!
      wait_watches_established $INOTIFY_STDERR 2>&1 | grep -v -e INOTIFY_STDERR | logstdout ${LINENO}

      # before requesting disk connection, save connecting disk info
      echo $MUX_INDEX $REMOTE_SSD_INDEX $ISRETRY > $DISK_CONNECTING_TMP

      # request disk connection
      log ${LINENO} requesting sata disk mux $MUX_INDEX index $REMOTE_SSD_INDEX
      log ${LINENO} wget http://${MUXES[$MUX_INDEX]}/103697.php?c:host4=ssd$REMOTE_SSD_INDEX
      wget -q http://${MUXES[$MUX_INDEX]}/103697.php?c:host4=ssd$REMOTE_SSD_INDEX -O - > /dev/null || killtree -KILL $MYPID

      # add scsi device, if previously removed after previous ssd backup for this mux
      hbtl=$(get_scsihost $MUX_INDEX)
      if [ -n "$hbtl" ] ; then
        log ${LINENO} "adding scsi device using values from cache"
        echo "scsi add-single-device $hbtl" | tee /proc/scsi/scsi 2>&1 | logstdout ${LINENO}
      fi

      # wait for inotifywait and timeout setup above
      log ${LINENO} waiting for mux $MUX_INDEX disk $REMOTE_SSD_INDEX
      wait $TIMEOUTPID
      timeout_status=$?

      log ${LINENO} timeout status $timeout_status wating for mux $MUX_INDEX disk $REMOTE_SSD_INDEX

      rm $TMP/${MUX_INDEX}_${REMOTE_SSD_INDEX}_connecting

      # exit loop if there was no timeout
      [ "$timeout_status" != "124" ] && break

      # timeout on retry ? exit
      [ -n "$ISRETRY" ] && killtree -KILL $MYPID

      # re-enqueue this mux/ssd pair for later
      log ${LINENO} requeue mux $MUX_INDEX index $REMOTE_SSD_INDEX single
      echo $MUX_INDEX $REMOTE_SSD_INDEX isretry >> $CONNECT_Q_TMP

      # ask next ssd index for this mux
      [ $REMOTE_SSD_INDEX -lt ${MUX_MAX_INDEX[$MUX_INDEX]} ] || break
      ((++REMOTE_SSD_INDEX))

    done
  done < $FIFO
  kill -TERM $TAIL_PID > /dev/null 2>&1
  rm $FIFO
}

# remount ssd on cameras
reset_eyesis_ide() {
  log ${LINENO} reset eyesis_ide
  for (( i=0 ; $i < ${#MUXES[@]} ; ++i )) do
    log ${LINENO} wget http://${MUXES[$i]}/eyesis_ide.php
    wget -q http://${MUXES[$i]}/eyesis_ide.php -O - > /dev/null || exit 1
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

########### main script

SCSIHOST=()

[ -z "$DESTINATION" ] && DESTINATION=$1
[ -z "$FILE_PATTERN" ] && FILE_PATTERN="$2"

if [ -z "$DESTINATION" ] ; then
  usage 1
fi

for opt in $@ ; do
  [ "$opt" = "-h" ] && usage 0
done

checkdependencies

# get camera master ip mac address
ping -w 5 -c 1 $BASE_IP.$MASTER_IP > /dev/null || exit 1
MACADDR=$(macaddr $BASE_IP.$MASTER_IP)
[ -z "$MACADDR" ] && exit 1

TMP=/tmp/footage_downloader/$MACADDR/$$
mkdir -p $TMP

# create shared variables and inter-process storage
export MYPID=$BASHPID
export EXIT_CODE_TMP=$(mktemp --tmpdir=$TMP)
export DISK_CONNECTING_TMP=$(mktemp --tmpdir=$TMP)
export SSD_SERIAL_TMP=$(mktemp --tmpdir=$TMP)
export REMOVED_DEVICES=$(mktemp --tmpdir=$TMP)
export CONNECT_Q_TMP=$(mktemp --tmpdir=$TMP)
export MUX_DONE_TMP=$(mktemp --tmpdir=$TMP)
export QSEQ_TMP=$(mktemp --tmpdir=$TMP)
export QUITTING_TMP=$(mktemp --tmpdir=$TMP)
export SERIAL_DONE_TMP=$(mktemp --tmpdir=$TMP)
export REMOVED_SCSI_TMP=$TMP/../removed_scsi

echo 1 > $EXIT_CODE_TMP
echo 0 > $QSEQ_TMP
echo 0 > $MUX_DONE_TMP
echo 0 > $QUITTING_TMP
touch $REMOVED_SCSI_TMP

log ${LINENO} get camera uptime
CAMERA_UPTIME=$(get_camera_uptime) 
[ -z "$CAMERA_UPTIME" ] && exit 1
[ $CAMERA_UPTIME -lt 120 ] && sleep $((120-CAMERA_UPTIME))

# clear scsi hosts cache if modification time older than camera uptime
export SCSIHOST_TMP=$TMP/../scsihosts
if [ -f $SCSIHOST_TMP ] ; then
  if [ $CAMERA_UPTIME -lt $(modtime $SCSIHOST_TMP) ] ; then
    echo -n > $SCSIHOST_TMP
  fi
else
  touch $SCSIHOST_TMP
fi

# set destination folder
DEST="$DESTINATION/$(echo $MACADDR | tr 'a-f' 'A-F')"

mkdir -p "$DEST/rsync" || exit 1

export MODULES_FILE=$DEST/info/footage_downloader/modules
if [ ! -f $MODULES_FILE ] ; then
  log ${LINENO} error file not found: $MODULES_FILE
  log ${LINENO} error run register_camera.sh $DESTINATION first
  exit 1
fi

# build sshall login list
for (( i=0 ; $i < $N ; ++i )) ; do
  USER_AT_HOST="$USER_AT_HOST "root@$BASE_IP.$((MASTER_IP + i))
done

# get camera ssd serials
STATUS=()
log ${LINENO} get ssd serials
export SSD_SERIAL=()
get_remote_disk_serial /dev/hda 2>&1 | tee | while read l ; do
  msg=($l)
  [ ${msg[0]} = "sshall:" ] || continue
  [ ${msg[2]} = "stderr" ] && log ${LINENO} get_remote_disk_serial: $l
  LOGIN=${msg[1]}
  [ -z "$LOGIN" ] && log ${LINENO} get_remote_disk_serial: $l && killtree -KILL $MYPID
  IP=$(echo $LOGIN | sed -r -n -e 's/.*@[0-9]+\.[0-9]+\.[0-9]+\.([0-9]+).*/\1/p')
  INDEX=$(expr $IP - $MASTER_IP)
  WHAT=${msg[2]}
  case "$WHAT" in
  status)
    STATUS[$INDEX]=${msg[3]}
    [ "${STATUS[$INDEX]}" != "0" ] && log ${LINENO} get_remote_serial: $IP && killtree -KILL $MYPID
    ;;
  stdout)
    SERIAL=${msg[3]}
    echo SSD_SERIAL[$INDEX]=$SERIAL >> $SSD_SERIAL_TMP
    ;;
  esac
done

cat $SSD_SERIAL_TMP
. $SSD_SERIAL_TMP

log ${LINENO} got ${#SSD_SERIAL[@]} SSD serials

[ ${#SSD_SERIAL[@]} -ne $N ] && exit 1

rm $SSD_SERIAL_TMP

# unmount camera ssd
log ${LINENO} umount CF
umount_all

# run backgroud task waiting for disks and launching backups
wait_and_backup &

# queue first ssd for each mux
for (( i=0 ; i < ${#MUXES[@]} ; ++i )) ; do
  echo $i 1 >> $CONNECT_Q_TMP
done

# run queue in background
log ${LINENO} starting queue processing
connect_q_run &

# wait background jobs termination
wait

# disable ctrl-c
trap '' SIGINT

# reset multiplexers
log ${LINENO} resetting eyesis ide
reset_eyesis_ide

# add previously removed scsi devices
sort -u $REMOVED_SCSI_TMP | while read hbtl ; do 
  log ${LINENO} "adding previously removed scsi devices"
  echo "scsi add-single-device $hbtl" | tee /proc/scsi/scsi 2>&1 | logstdout ${LINENO}
  sed -r -i -e "/^$hbtl\$/d" $REMOVED_SCSI_TMP
done

EXIT_CODE=$(cat $EXIT_CODE_TMP)

# remove temporary files
rm $TMP/$$ -r 2> /dev/null

log ${LINENO} exit $EXIT_CODE
exit $EXIT_CODE
