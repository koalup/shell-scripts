#!/bin/bash
########################################################################################################################
#-
#- NAME
#-      rman-backup.sh - RMAN backup script
#- 
#- SYNOPSIS
#-      rman-backup.sh [OPTIONS] TARGET BACKUP_TYPE
#+      rman-backup.sh	[-dDhn] 
#+				[-A {applied|shipped}]
#+				[-c channels] 
#+				[-C catalog_connect_string] 
#+				[-f format] 
#+				[-F filesperset] 
#+				[-i {0|D|C}] 
#+				[-l logdir] 
#+				[-m email,email,...] 
#+				[-o maxopenfiles]
#+				[-p parm]
#+				[-r {primary|physical}]
#+				[-s maxpiecesize]
#+				[-t tag] 
#+				[-u db_unique_name]
#+				[-w days] 
#+				[-y {disk|sbt_tape}] 
#+ 				TARGET{,TARGET,...} 
#+				{ALL|ARCHIVELOG|CONTROLFILE|DATABASE|DATAFILECOPY|CUSTOM cmdfile}
#-
#- DESCRIPTION
#-	TARGET(s)		Target database(s). This can be a comma separated list of targets. When specifying multiple targets,
#-				they must all be part of the same Data Guard environment. DO NOT specify multiple targets if they
#-				are not part of the same Data Guard environment. 
#-				Each target can be:
#-					- An ORACLE_SID, if this script runs on the database host, or 
#-					- A SQL*Net connect string, if this script runs on a remote host. Using a wallet in this case is highly recommended.
#-	BACKUP_TYPE		Type of backup. Valid values are
#-					ALL	  	 - Backup database, current controlfile, and archivelogs
#-					ARCHIVELOG	 - Backup archivelogs only
#-					CONTROLFILE	 - Backup controlfile only
#-					DATABASE	 - Backup database and current controlfile only
#-					DATAFILECOPY	 - Backup database using datafilecopy method. Includes current controlfile and archivelogs
#-					CUSTOM {cmdfile} - Use a custom cmdfile
#-	
#- OPTIONS
#-	-A {applied|shipped}	Manage the archive log deletion policy in a standby environment.
#-				DEVICE_TYPE (-y) must be explicitly set to SBT and a catalog must be specified (-C) 
#-				otherwise this parameter is ignored
#-	-c integer		Number of channels to allocate. Device type must be
#-				be specified if using this option.
#-	-C string		Catalog connect string
#-	-d			Delete all archivelogs after they have been backed up
#-	-D			Delete obsolete backups
#-	-f string		Format of backup. When specifying a wildcard in a cron
#-				job, you must escape all instances of % with \
#-	-F number		Specify FILESPERSET
#-	-h			Show help
#-	-i { 0 | C | D }	Speficy an incremental backup. Valid values are
#-					0 - Incremental level 0
#-					C - Incremental level 1 cumulative
#-					D - Incremental level 1 diferential
#-	-l string		Log directory
#-	-m string		Comma separated list of emails that the log should be sent to
#-	-n			Backup only archivelogs that have not been backed up.
#-	-o			Specify MAXOPENFILES
#-	-p			Specify PARM
#-	-r string		Specify database role. Valid values are PRIMARY and PHYSICAL.	
#-	-s integer[K|M|G]	Specifies a maximum size per backup piece. At least one
#-				channel must be specified when using this parameter.
#-	-t string		Backup tag.
#-	-u string		Specify DB_UNIQUE_NAME.
#-	-w number		Retention window for DATAFILECOPY backups in days
#-	-y {disk|sbt_tape}	Device type. Defaults to DISK. 
#-      
########################################################################################################################
export PATH=/bin:/usr/bin:/usr/local/bin:.
export NLS_DATE_FORMAT='YYYY-MM-DD.HH24:MI:SS'
export ORAENV_ASK=NO

NAME="${0##*/}"
BASE=$(cd "${0%/*}"; pwd)

ENV_ORA_HOME=${ORACLE_HOME:-""}
SQLPLUS_OPTS="SET LIN 400 PAGES 0 HEAD OFF FEED OFF VERIFY OFF; WHENEVER SQLERROR EXIT 1; WHENEVER OSERROR EXIT 1"

