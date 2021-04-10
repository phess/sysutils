#!/bin/bash

############################################################
# This script is meant to perform a system backup.
# It is passed the target mountpoint and possibly also a
# Rsync exclude-file and possibly also a Rsync INclude-file.
#
# HISTORY:
# 2009-06-13: Program written
# 2010-06-27: Comments for the mountpoints
# 2010-10-22: Translated to English. Started using getopt.
#             Almost completely rewritten. SSH options
#             added. Logging reviewed and reduced.
# 2010-11-25: Fixed bug when NOT using remote SSH host for 
#             backup.
# 2011-04-15: Fixed 1st run always returning an error. Fixed
#             error codes in order to ease debugging.
# 2012-01-14: Fixed a few typos, removed duplicate function
#             definition, provided proper logging through
#             the 'logger' utility (now a dependency).
# 2012-01-15: Fixed the 'line 215: unexpected "if"' bug.
# 2013-11-13: Clarified the "use the -l option" message.
# 2014-02-20: Included --hard-links --acls --user-xattrs 
#             args to rsync.
############################################################


# CONSTANTS and FUNCTIONS:
PROGNAME="`basename \"${0}\"`"

# Function LOGTHIS needs the 'logger' utility
which logger &>/dev/null
if [[ "$?" -ne "0" ]]; then
    echo "I need the 'logger' utility, or else logging is not going to work."
    echo "Aborting."
    exit 33 ## This error code may violate some standard
fi

function LOGTHIS {
  #local msg="${HOSTNAME:-''}: $(date '+%Y-%m-%d'): ${1}"
  #echo "[$(date '+%d/%M/%Y %T')] ${msg}"
  local msg="${*}"
  echo "${msg}" |logger -p local4.info -t ${PROGNAME} --stderr 2>&1
}

function help {
  echo "Usage: ${PROGNAME} -d <DESTINATION> [OPTIONS]
OPTIONS:
  -h                   |Print this help text and exit
  -s <SSH host[:port]> |Specify a remote SSH host (and port) for the backup
  -d <BASE DIR>        |Directory that will hold this backup directory
  -u <REMOTE USER>     |Remote user (only when destination backup is remote)
  -l <LAST BACKUP>     |Directory containing the latest backup of this system
  -i <INCLUDE>         |Rsync's include file for this backup
  -y                   |Assume \"yes\" to all answers
  -m <MAX FILE SIZE>   |Maximum file size to be backed up, in MB
  -p                   |\"Pretend\" run: just show what WOULD be done
"
}

while getopts hs:d:u:l:i:ym:p OPTION ;
  do case "${OPTION}" in
    h) help ; exit 0 ;;
    s) SSH_HOST="${OPTARG}" ;;
    d) MOUNTPOINT="${OPTARG}" ;;
    u) SSH_USER="${OPTARG}" ;;
    l) LASTBACKUP="${OPTARG}" ;;
    i) INCLUDE_FILE="${OPTARG}" ;;
    y) ALL_YES="1" ;;
    m) MAX_SIZE="--max-size=${OPTARG}M" ;;
    p) DRY_RUN="--dry-run" ;;
    *) help ; exit 64 ;;
  esac
done

[[ "${DRY_RUN}" ]] && LOGFILE=/dev/stdout || LOGFILE=/var/log/backup.log

###############
# SSH functions
###############
if [[ "${SSH_HOST}" ]]; then
  # We have to replace a few shell commands with their remote SSH equivalents.
  function ls {
    ssh -l ${SSH_USER} ${SSH_HOST} "ls ${*}"
    return $?
  }
  function dir_writable {
    ssh -l ${SSH_USER} ${SSH_HOST} "test -d \"${*}\" -a -w \"${*}\""
    return $?
  }
  function mkdir {
    ssh -l ${SSH_USER} ${SSH_HOST} "mkdir \"${*}\""
    return $?
  }
  SSH_OPTIONS="${SSH_OPTIONS} -z"
  SSH_DIR_PREFIX="${SSH_USER}@${SSH_HOST}:"

###################
# non-SSH functions
###################
else
  # Functions 'ls' and 'mkdir' are not needed because these are
  # built-in commands.
  function dir_writable {
    test -d "${*}" -a -w "${*}"
    return $?
  }
  # Let's check if the destination is really there.
  dir_writable "${MOUNTPOINT}" || { LOGTHIS "Backup destination (${MOUNTPOINT}) is not a directory or is not writeable by user $USER. ABORT." && exit 77; }
fi


# Now let's create our new destination directory.
TODAY=$(date '+%Y-%m-%d')
TODAYPOINT="${TODAYPOINT}${MOUNTPOINT}"/"BACKUP-$(hostname)-${TODAY}"

