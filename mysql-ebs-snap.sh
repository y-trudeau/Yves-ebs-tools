#!/bin/bash
#
# mysql_ebs_snap.sh version v 0.1 2013-06-24
# Yves Trudeau, Percona
# Inspired by zfs_snap of Nils Bausch
#
# take EBS snapshots with a time stamp
# -h help page
# -d choose default options: hourly, daily, weekly, monthly, yearly
# -f volume-id to snapshot 
# -m mysql mount point
# -v verbose output
# -p pretend - don't take snapshots
# -S mysql socket
# -u user mysql user
# -P mysql password 
# -w warmup script

DEBUGFILE="/tmp/mysql-ebs-snap.log"
if [ "${DEBUGFILE}" -a -w "${DEBUGFILE}" -a ! -L "${DEBUGFILE}" ]; then
        exec 9>>"$DEBUGFILE"
        exec 2>&9
        date >&9
        echo "$*" >&9
        set -x
else
        echo 9>/dev/null
fi
export PATH=$PATH:/sbin:/usr/sbin
# Path to binaries used
AWS=`which aws`
EGREP=`which egrep`
GREP=`which grep`
TAIL=`which tail`
SORT=`which sort`
XARGS=`which xargs`
DATE=`which date`
CUT=`which cut`
TR=`which tr`
MYSQL=`which mysql`
ECHO=`which echo`

# set default values
DEFAULTOPT=
PREFIX="MySQL"
LABEL=`${DATE} +"%FT%H:%M"`
vflag=
pflag=
socket=/tmp/mysql.sock
mysql_user=root
password=
filesystem=
warmup=
mysqlmount=/var/lib/mysql

# go through passed options and assign to variables
while getopts 'hd:l:m:vpu:S:P:f:w:' OPTION
do
        case $OPTION in
        d)      DEFAULTOPT="$OPTARG"
                ;;
        l)      LABELPREFIX="$OPTARG"
                ;;
        m)      mysqlmount="$OPTARG"
                ;;
        v)      vflag=1
                ;;
        p)      pflag=1
                ;;
        u)      mysql_user="$OPTARG"
                ;;
        f)      filesystem="$OPTARG"
                ;;
        S)      socket="$OPTARG"
                ;;
        P)      password="$OPTARG"
                ;;
        w)      warmup="$OPTARG"
                ;;
        h|?)      printf "Usage: %s: [-h] [-d <default-preset>] [-v] [-p] [-u <mysql user>] [-P <mysql password>] [-S <mysql socket>] [-f <EBS volume-id>] [-m <mysql datadi
r> [-w <warmup sql script>]\n" $(basename $0) >&2
                exit 2
                ;;
        esac
done

# go through possible presets if available
if [ -n "$DEFAULTOPT" ]; then
        case $DEFAULTOPT in
        hourly) LABELPREFIX="${PREFIX}_AutoH"
                LABEL=`${DATE} +"%FT%H:%M"`
                retention=24
                ;;
        daily)  LABELPREFIX="${PREFIX}_AutoD"
                LABEL=`${DATE} +"%F"`
                retention=7
                ;;
        weekly) LABELPREFIX="${PREFIX}_AutoW"
                LABEL=`${DATE} +"%Y-%U"`
                retention=4
                ;;
        monthly)LABELPREFIX="${PREFIX}_AutoM"
                LABEL=`${DATE} +"%Y-%m"`
                retention=12
                ;;
        yearly) LABELPREFIX="${PREFIX}_AutoY"
                LABEL=`${DATE} +"%Y"`
                retention=10
                ;;
        *)      printf 'Default option not specified\n'
                exit 2
                ;;
        esac
fi

if [ -z "$pflag" ]; then

        $MYSQL -N -n -u $mysql_user -p$password -S $socket > /${mysqlmount}/snap_master_pos.out <<EOF
flush tables with read lock;
flush logs;
show master status;
show slave status\G
\! sync
\! ${AWS} ec2 create-snapshot --volume-id ${filesystem} --description $LABELPREFIX-$LABEL > /tmp/snap.log
EOF

fi

        if [ "$vflag" ]; then
                echo "Snapshot taken"
        fi

if [ "$warmup" ]; then
        cat $warmup |  $MYSQL -N -u $mysql_user -p$password -S $socket &
fi

#DELETE SNAPSHOTS
# adjust retention to work with tail i.e. increase by one
let retention+=1
#if [ "$vflag" ]; then
#        echo "${AWS} ec2 describe-snapshots --filters "Name=description,Values=${LABELPREFIX}*" 
#fi

list=`${AWS} ec2 describe-snapshots --filters "Name=description,Values=${LABELPREFIX}*" --query 'Snapshots[*].{Description:Description,ID:SnapshotId}' --output text | ${SOR
T} -r | ${TAIL} -n +${retention} | while read line; do ${ECHO} "$line|"; done`

if [ ! -z "$pflag" ]; then
        if [ "${#list}" -gt 0 ]; then
                echo "Delete recursively:"
                echo "$list"
        else
                echo "No snapshots to delete"
        fi
else
        if [ "${#list}" -gt 0 ]; then
                IFS='|'
                for snap in $list; do 
                        snapid=`echo $snap | tr -d '\n' | awk '{ print $2}'`;
                        if [ "$vflag" ]; then
                                echo "Deleting snapshot $snapid"
                        fi
                        $AWS ec2 delete-snapshot --snapshot-id $snapid
                        sleep 5 # API is throttled
                done 
                unset IFS
        fi
fi

