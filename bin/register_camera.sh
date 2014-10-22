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

trap "killtree -9 $MYPID yes" EXIT SIGINT SIGKILL SIGHUP

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
  echo "usage: $(basename $0)"
  exit $1
}

# kill child processes, and optionally the root process
killtree() {
    local _pid=$2
    local _sig=$1
    local killroot=$3

    killroot=yes
    # stop parents children production between child killing and parent killing
    #[ "${_pid}" != "$MYPID" ] && kill -STOP ${_pid}
    for _child in $(ps -o pid --no-headers --ppid ${_pid}); do
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

save_module_address() {
  local MUX_INDEX=$1
  local MUX_REMOTE_SSD_INDEX=$2
  local SERIAL=$3
  [ grep -q -E -e " $SERIAL\$" $MODULE_ADDRESS_TMP ] && return 0
  echo $(get_module_index $SERIAL) $MUX_INDEX $MUX_REMOTE_SSD_INDEX $SERIAL >> $MODULE_ADDRESS_TMP
  sort -u $MODULE_ADDRESS_TMP > ${MODULE_ADDRESS_TMP}.sort
  cat ${MODULE_ADDRESS_TMP}.sort > $MODULE_ADDRESS_TMP
}

# check that specified module address match saved one
check_module_address() {
  local MUX_INDEX=$1
  local MUX_REMOTE_SSD_INDEX=$2
  local SERIAL=$3
  [ ! grep -q -E -e "^[0-9]+ $MUX_INDEX $MUX_REMOTE_SSD_INDEX " $MODULE_ADDRESS_TMP ] && return 0
  grep -q -E -e "$MUX_INDEX $MUX_REMOTE_SSD_INDEX $SERIAL\$" $MODULE_ADDRESS_TMP
}

# wait udev generated files in spool folder before mounting disk and save module address in background
wait_and_register() {

  inotifywait -m -e close_write $SPOOL | while read l ; do

    log INOTIFY $l

    sleep 5

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
    ISRETRY=${DISK_CONNECTING_INFO[2]}
    DEVICE=$(grep DEVNAME "$UDEVINFO" | cut -f 2 -d '=')

    log $MUX_INDEX $MUX_REMOTE_SSD_INDEX $SCSIHOST $SERIAL $DEVICE

    # assert previously saved module address match the connecting disk
    if [ ! check_module_address $MUX_INDEX $MUX_REMOTE_SSD_INDEX $SERIAL ] ; then
      log invalid_address "saved serial for mux $MUX_INDEX ssd $MUX_REMOTE_SSD_INDEX is not matching  $SERIAL"
      killtree -KILL $MYPID 
    fi

    # cache camera module address (mux index, ssd index)
    save_module_address $MUX_INDEX $MUX_REMOTE_SSD_INDEX $SERIAL

    # cache mux index and scsi host association
    save_scsihost $MUX_INDEX $SCSIHOST

    # if disk is already connected, ignore
    [ -f $TMP/${MUX_INDEX}_${MUX_REMOTE_SSD_INDEX}_connected ] && continue

    # set already connected flag
    touch $TMP/${MUX_INDEX}_${MUX_REMOTE_SSD_INDEX}_connected || killtree -KILL $MYPID
    echo $SCSIHOST $SERIAL $DEVICE > $TMP/${MUX_INDEX}_${MUX_REMOTE_SSD_INDEX}_connected

    # unpause connect queue
    touch $TMP/${MUX_INDEX}_${MUX_REMOTE_SSD_INDEX}_connecting || killtree -KILL $MYPID

    enqueue_next_ssd &

  done
}

# enqueue next ssd for this mux
enqueue_next_ssd() {

  MUX_INDEX=$1
  REMOTE_SSD_INDEX=$2
  SCSIHOST="$3 $4 $5 $6"
  SERIAL=$7
  DEVICE=$8
  ISRETRY=$9
  BACKUP_DONE=$(cat $BACKUP_DONE_TMP)
  MUX_DONE=$(cat $MUX_DONE_TMP)

  # quit if already registered - should not happend
  [ -f $TMP/${MUX_INDEX}_${REMOTE_SSD_INDEX}_registered ] && killtree -KILL $MYPID

  sleep 5

  # sync filesystems
  log syncing
  sync

  # remove scsi host (will be added in connect_q_run after requesting connection for next ssd of this mux)
  log removing device mux $MUX_INDEX index $REMOTE_SSD_INDEX
  [ -n "$SCSIHOST" ] || killtree -KILL $MYPID
  echo "scsi remove-single-device $SCSIHOST" | tee /proc/scsi/scsi 2>&1 | logstdout
  echo $SCSIHOST >> $REMOVED_SCSI_TMP

  # remove flag
  rm $TMP/${MUX_INDEX}_${REMOTE_SSD_INDEX}_connected || killtree -KILL $MYPID

  # set registered flag
  touch $TMP/${MUX_INDEX}_${REMOTE_SSD_INDEX}_registered || killtree -KILL $MYPID
  echo $SCSIHOST $SERIAL $DEVICE $STATUS > $TMP/${MUX_INDEX}_${REMOTE_SSD_INDEX}_registered

  echo $SERIAL >> $SERIAL_DONE_TMP
  # show progression
  SERIAL_DONE_COUNT=$(sort -u $SERIAL_DONE_TMP | wc -l)
  log registration_done_count $SERIAL_DONE_COUNT

  # enqueue this mux's next ssd for backup (ignore this step for retries)
  if [ "$ISRETRY" = "" -a $REMOTE_SSD_INDEX -lt ${MUX_MAX_INDEX[$MUX_INDEX]} ] ; then
    echo $MUX_INDEX $((REMOTE_SSD_INDEX+1)) >> $CONNECT_Q_TMP
  else
    # check mux done
    if ! is_any_ssd_left_in_queue_for_mux $MUX_INDEX ; then
      echo $((++MUX_DONE)) > $MUX_DONE_TMP
    fi
    log mux_done_count $MUX_DONE
  fi

  # exit when nothing left to do
  if [ "$MUX_DONE" = "${#MUXES[@]}" ] ; then
    if [ $(sort -u $SERIAL_DONE_TMP | wc -l) -eq $N ] ; then
      log exit_status 0
    else
      log exit_status 1
    fi
    killtree -KILL $MYPID
  fi
}

is_any_ssd_left_in_queue_for_mux() {
   MUX_INDEX=$1
   QSEQ=$(cat $QSEQ_TMP)
   tail -n +$QSEQ $CONNECT_Q_TMP | cut -f 1 -d ' ' | grep -q -e '^'$MUX'$'
}

wait_watches_established() {

  local INOTIFY_STDERR=$1
  local msg

  FIFO=$(mktemp)
  mkfifo $FIFO
  tail -f $INOTIFY_STDERR > $FIFO &
  TAIL_PID=$?

  while read msg ; do
    echo msg = $msg | logstdout
    [[ "$msg" =~ "Watches established" ]] && break
  done < $FIFO

  kill $TAIL_PID

  rm $INOTIFY_STDERR
}

# switch esata connections sequentially reading from $CONNECT_Q_TMP
connect_q_run() {

  tail -f $CONNECT_Q_TMP | while read INDEXES ; do

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

    while true ; do

      # before requesting disk connection, setup inotifywait and timemout to pause queue until disk is connected or timeout occurs
      touch /tmp/${MUX_INDEX}_${REMOTE_SSD_INDEX}_connecting || killtree -KILL $MYPID

      INOTIFY_STDERR=$(mktemp)
      timeout -k 10 30 inotifywait -e close_write /tmp/${MUX_INDEX}_${REMOTE_SSD_INDEX}_connecting 2> $INOTIFY_STDERR &
      TIMEOUTPID=$!
      wait_watches_established $INOTIFY_STDERR

      # before requesting disk connection, save connecting disk info
      echo $MUX_INDEX $REMOTE_SSD_INDEX $ISRETRY> $DISK_CONNECTING_TMP

      # request disk connection
      log requesting sata disk mux $MUX_INDEX index $REMOTE_SSD_INDEX
      log wget http://${MUXES[$MUX_INDEX]}/103697.php?c:host4=ssd$REMOTE_SSD_INDEX
      wget -q http://${MUXES[$MUX_INDEX]}/103697.php?c:host4=ssd$REMOTE_SSD_INDEX -O - > /dev/null || killtree -KILL $MYPID

      # add scsi device, if previously removed after previous ssd backup for this mux
      hbtl=$(get_scsihost $MUX_INDEX)
      if [ -n "$hbtl" ] ; then
        log "adding scsi device using values from cache"
        echo "scsi add-single-device $hbtl" | tee /proc/scsi/scsi 2>&1 | logstdout
      fi

      # wait for inotifywait and timeout setup above
      log waiting for mux $MUX_INDEX disk $REMOTE_SSD_INDEX
      wait $TIMEOUTPID
      timeout_status=$?

      log timeout status $timeout_status wating for mux $MUX_INDEX disk $REMOTE_SSD_INDEX

      rm $TMP/${MUX_INDEX}_${REMOTE_SSD_INDEX}_connecting

      # exit loop if there was no timeout
      [ "$timeout_status" != "124" ] && break

      # timeout on retry ? exit
      [ -n "$ISRETRY" ] && killtree -KILL $MYPID

      # re-enqueue this mux/ssd pair for later
      log requeue mux $MUX_INDEX index $REMOTE_SSD_INDEX single
      echo $MUX_INDEX $REMOTE_SSD_INDEX isretry >> $CONNECT_Q_TMP

      # ask next ssd index for this mux
      [ $REMOTE_SSD_INDEX -lt ${MUX_MAX_INDEX[$MUX_INDEX]} ] || break
      ((++REMOTE_SSD_INDEX))

    done
  done
}

# reset multiplexers
reset_eyesis_ide() {
  log reset eyesis_ide
  for (( i=0 ; $i < ${#MUXES[@]} ; ++i )) do
    log wget http://${MUXES[$i]}/eyesis_ide.php
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
export DISK_CONNECTING_TMP=$(mktemp --tmpdir=$TMP)
export SSD_SERIAL_TMP=$(mktemp --tmpdir=$TMP)
export REMOVED_DEVICES=$(mktemp --tmpdir=$TMP)
export CONNECT_Q_TMP=$(mktemp --tmpdir=$TMP)
export MUX_DONE_TMP=$(mktemp --tmpdir=$TMP)
export QSEQ_TMP=$(mktemp --tmpdir=$TMP)
export SERIAL_DONE_TMP=$(mktemp --tmpdir=$TMP)
export MODULE_ADDRESS_TMP=$TMP/../modules
export REMOVED_SCSI_TMP=$TMP/../removed_scsi

echo 0 > $QSEQ_TMP
echo 0 > $MUX_DONE_TMP
touch $MODULE_ADDRESS_TMP
touch $REMOVED_SCSI_TMP

log get camera uptime
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
DEST="$DESTINATION/$MACADDR"

mkdir -p "$DEST/rsync" || exit 1

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
  [ ${msg[2]} = "stderr" ] && log get_remote_disk_serial: $l
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

# run backgroud task waiting for disks and launching backups
wait_and_register &

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

sort -u $REMOVED_SCSI_TMP | while read hbtl ; do 
  log "adding previously removed scsi devices"
  echo "scsi add-single-device $hbtl" | tee /proc/scsi/scsi 2>&1 | logstdout
  sed -r -i -e "/^$hbtl\$/d" $REMOVED_SCSI_TMP
done

log all_done

rm $TMP/$$ -r 2> /dev/null