# If our destination directory already exists and is writable, we should
# ask whether or not to update it.
if dir_writable "${TODAYPOINT}" ; then
  LOGTHIS "Backup destination (${TODAYPOINT}/) already exists."
  echo -n "Do you want to update the existing backup on ${TODAYPOINT}? (y/N) > "
  if [[ "${ALL_YES}" -eq "1" ]]; then
    UPDATEBACKUP="y"
    echo "y (you used the '-y' option)"
  else
    read UPDATEBACKUP
  fi
  # Unless the answer is YES, we have to ABORT.
  if [[ "`echo ${UPDATEBACKUP} | tr 'A-Z' 'a-z'`" != "y" ]]; then
    LOGTHIS "User chose not to update. ABORT."
    exit 30 ## This error code may violate some standard.
  else
    LOGTHIS "User chose to update backup at \'${TODAYPOINT}\'."
  fi

else
  if [[ ! ${DRY_RUN} ]]; then
    mkdir "${TODAYPOINT}"
    if [ "$?" -ne "0" ]; then
        LOGTHIS "Unable to create the destination directory for this backup on ${TODAYPOINT}. ABORT."
        exit 31 ## This error code may violate some standard.
    fi
  fi
fi

# Now, let's check where the latest backup is, in case this
# parameter hasn't been passed as an argument.
if [[ ! "${LASTBACKUP}" ]]; then
  # This is the most recently CHANGED directory.
  LASTCHANGED="$(ls -dartF ${MOUNTPOINT}/BACKUP-$(hostname)-20[0-9\-]* | grep -v "${TODAY}" | tail -n1)"
  # ...and this is the most recently CREATED directory.
  LASTNAME="$(ls -da "${MOUNTPOINT}"/BACKUP-$(hostname)-*/ | grep -v ${TODAY} | sort | tail -n1)"

  # If $LASTCHANGED and $LASTNAME differ, choose $LASTNAME.
  if [ "${LASTCHANGED}" != "${LASTNAME}" ]; then
    LASTBACKUP="${LASTNAME}"
    LOGTHIS "${LASTCHANGED} has been changed more recently, but the name of ${LASTNAME} seems to indicate it should be more recent than ${LASTCHANGED}. I'm choosing ${LASTBACKUP}. If you disagree, please use option '-l' to inform where I can find the latest backup directory."
  else
    LASTBACKUP="${LASTCHANGED}"
  fi
fi

# $LASTBACKUP's path *has to* be relative in order to work
# with SSH.
LASTBACKUP="../$(basename "${LASTBACKUP}")"

LOGTHIS "The latest backup resides at: ${LASTBACKUP}"

# The backup is always performed starting on '/'. Choose
# what should and shouldn't be backed up:
rsync_includes='
# Whole home directories, except for what is unnecessary
+ /home
- /home/*/.local/share/Trash

# Only /mnt mount points, not their contents
+ /mnt
+ /mnt/*
- /mnt/*/*

# Whole /etc!
+ /etc

# Kernel configs (these lie in /usr/src/)
+ /usr
+ /usr/src
- /usr/src/*/
- /usr/*

# Whole /var!
+ /var

# Global: no .hg´s, no .git´s, no .cache´s
- **/.git/
- **/.hg/
- **/.cache/

# That´s enough
- /*
'

# Random name for the temp file that'll keep
# Rsync's {in,ex}cludes.
INCLUDE_FILE=/tmp/`head -c6 /dev/urandom | base64 -i | sed -e 's,[^[:alnum:]/],_,g'`.rsync.includes

# I'm so clever... :) This is where Rsync's include file is created.
echo "${rsync_includes}" > ${INCLUDE_FILE}
if [[ "$?" -ne "0" ]]; then
    LOGTHIS "Cannot create include file ${INCLUDE_FILE}. ABORT."
    exit 32 ## This error code may violate some standard.
fi

# We'd better use ionice's class 3 for this backup.
[ -x `which ionice` ] && IONICE="`which ionice` -c3 "

# If we're here, then it's mounted. Back it up, already!
BKPCMD="${IONICE} rsync ${SSH_OPTIONS} ${DRY_RUN} ${MAX_SIZE} -avP --hard-links --acls --xattrs --include-from=${INCLUDE_FILE:-/dev/null} --link-dest=${LASTBACKUP} / ${SSH_DIR_PREFIX}${TODAYPOINT%%/}/"
message="Running: $BKPCMD"
echo "$message"

LOGTHIS "$message"
# Only log stderr
${BKPCMD} 2>&1 1>/dev/null | logger -p local4.error -t ${PROGNAME}

# Delete the temporary {in,ex}clude file
#rm "${INCLUDE_FILE}"

# Unmount the backup disk when possible
#pumount ${MOUNTPOINT}

exit 0
# vim:ts=2 shiftwidth=2 et:
