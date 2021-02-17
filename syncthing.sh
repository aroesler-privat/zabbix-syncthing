#!/bin/bash

CURL=$(which curl)
JQ=$(which jq)
DATE=$(which date)
ZABBIX_SENDER=$(which zabbix_sender)

SYNCTHING_HOST=""
SYNCTHING_FOLDER=""
SYNCTHING_ACTION=""

declare -a SYNCTHING_HOSTS
declare -A SYNCTHING_IP
declare -A SYNCTHING_PORT
declare -A SYNCTHING_API
declare -A SYNCTHING_DEVID

ZABBIX_INPUT=""
ZABBIX_SERVER="127.0.0.1"
ZABBIX_HOST=""
ZABBIX_DRYRUN=0

function create_zabbix_input() { ##############################################
# creates input for zabbix_send-command                                       #
# -> no parameter: initializes STRING to ""                                   #
# -> any parameter is added to the string                                     #
# -> format: ZABBIXHOST_NAME ZABBIXITEM_KEY TIMESTAMP VALUE                   #
# -> per function-call a newline is added                                     #
# -> use as: echo $ZABBIX_INPUT | tr '|' '\n'                                 #
###############################################################################
	if [ "$#" == 0 ] ; then
		ZABBIX_INPUT=""
	elif [ -z "$ZABBIX_INPUT" ]; then
		ZABBIX_INPUT="$*"
	else
		ZABBIX_INPUT+='|'"$*"
	fi
}

function send_to_zabbix() { ###################################################
# sends $ZABBIX_INPUT to $ZABBIX_SERVER                                       #
###############################################################################

        if [ "$ZABBIX_DRYRUN" == "0" ] ; then
                echo "$ZABBIX_INPUT" | tr '|' '\n' | \
		if RESULT=$($ZABBIX_SENDER -z $ZABBIX_SERVER -T -i -)
		then 
		echo "send_to_zabbix failed with $RESULT, command was $ZABBIX_INPUT"
		fi
        else
                echo "$ZABBIX_INPUT" | tr '|' '\n'
        fi
}


function add_syncthing_host() { ###############################################
# adds syncthing-host to be monitored                                         #
# - add_syncthing_host $HOST $IP $PORT $APIkey                                #
###############################################################################
	HOST=$1
	IP=$2
	PORT=$3
	APIkey=$4

	SYNCTHING_IP[$HOST]=$IP
	SYNCTHING_PORT[$HOST]=$PORT
	SYNCTHING_API[$HOST]=$APIkey

	SYNCTHING_DEVID[$HOST]=$($CURL -s -X GET -H "X-API-Key: ${SYNCTHING_API[$HOST]}" http://"${SYNCTHING_IP[$HOST]}":"${SYNCTHING_PORT[$HOST]}"/rest/system/status | $JQ ".myID" | sed -es/"^\"\([^\"]*\)\"$"/"\1"/)

	SYNCTHING_HOSTS+=( "$HOST" )
}

function get_folder_id() { ####################################################
# receives ID of a given foldername                                           #
# - get_folder_id $HOST $FOLDERNAME                                           #
# - returns ID of the folder labeled "$FOLDERNAME"                            #
###############################################################################
	HOST=$1
	NAME=$2

	ID=$($CURL -s -X GET -H "X-API-Key: ${SYNCTHING_API[$HOST]}" http://"${SYNCTHING_IP[$HOST]}":"${SYNCTHING_PORT[$HOST]}"/rest/system/config | $JQ ".folders[] | select(.label | contains(\"$NAME\"))" | $JQ '.id' | sed -es/"^\"\([^\"]*\)\"$"/"\1"/)

	echo -n "$ID"
}

function get_folder_device_ids() { ############################################
# receives IDs of devices that sync a given foldername                        #
# - get_folder_device_ids $HOST $FOLDERNAME                                   #
# - returns list of IDs, filters the ID of $HOST                              #
###############################################################################
	HOST=$1
	NAME=$2

	IDS=$($CURL -s -X GET -H "X-API-Key: ${SYNCTHING_API[$HOST]}" http://"${SYNCTHING_IP[$HOST]}":"${SYNCTHING_PORT[$HOST]}"/rest/system/config | $JQ ".folders[] | select(.label | contains(\"$NAME\"))" | $JQ ".devices[] | .deviceID" | sed -es/"^\"\([^\"]*\)\"$"/"\1"/ | tr '\n' ' ')

	echo -n "$IDS" | sed -es/"${SYNCTHING_DEVID[$HOST]}"/""/
}

function get_folder_lastsync_time() { #########################################
# receives timestamp when last file of folder was synced                      #
# - get_folder_lastscan $HOST $FOLDERNAME                                     #
# - returns timestamp                                                         #
###############################################################################
	HOST=$1
	NAME=$2

	ID=$(get_folder_id "$HOST" "$NAME")

	LASTSCAN=$($CURL -s -X GET -H "X-API-Key: ${SYNCTHING_API[$HOST]}" http://"${SYNCTHING_IP[$HOST]}":"${SYNCTHING_PORT[$HOST]}"/rest/stats/folder | $JQ ".\"$ID\".lastFile.at" | sed -es/"^\"\([^\"]*\)\"$"/"\1"/)

	LAST_SEC=$($DATE -d "$LASTSCAN" +"%Y-%m-%d %H:%M.%S")

	echo -n "$LAST_SEC"
}

function get_folder_lastsync_file() { #########################################
# receives name of the last file that has been synced in given folder         #
# - get_folder_lastscan $HOST $FOLDERNAME                                     #
# - returns string with name of file                                          #
###############################################################################
	HOST=$1
	NAME=$2

	ID=$(get_folder_id "$HOST" "$NAME")

	LASTFILE=$($CURL -s -X GET -H "X-API-Key: ${SYNCTHING_API[$HOST]}" http://"${SYNCTHING_IP[$HOST]}":"${SYNCTHING_PORT[$HOST]}"/rest/stats/folder | $JQ ".\"$ID\".lastFile.filename" | sed -es/"^\"\([^\"]*\)\"$"/"\1"/)

	echo -n "$LASTFILE"
}

function get_folder_lastscan() { ##############################################
# receives timestamp when folder was scanned last time                        #
# - get_folder_lastscan $HOST $FOLDERNAME                                     #
# - returns timestamp                                                         #
###############################################################################
	HOST=$1
	NAME=$2

	ID=$(get_folder_id "$HOST" "$NAME")

	LASTSCAN=$($CURL -s -X GET -H "X-API-Key: ${SYNCTHING_API[$HOST]}" http://"${SYNCTHING_IP[$HOST]}":"${SYNCTHING_PORT[$HOST]}"/rest/stats/folder | $JQ ".\"$ID\".lastScan" | sed -es/"^\"\([^\"]*\)\"$"/"\1"/)

	LAST_SEC=$($DATE -d "$LASTSCAN" +"%Y-%m-%d %H:%M.%S")

	echo -n "$LAST_SEC"
}

function get_folder_status() { ################################################
# requests status of a given folder                                           #
# - get_folder_status $HOST $ID <$FLAGS>                                      #
# - if $FLAGS is not given, all flags will be printed as JSON-string          #
# - if $FLAGS is given:                                                       #
#   -> per FLAG $SYNCTHING_KEY-$FLAG will be set to flag-value                #
#   -> FLAG, Value and Timestamp will be send via zabbix_sender               #
#   -> returns amount of errors                                               #
###############################################################################
	HOST=$1
	NAME=$2
	FLAGS=$3

	ID=$(get_folder_id "$HOST" "$NAME")

	STATUS=$($CURL -s -X GET -H "X-API-Key: ${SYNCTHING_API[$HOST]}" http://"${SYNCTHING_IP[$HOST]}":"${SYNCTHING_PORT[$HOST]}"/rest/db/status?folder="$ID")

	if [ -z "$FLAGS" ] ; then
		echo "$STATUS"
		exit 0
	else
		TIME=$(echo "$STATUS" | $JQ ".stateChanged" | sed -es/"^\"\([^\"]*\)\"$"/"\1"/)
		TIMESTAMP=$($DATE -d "$TIME" +"%s")

		create_zabbix_input

		for FLAG in $(echo "$FLAGS" | tr ',' ' ') ; do
			VALUE=$(echo "$STATUS" | $JQ ".$FLAG" | sed -es/"^\"\([^\"]*\)\"$"/"\1"/)
			create_zabbix_input "$ZABBIX_HOST" "$FLAG" "$TIMESTAMP" "$VALUE"
		done

		send_to_zabbix
	fi

	RETURN=$(echo "$STATUS" | $JQ ".errors")

	echo -n "$RETURN"
}

function get_device_name() { ##################################################
# recieves name of a device specified by its deviceID                         #
# - get_device_name $HOST $ID                                                 #
# - returns name of the device                                                #
###############################################################################
	HOST=$1
	ID=$2

	NAME=$($CURL -s -X GET -H "X-API-Key: ${SYNCTHING_API[$HOST]}" http://"${SYNCTHING_IP[$HOST]}":"${SYNCTHING_PORT[$HOST]}"/rest/system/config | $JQ ".devices[] | select(.deviceID | contains(\"$ID\"))" | $JQ ".name")

	echo -n "$NAME" | sed -es/"^\"\([^\"]*\)\"$"/"\1"/
}

function get_device_lastseen() { ##############################################
# receives last time when a device was seen                                   #
# - get_device_lastseen $HOST $ID                                             #
# - returns last time a device was seen as unix-timestamp                     #
###############################################################################
	HOST=$1
	ID=$2

	LASTSEEN=$($CURL -s -X GET -H "X-API-Key: ${SYNCTHING_API[$HOST]}" http://"${SYNCTHING_IP[$HOST]}":"${SYNCTHING_PORT[$HOST]}"/rest/stats/device | jq ".\"$ID\".lastSeen" | sed -es/"^\"\([^\"]*\)\"$"/"\1"/)

	LAST_SEC=$($DATE -d "$LASTSEEN" +"%Y-%m-%d %H:%M.%S")

	echo -n "$LAST_SEC"
}

## Adding static syncthing-hosts ##############################################
###############################################################################

# add_syncthing_host "myHost" "192.168.1.1" "8384" "mykeymykeymykey"

## check command-line parameters ##############################################
###############################################################################

HOSTIP="127.0.0.1"
HOSTPORT="8384"
HOSTAPI=""

for PARAM in "$@" ; do
	OPTION=$(echo "$PARAM" | sed -es/"^\([^=]*\)=.*$"/"\1"/)
	VALUE=$(echo "$PARAM" | sed -es/"^[^=]*=\([^=]*\)$"/"\1"/ | grep -v "^--")

	case $OPTION in 
		"--ip")
			[ -z "$SYNCTHING_HOST" ] && SYNCTHING_HOST=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 13)
			HOSTIP="$VALUE"
			;;
		"--port")
			[ -z "$SYNCTHING_HOST" ] && SYNCTHING_HOST=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 13)
			HOSTPORT="$VALUE"
			;;
		"--apikey")
			[ -z "$SYNCTHING_HOST" ] && SYNCTHING_HOST=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 13)
			HOSTAPI="$VALUE"
			;;
		"--host")
			if [[ ! " ${SYNCTHING_HOSTS[*]} " == *" ${VALUE} "* ]] ; then
				echo "Host '$VALUE' is not known by the script"
				echo "Please define '$VALUE' by calling add_syncthing_host"
				exit 0
			fi
			SYNCTHING_HOST=$VALUE
			;;
		"--folder")
			SYNCTHING_FOLDER=$VALUE
			;;
		"--last-seen")
			SYNCTHING_ACTION="lastseen"
			;;
		"--last-sync")
			SYNCTHING_ACTION="lastsync"
			;;
		"--last-scan")
			SYNCTHING_ACTION="lastscan"
			;;
		"--last-file")
			SYNCTHING_ACTION="lastfile"
			;;
		"--status")
			SYNCTHING_ACTION="status"
			SYNCTHING_STATUS_FLAGS=$VALUE
			;;
		"--zabbix-dryrun")
			ZABBIX_DRYRUN=1
			;;
		"--zabbix-server")
			ZABBIX_SERVER=$VALUE
			;;
		"--zabbix-host")
			ZABBIX_HOST=$VALUE
			;;
		"--help")
			echo "Usage: $0 [parameter]"
			echo ""
			echo "You must either define a Syncthing-Host via ..."
			echo "--ip=<IP>        - IP of syncthing host (default: $HOSTIP)"
			echo "--port=<Port>    - TCP-port syncthing host is listening (default: $HOSTPORT)"
			echo "--apikey=<key>   - API-Key of given syncthing host"
			echo ""
			echo "... or refer to a host hardcoded as add_syncthing_host via ..."
			echo "--host=<host>    - name of a hardcoded syncthing_host (don't use with --ip, --port or --apikey)"
			echo ""
			echo "--folder=<label> - label of folder"
			echo ""
			echo "Actions:"
			echo "--last-seen      - timestamp, when device owning given folder was last time seen"
			echo "--last-sync      - timestamp, when last file of given folder was synced"
			echo "--last-file      - name of the last file that has been synced"
			echo "--last-scan      - timestamp, when folder was scanned last time"
			echo "--status=<flags> - returns status of given folder, <flags>=empty prints all available flags (requires zabbix)"
			echo ""
			echo "--zabbix-dryrun  - does not send anything to zabbix but print commands"
			echo "--zabbix-server  - give address of Zabbix-Server (default: $ZABBIX_SERVER)"
			echo "--zabbix-host    - values given in --status=<flags> will be stored as FLAG=VALUE in given Zabbix host"
			exit 0
			;;
		*)
			echo "use $0 --help to get help"
			exit 0
			;;
	esac