showusage () {
	echo "usage:" >&2
	awk '/^\#\+/ {print $0}' ${BASE}/${NAME} | sed 's/^#+/ /' >&2
}
	
showhelp () {
        awk '/^\#-/ {print $0}' ${BASE}/${NAME} | sed 's/^#-/ /'
}

run_sqlplus () {
	local conn_str=${1}
	local cmd_str="connect ${conn_str};${2}"
	local cmd=""
	local stat=0

	if [[ -z "${ORACLE_HOME}" ]];	then echo "${FUNCNAME}(): ORACLE_HOME is not set"; return 1; fi
	if [[ $# -ne 2 ]]; 		then echo "${FUNCNAME}(): Invalid number of arguments"; return 1; fi

	while read line; do
		if [[ "${line%%-*}" = "ORA" ]];	then 
			stat=1 
		fi

		if [[ ${stat} -eq 1 ]];	then 
			echo "${line}" 1>&2
		else 
			echo "${line}"
		fi
	done < <(
		OLD_IFS=${IFS}; IFS=";"
		for cmd in ${cmd_str}; do
			echo "${cmd};"
		done | ${ORACLE_HOME}/bin/sqlplus -s /nolog 2>&1 || echo "ORA-EXIT: Status was non 0"
		IFS=${OLDOFS}
        )
        return ${stat}
}

get_target_details () {

	local targets=$(echo "${1}" | awk '{ n=split($0,targets,","); for (i=1;i<=n;i++) printf targets[i]" "; }')

	for target in ${targets}; do

		unset ORACLE_HOME
		unset ORACLE_SID

		connect_string=${target}
		score=0

		if [[ "${target}" = "${target%@*}" ]]; then
			export ORACLE_SID="${target}"
			. oraenv < <(echo 0) > /dev/null 2>&1
			connect_string=/
			
			if [[ "${ORACLE_HOME}" = "0" ]]; then 
				echo "${score},${target},n/a,n/a,ERROR: ${target} is not in the oratab file"
				continue
			fi
		else 
			if [[ -z "${ENV_ORA_HOME}" ]]; then
				echo "${score},${target},n/a,n/a,ERROR: ORACLE_HOME environment variable not set"
				continue
			fi
			export ORACLE_HOME=${ENV_ORA_HOME}
		fi
		
		res=$(run_sqlplus "${connect_string} as sysdba" "${SQLPLUS_OPTS}; select DB_UNIQUE_NAME||','||DATABASE_ROLE from v\$database;" 2>&1) || { 
			echo "${score},${target},n/a,n/a,$(echo $(echo "${res}" | grep ^ORA))"
			continue; 
		}

		if [[ "${res#*,}" = "PHYSICAL STANDBY"  ]];	then score=$(( ${score} + 1 )); fi
		if [[ "${res#*,}" = "PRIMARY" 		]]; 	then score=$(( ${score} + 2 )); fi
		if [[ "${res%,*}" = "${DB_UNIQUE_NAME}" ]];	then score=$(( ${score} + 4 )); fi
		if [[ "${res#*,}" = "${DATABASE_ROLE}"  ]]; 	then score=$(( ${score} + 8 )); fi
		
		echo "${score},${target},${res%,*},${res#*,},OK"

	done | sort -rn
}

set_archlog_deleletion_policy () {

	local stat=0

	echo "${TARGET_TAB}" | awk -F, '/^[0-9]/ {print $1,$2,$3}' | while read score target db_unique_name; do
		if [[ ${score} -eq 0 ]]; then
			echo "WARNING: Unable to CONFIGURE ARCHIVELOG DELETION POLICY for ${target} because it is unavailable or invalid."
			continue
		fi

		if [[ "${target}" = "${TARGET}" ]]; then
			ADP_CMD="${ARCHIVELOG_DELETION_POLICY} BACKED UP 1 TIMES TO ${DEVICE_TYPE}"
		else
			ADP_CMD="${ARCHIVELOG_DELETION_POLICY}"
		fi
		echo "Running '${ADP_CMD} | ${ORACLE_HOME}/bin/rman target ${target} ${CATALOG_CONNECT_STRING}'"
		res=$(echo "${ADP_CMD};" | ${ORACLE_HOME}/bin/rman target ${target} ${CATALOG_CONNECT_STRING}) || { 
			echo "WARNING: '${ADP_CMD} ${ORACLE_HOME}/bin/rman target ${target} ${CATALOG_CONNECT_STRING}' FAILED"; 
			echo "${res}" | grep ^RMAN
			stat=1
		}
	done
	
	return ${stat}

}

while getopts ":A:c:C:dDf:F:hi:l:m:no:p:r:s:t:u:w:y:" opt; do
	case "${opt}" in
		A)	case $(echo ${OPTARG} | tr [a-z] [A-Z]) in
				SHIPPED)	ARCHIVELOG_DELETION_POLICY="CONFIGURE ARCHIVELOG DELETION POLICY TO SHIPPED TO ALL STANDBY";;
				APPLIED)	ARCHIVELOG_DELETION_POLICY="CONFIGURE ARCHIVELOG DELETION POLICY TO APPLIED ON ALL STANDBY";;
				*)		echo "ERROR: invalid archive log deletion policy" >&2; exit 1;;
			esac;;
		c)	CHANNELS=${OPTARG};;
		C)	CATALOG_CONNECT_STRING="catalog ${OPTARG}";;
		d)	DELETE_INPUT="DELETE ALL INPUT";;
		D)	DELETE_OBSOLETE="DELETE NOPROMPT OBSOLETE;";;
		f)	FORMAT="FORMAT '${OPTARG}'";;
		F)	FILESPERSET="FILESPERSET=${OPTARG}";;
		h)	showhelp; exit;;
		i)	case "${OPTARG}" in 
				0)	INCREMENTAL_LEVEL="INCREMENTAL LEVEL 0";;
				[Dd])	INCREMENTAL_LEVEL="INCREMENTAL LEVEL 1";;
				[Cc])	INCREMENTAL_LEVEL="INCREMENTAL LEVEL 1 CUMULATIVE";;	
				*)	echo "ERROR: invalid incremental level" >&2; exit 1;;
			esac;;
		l)	LOGD="${OPTARG}";;
		m)	MAILLIST="${OPTARG}";;
		n)	NOT_BACKED_UP="NOT BACKED UP";;
		o)	MAXOPENFILES="MAXOPENFILES ${OPTARG}";;
		p)	PARMS="PARMS='${OPTARG}'";;
		r)	case $(echo "${OPTARG}" | tr [a-z] [A-Z]) in
				PRIMARY)	DATABASE_ROLE="PRIMARY";;
				PHYSICAL)	DATABASE_ROLE="PHYSICAL STANDBY";;
				*)		echo "ERROR: invalid database role" >&2; exit 1;;
			esac;;
		s)	MAXPIECESIZE="MAXPIECESIZE ${OPTARG}";;
		t)	TAG="TAG='${OPTARG}'";;
		u)	DB_UNIQUE_NAME="${OPTARG}";;
		w)	DATAFILECOPY_RETENTION_WINDOW="UNTIL TIME 'SYSDATE - ${OPTARG}'";;
		y)	case $(echo "${OPTARG}" | tr [a-z] [A-Z]) in 
				DISK)		DEVICE_TYPE="DEVICE TYPE DISK";;
				SBT|SBT_TAPE)	DEVICE_TYPE="DEVICE TYPE SBT_TAPE";;
				*)		echo "ERROR: invalid device type" >&2; exit 1;;
			esac
			;;
		\?)	showusage; exit;;
	esac
done
shift $((${OPTIND} - 1))

if [[ $# -lt 2 ]]; 							then showusage; exit; fi
if [[ ${CHANNELS:-"0"} -gt 0 ]] && [[ -z "${DEVICE_TYPE:-""}" ]]; 	then echo "ERROR: a device type must be spefified when using channels" >&2; exit 1; fi
if [[ ${CHANNELS:-"0"} -eq 0 ]] && [[ -n "${MAXPIECESIZE:-""}" ]]; 	then echo "ERROR: at least one channel must be specified when using max piece size" >&2; exit 1; fi
if [[ ${CHANNELS:-"0"} -eq 0 ]]; 					then DEVICE_TYPE_AUTO=${DEVICE_TYPE:-""}; fi

TARGETS=${1}
BCKUP_TYPE=$(echo ${2} | tr [a-z] [A-Z])

TARGET_TAB="$(get_target_details ${TARGETS})"
TARGET=$(echo "${TARGET_TAB}" | awk -F, '/^[1-9]/ && FNR==1 {print $2}')
TUNAME=$(echo "${TARGET_TAB}" | awk -F, '/^[1-9]/ && FNR==1 {print $3}')
DBROLE=$(echo "${TARGET_TAB}" | awk -F, '/^[1-9]/ && FNR==1 {print $4}')
TCOUNT=$(echo "${TARGET_TAB}" | grep ^[0-9] | wc -l)

LOGD="${LOGD:-"${BASE}/${NAME%.*}-logs"}"
LOGF="${LOGD}/${NAME%.*}_${TUNAME:-"UNDEFINED"}_${BCKUP_TYPE}_$(date "+%Y-%m-%d.%H%M").log"

if ! mkdir -p "${LOGD}";	then echo "ERROR: unable to create log directory ${LOGD}" >&2; exit 1; fi
if ! touch    "${LOGF}";	then echo "ERROR: unable to create log file ${LOGF}" >&2; exit 1; fi

case ${BCKUP_TYPE} in 
	ALL)		BCKUP_CMD="BACKUP ${TAG:-""} ${DEVICE_TYPE_AUTO:-""} ${FORMAT:-""} ${FILESPERSET} ${INCREMENTAL_LEVEL:-""} DATABASE INCLUDE CURRENT CONTROLFILE PLUS ARCHIVELOG ${NOT_BACKED_UP:-""} ${DELETE_INPUT:-""};";;
	ARCHIVELOG)	BCKUP_CMD="BACKUP ${TAG:-""} ${DEVICE_TYPE_AUTO:-""} ${FORMAT:-""} ${FILESPERSET} ARCHIVELOG ALL ${NOT_BACKED_UP:-""} ${DELETE_INPUT:-""};";;
	CUSTOM)		CMDFILE="${3:-""}"; if [[ ! -f "${CMDFILE}" ]]; then echo "ERROR: cmdfile ${CMDFILE} does not exist" >&2; exit 1; fi;;
	CONTROLFILE)	BCKUP_CMD="BACKUP ${TAG:-""} ${DEVICE_TYPE_AUTO:-""} ${FORMAT:-""} CURRENT CONTROLFILE;";;
	DATABASE)	BCKUP_CMD="BACKUP ${TAG:-""} ${DEVICE_TYPE_AUTO:-""} ${FORMAT:-""} ${FILESPERSET} ${INCREMENTAL_LEVEL:-""} DATABASE INCLUDE CURRENT CONTROLFILE;";;
	DATAFILECOPY)	BCKUP_CMD="RECOVER COPY OF DATABASE WITH TAG 'IMAGECOPY' ${DATAFILECOPY_RETENTION_WINDOW};