done

if [ -z "$SYNCTHING_HOST" ] ; then
	echo "You must define a syncthing-host via --host or --ip/--port/--apikey"
	exit 0
fi

## if not hardcoded host should be added: do it ###############################
###############################################################################
if [[ ! " ${SYNCTHING_HOSTS[*]} " == *" ${SYNCTHING_HOST} "* ]] ; then
	if [ -z "$HOSTAPI" ] ; then
		echo "If --ip and/or --port are defined to add a syncthing-host, --apikey is required"
		echo "You may hard-code syncthing-hosts into the script by calling add_syncthing_host"
		exit 0
	fi
	add_syncthing_host "$SYNCTHING_HOST" "$HOSTIP" "$HOSTPORT" "$HOSTAPI"
fi

###############################################################################
###############################################################################

case "$SYNCTHING_ACTION" in
	"lastseen")
		DEVS=$(get_folder_device_ids "$SYNCTHING_HOST" "$SYNCTHING_FOLDER")

		for DEV in $DEVS ; do
			RETURN=$(get_device_lastseen "$SYNCTHING_HOST" "$DEV")
		done
		;;
	"lastsync")
		RETURN=$(get_folder_lastsync_time "$SYNCTHING_HOST" "$SYNCTHING_FOLDER")
		;;
	"lastscan")
		RETURN=$(get_folder_lastscan "$SYNCTHING_HOST" "$SYNCTHING_FOLDER")
		;;
	"lastfile")
		RETURN=$(get_folder_lastsync_file "$SYNCTHING_HOST" "$SYNCTHING_FOLDER")
		;;
	"status")
		if [ -z "$ZABBIX_HOST" ] && [ -n "$SYNCTHING_STATUS_FLAGS" ] ; then
			echo "--zabbix-host is required when asking for status"
			exit 1
		fi
		RETURN=$(get_folder_status "$SYNCTHING_HOST" "$SYNCTHING_FOLDER" "$SYNCTHING_STATUS_FLAGS")
		;;
esac

echo "$RETURN"

exit 0