BACKUP INCREMENTAL LEVEL 1 FOR RECOVER OF COPY WITH TAG 'IMAGECOPY' DATABASE INCLUDE CURRENT CONTROLFILE PLUS ARCHIVELOG ${NOT_BACKED_UP:-""} ${DELETE_INPUT:-""};";;
	*)		showusage; exit 1;;
esac

main () {
	local stat=0

	echo "START:	$(date)"
	echo "SCRIPT:	$(hostname):${BASE}/${NAME}"
	echo "LOG:	$(hostname):${LOGF}"
	echo ""
	echo "TARGET DETAILS:"
	echo "${TARGET_TAB}" | awk -F, '
		BEGIN { format = "%-10s %-20s %-20s %-20s %-80s\n"; printf format,"score","target","db_unique_name","database_role","status"}
		{ printf format,$1,$2,$3,$4,$5; }
	'

	if [[ -z "${TARGET}" ]]; then echo "ERROR: Unable to find a suitable target to back up."; return 1; fi

	export ORACLE_HOME=${ENV_ORA_HOME}
	if [[ ${TARGET} = ${TARGET%@*} ]]; then
		export ORACLE_SID=${TARGET}
		. oraenv < <(echo 0) > /dev/null 2>&1
		TARGET=/
	fi

	echo ""
	echo "SELECTED: TARGET=${TARGET}, DB_UNIQUE_NAME=${TUNAME}, DATABASE_ROLE=${DBROLE}"
	echo ""

	if [[ ${TCOUNT} -ge 2 ]]; then
		if [[ -z "${CATALOG_CONNECT_STRING}" ]];		then echo "WARNING: You are backing up a standby database environment without specifying a catalog (-C). This is a really bad idea!"; fi
		if [[ "${DEVICE_TYPE}" != "DEVICE TYPE SBT_TAPE" ]]; 	then echo "WARNING: You are backing up a standby database environment wihtout specifying DEVICE_TYPE (-y) of SBT_TAPE. This is a really bad idea!"; fi
		if [[ -n "${ARCHIVELOG_DELETION_POLICY}" ]]; then
			if [[ "${DEVICE_TYPE}" != "DEVICE TYPE SBT_TAPE" ]] || [[ -z "${CATALOG_CONNECT_STRING}" ]]; then
				echo "WARNING: Ingnoring ARCHIVELOG DELETION POLICY management (-A) because either DEVICE_TYPE (-y) is not SBT_TAPE or a catalog (-C) has not been specified."
				unset ARCHIVELOG_DELETION_POLICY
			fi
		fi
		if [[ -z "${ARCHIVELOG_DELETION_POLICY}" ]]; 		then echo "WARNING: ARCHIVELOG DELETION POLICY is not managed by this script. It will have to be done manually in the event of a failover/switchover."; fi
	fi

	if [[ ${BCKUP_TYPE} = "CUSTOM" ]]; then
		${ORACLE_HOME}/bin/rman target ${TARGET} ${CATALOG_CONNECT_STRING} cmdfile "${CMDFILE}" || stat=1
	else

		if [[ -n "${ARCHIVELOG_DELETION_POLICY}" ]]; then
			set_archlog_deleletion_policy || stat=1
		fi

		RMAN_CMD=$(	
			echo "run {"

			i=0 
			while [[ ${i} -lt ${CHANNELS:-"0"} ]]; do 
				i=$(( ${i} + 1 ))
				echo "ALLOCATE CHANNEL C${i} ${DEVICE_TYPE} ${PARMS:-""} ${MAXPIECESIZE:-""} ${MAXOPENFILES:-""};"
			done

			echo "${BCKUP_CMD:-"#"}"
              		echo "${DELETE_OBSOLETE:-"#"}"

			i=0
			while [[ ${i} -lt ${CHANNELS:-"0"} ]]; do 
				i=$(( ${i} + 1 ))
				echo "RELEASE CHANNEL C${i};"
			done
	      		echo "}"

		) 

		echo "Running '${RMAN_CMD} | ${ORACLE_HOME}/bin/rman target ${TARGET} ${CATALOG_CONNECT_STRING}'"
		echo "${RMAN_CMD}" | ${ORACLE_HOME}/bin/rman target ${TARGET} ${CATALOG_CONNECT_STRING} || stat=1

		# running this again triggers recaltulation of recovery area utilization
		if [[ -n "${ARCHIVELOG_DELETION_POLICY}" ]]; then
			set_archlog_deleletion_policy || stat=1
		fi
	fi
	echo "END: $(date)"
	return ${stat}
}
# main || exit 1
main > ${LOGF} 2>&1 || { if [[ -n "${MAILLIST}" ]]; then mail -s "Backup of database ${TUNAME} from $(hostname) failed" ${MAILLIST} < ${LOGF}; fi; exit 1; }
if [[ -n "${MAILLIST}" ]]; then mail -s "Backup of database ${TUNAME} from $(hostname) was successful" ${MAILLIST} < ${LOGF}; fi; exit 0
