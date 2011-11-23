#!/usr/bin/bash
#
# Started by:
# http://adumont.serveblog.net/2009/09/01/virtualbox-smf-2/
#
# This SMF method is distributed under the following MIT License terms:
#
# Copyright (c) 2009 Alexandre Dumont
# (C) 2009 minor patches by Jim Klimov: start "saved" machines
# (C) 2010-2011 larger patches by Jim Klimov, JCS COS&HT
#       $Id: vbox.sh,v 1.49 2011/11/23 13:53:06 jim Exp $
#	* process aborted, paused VM's
#	* "vm/debug_smf" flag, "vm/nice" flag.
#       * Inherit service-level default attribute values.
#	* KICKER to monitor VirtualBox VM state and restart or force
#	  SMF-maintenance state
#	  NOTE: this script can cause SMF "offline" state for service instance
#	  (not easily noticeable "maintenance") in cases that the VM became
#	  'paused', 'saved', 'poweroff' and appropriate 'vm/restart_X_vm'
#	  SMF property flags are not true, or VM got into unknown state.
#	  The offline state is temporary (i.e. until reboot). It can be set
#	  only if the execution user has RBAC rights to change SMF service
#	  state with svcadm. If that fails, script causes 'maintenance' mode.
#	** Special flag 'vm/offline_is_maint = true' causes the service to
#	  always go into SMF 'maintenance' mode, even if it can technically
#	  go 'offline'.
#	* Setting of a timezone value to change the VM's "hardware clock" zone
#	  i.e. to UTC for all server VMs regardless of host OS default timezone
#	* Command-line mode to intercept a VM into GUI mode,
#	  then return it to SMF execution
#	* Hook to a procedure (ext script) to check states of services
#	  running inside the VM (i.e. ping, check website or DB) and react
#	  by reset or maintenance... See $KICKER_VMSVCCHECK_* params.
#	* Graceful Reboot/Quick Reset actions
#    NOTE: Some features require GNU date (gdate) in PATH, see $GDATE below.
#
#
# Permission is hereby granted, free of charge, to any person
# obtaining a copy of this software and associated documentation
# files (the "Software"), to deal in the Software without
# restriction, including without limitation the rights to use,
# copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the
# Software is furnished to do so, subject to the following
# conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
# OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
# HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
# WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
# OTHER DEALINGS IN THE SOFTWARE.

printHelp() {
    echo "vboxsvc, an SMF method for VirtualBox: (C) 2010-2011 by Jim Klimov,"
    echo "	$Id: vbox.sh,v 1.49 2011/11/23 13:53:06 jim Exp $"
    echo "	see http://vboxsvc.sourceforge.net/ for possible updates"
    echo "	building upon work (C) 2009 by Alexandre Dumont"
    echo "This method script supports SMF methods: { start | stop }"
    echo "Requires set SMF_FMRI environment variable which points to a VM instance."
    echo "VMs may be owned and run by unprivileged users, in local or global zones."
    echo ""
    echo "The KICKER loop to watch VM state re-reads variables each cycle, so"
    echo "'svccfg -s VM_NAME ... ; svcadm refresh VM_NAME' works dynamically."
    echo ""
    echo "Possible command-line options to specify VM_NAME (ultimately SMF_FMRI):"
    echo "	-s|-svc SVC_URL	SMF service name, possibly an SMF shortcut name"
    echo "	-vm VM_NAME    	'VM_NAME', as the SMF instance name (suffix after colon)"
    echo ""
    echo "This script also supports following command-line mode methods:"
    echo ""
    echo "	getstate|state|status	Prints states of SMF service (and spawned"
    echo "				processes if any - VMs may be parented by"
    echo "				VBoxSVC outside ot service's scope) and"
    echo "				state of VM (according to VirtualBox)"
    echo "		returns 0	VM running/starting/restoring"
    echo "			1	VM paused"
    echo "			2	VM saving"
    echo "			3	VM saved"
    echo "			10	VM powered off (halted)"
    echo "			20	VM aborted (VBox process died badly)"
    echo "			125	VM state string is empty (VBox bug)"
    echo "			126	VM state unknown by script"
    echo ""
    echo "	startgui (req: DISPLAY)	Saves VM state if needed, (re)starts with GUI"
    echo ""
    echo "	reboot [ifruns]		(Conditionally) Reboots the VM by trying"
    echo "				acpipowerbutton -> poweroff -> reset -> start"
    echo "				Probably disrupts GUI due to VM process exit."
    echo "	reset			Resets the VM OS by trying reset action."
    echo "		NOTE that for VBox 3.0.12 sometimes the reset'ed Windows guest"
    echo "		VM's hang on boot while poweroff-poweron'ed ones start ok"
    echo ""

}

#############################################################################
### Small helper routines
echodot() {
    /bin/echo ".\c"
}

echo_noret() {
    ### Echoes "$@" without carriage return/linefeed if possible...
    /bin/echo "$@\c"
}

sleeper() {
    ### Simple routine for breakable sleep (i.e. for background processes)
    MAX="$1"
    [ -z "$MAX" -o "$MAX" -le 0 ] && MAX=1

    COUNT=0
    while [ "$COUNT" -lt "$MAX" ]; do
        sleep 1
        COUNT="`expr $COUNT + 1`"
    done               
}
#############################################################################

while [ $# -gt 1 ]; do
    ### NOTE: We leave last param for normal processing below
    case "$1" in
	help|--help|-help|-h|'-?'|'/?')
	    printHelp
	    ;;
	-s|-svc) [ -z "$SMF_FMRI" ] && SMF_FMRI="$2"
	    shift 1 ;;
	-vm) [ -z "$SMF_FMRI" ] && SMF_FMRI="svc:/site/xvm/vbox:$2"
	    shift 1 ;;
	reboot) ### This presumably begins other script parameters
		### parsed below, now break this cycle
	    break ;;
	*)  echo "WARN: Unrecognized command-line parameter: '$1'" ;;
    esac
    shift 1
done

### Failure to include this is fatal, by design - no SMF installed
if [ ! -f /lib/svc/share/smf_include.sh -o \
     ! -r /lib/svc/share/smf_include.sh -o \
     ! -s /lib/svc/share/smf_include.sh ]; then
    echo "ERROR: SMF not installed? Can't use file /lib/svc/share/smf_include.sh" >&2
    exit 95
fi
. /lib/svc/share/smf_include.sh

if [ $# -lt 1 ]; then
    echo "ERROR on command-line: no params left to work with!" >&2
    printHelp
    exit $SMF_EXIT_ERR
fi

### SMF_FMRI is the name of the target service. This allows multiple instances
### to use the same script.

if [ -z "$SMF_FMRI" ]; then
    case "$1" in
        help|--help|-help|-h|'-?'|'/?')
            printHelp
            echo "NOTE: SMF framework variables are not initialized. Valid SMF_FMRI value is required, i.e.:"
	    svcs -a | grep 'svc:/site/xvm/vbox'
            exit 0
	    ;;
        *)
            echo "ERROR: SMF framework variables are not initialized." >&2
	    exit $SMF_EXIT_ERR
	    ;;
    esac
fi

### Sanity check for accepted external variables
OUT="`svcs -H $SMF_FMRI`"
RES=$?

if [ "$RES" != 0 -o `echo "$OUT" | wc -l` != 1 ]; then
    echo "ERROR: Provided SMF_FMRI value does not point to one SMF service name" >&2
    echo "	SMF_FMRI = '$SMF_FMRI'" >&2
    echo "	svcs check: result = '$RES', output =" >&2
    echo "===" >&2
    echo "$OUT" >&2
    echo "===" >&2
    echo "ERROR: SMF framework variables are not initialized properly." >&2
    exit $SMF_EXIT_ERR
fi

_SMF_FMRI="`echo "$OUT" | awk '{print $NF}'`"
if [ x"$_SMF_FMRI" != x"$SMF_FMRI" ]; then
    echo "INFO: Replacing SMF_FMRI value from '$SMF_FMRI' to '$_SMF_FMRI'"
    SMF_FMRI="$_SMF_FMRI"
fi
unset _SMF_FMRI

SMF_BASE="`echo "$SMF_FMRI" | sed 's/^\(.*\:.*\)\(\:.*\)$/\1/'`"
INSTANCE="$( echo $SMF_FMRI | cut -d: -f3 )"

### If current user differs from 'method_context/user', try using 'su'
### Processed below. Use-case: root checking non-root's VM status.
RUNAS=""

getUID() {
    ### Returns the numerical UID of current user or of username in $1 if any
    ### OpenSolaris boasts a more functional "id" than Soalris 10 (u6 - u8)
    NUM_UID="`id -u $1 2>/dev/null`" || NUM_UID="`id $1 | sed 's/uid=\([^(]*\)(\([^)]*\).*$/\1/'`"
    RET=$?

    echo "$NUM_UID"
    return $RET
}

GETPROPARG_QUIET=false
GETPROPARG_INHERIT=true
getproparg() {
    if [ x"$GETPROPARG_QUIET" = x"true" ]; then
        val="`$RUNAS svcprop -p "$1" "$SMF_FMRI" 2>/dev/null`"
    else
        val="`$RUNAS svcprop -p "$1" "$SMF_FMRI"`"
    fi

    [ -n "$val" ] && echo "$val" && return

    if [ x"$GETPROPARG_INHERIT" = xfalse ]; then
	false
	return
    fi

    ### Value not defined/set for instance
    ### Fetch one set for SMF service defaults
    if [ x"$GETPROPARG_QUIET" = x"true" ]; then
        val="`$RUNAS svcprop -p "$1" "$SMF_BASE" 2>/dev/null`"
    else
        val="`$RUNAS svcprop -p "$1" "$SMF_BASE"`"
    fi

    if [ -n "$val" ]; then
        [ x"$GETPROPARG_QUIET" != x"true" ] && \
	    echo "INFO: Using service-general default attribute '$1' = '$val'" >&2
        echo "$val"
        return
    fi
    false
}

get_nicerun() {
    ### Gets the NICE value and provides a variable to call
    ### "/bin/nice" with needed params
    NICE="$( getproparg vm/nice )"
    NICERUN=""

    if [ x"$NICE" != x ]; then
        if [ "$NICE" -le 0 -o "$NICE" -ge 0 ]; then
            ### Is a number
            NICERUN="/bin/nice -n $NICE"
        else
            echo "WARN: invalid 'vm/nice' = '$NICE', ignored." >&2
        fi
    else
        echo "WARN: 'vm/nice' not set, using OS defaults." >&2
    fi

    echo "$NICERUN"
}

get_tz_vm() {
    TZ_VM="$( getproparg vm/timezone )"

    [ x"$TZ_VM" = x ] && return

    if [ x"$TZ" != x"$TZ_VM" ]; then
	echo "INFO: Replacing VM time zone from current '$TZ' to '$TZ_VM'" >&2
	echo "TZ='$TZ_VM'"
    fi
}

resume_vm() {
    # For paused VM's
    NICERUN="`get_nicerun`"
    echo "INFO: NICERUN='$NICERUN'" >&2

    ( TZVM="`get_tz_vm`"    
      [ x"$TZVM" != x ] && export $TZVM
      $RUNAS $NICERUN /usr/bin/VBoxManage controlvm "$1" resume
    )
}

start_vm() {
    NICE="$( GETPROPARG_QUIET=true getproparg vm/nice )"
    NICERUN="`get_nicerun`"

    ( TZVM="`get_tz_vm`"    
      [ x"$TZVM" != x ] && export $TZVM

      if [ x"$NICERUN" = x -o x"$NICE" = x -o x"$NICE" = x0 ]; then
        echo "INFO: Normal RUN:	VBoxManage..." >&2
        $RUNAS /usr/bin/VBoxManage startvm "$1" --type vrdp
      else
        echo "INFO: NICERUN:	$NICERUN VBoxHeadless..." >&2
	$RUNAS $NICERUN /usr/bin/VBoxHeadless -startvm "$1" --vrdp config &
      fi
    )
}

stop_vm() {
    # STOP_METHOD=acpipowerbutton|savestate|acpisleepbutton|poweroff
    if [ x"$FORCE_STOP_METHOD" != x ]; then
	STOP_METHOD="$FORCE_STOP_METHOD"
    else
        STOP_METHOD="$( getproparg vm/stop_method )"
    fi

    case "$STOP_METHOD" in
        acpipowerbutton|savestate|acpisleepbutton|poweroff|reset)
            ;;
        *)
            STOP_METHOD="savestate"
            ;;
    esac

    ( TZVM="`get_tz_vm`"    
      [ x"$TZVM" != x ] && export $TZVM
      $RUNAS /usr/bin/VBoxManage controlvm "$1" "$STOP_METHOD"
    )
    RES=$?

    ### Savestate action exits when the state is saved.
    ### "Button press" emulations exit after pressing the button.
    ### We want to sleep until the VM stops.
    [ x"$RES" = x0 ] && case "$STOP_METHOD" in
	savestate)
	    STOP_TIMEOUT="`( getproparg vm/stop_timeout )`" || STOP_TIMEOUT="-1"
	    [ x"$STOP_TIMEOUT" = x ] && STOP_TIMEOUT="-1"
	    [ "$STOP_TIMEOUT" -le 0 ] && \
		echo "INFO: Method script will not enforce a stop timeout. SMF may..." || \
		echo "INFO: Method script will enforce a stop timeout of $STOP_TIMEOUT, SMF may have another opinion..."
	    STOP_COUNT=0

	    VM_STATE="$( vm_state $1 )"
	    while [ "x$VM_STATE" != xsaved ]; do
		sleep 1
		echodot

		VM_STATE="$( vm_state $1 )"
		case "x$VM_STATE" in
	    	    xaborted|xpoweroff)
			echo "ERROR: VM '$1' died during savestate!" >&2
		        VM_STATE="saved"
			RES=126
			;;
		esac

		STOP_COUNT="$(($STOP_COUNT+1))" || STOP_COUNT=0
		if [ "$STOP_TIMEOUT" -gt 0 -a "$STOP_COUNT" -gt "$STOP_TIMEOUT" ] ; then
		    echo "ERROR: VM '$1' stop timer expired ($STOP_COUNT > $STOP_TIMEOUT)" >&2
		    VM_STATE="saved"
		    RES=125
		fi
	    done
	    ;;
        poweroff|acpipowerbutton)
	    STOP_TIMEOUT="`( getproparg vm/stop_timeout )`" || STOP_TIMEOUT="-1"
	    [ x"$STOP_TIMEOUT" = x ] && STOP_TIMEOUT="-1"
	    [ "$STOP_TIMEOUT" -le 0 ] && \
		echo "INFO: Method script will not enforce a stop timeout. SMF may..." || \
		echo "INFO: Method script will enforce a stop timeout of $STOP_TIMEOUT, SMF may have another opinion..."
	    STOP_COUNT=0

	    VM_STATE="$( vm_state $1 )"
	    while [ "x$VM_STATE" != xpoweroff ]; do
		sleep 1
		echodot

		VM_STATE="$( vm_state $1 )"
		case "x$VM_STATE" in
	    	    xaborted|xsaved)
			echo "ERROR: VM '$1' died during poweroff!" >&2
		        VM_STATE="poweroff"
			RES=126
			;;
		esac

		STOP_COUNT="$(($STOP_COUNT+1))" || STOP_COUNT=0
		if [ "$STOP_TIMEOUT" -gt 0 -a "$STOP_COUNT" -gt "$STOP_TIMEOUT" ] ; then
		    echo "ERROR: VM '$1' stop timer expired ($STOP_COUNT > $STOP_TIMEOUT)" >&2
		    VM_STATE="poweroff"
		    RES=125
		fi
	    done
	    ;;
	acpisleepbutton) ;;
	reset) ;;
    esac

    # Occasionally a restart attempt fails because "a session is still open"
    # Unscientific WORKAROUND: sleep a little for other VBox processes
    # to "release" the VM
    echo "INFO: sync and nap..."
    sync; sleep 3

    echo "INFO: VM '$1' state is now: '$( vm_state $1 )'"

    return $RES
}

reboot_vm() {
    ### reboot VM "$1" via (acpipoweroff-poweroff-reset-poweron)
    ### can use "$2" == "ifruns" to poweron the VM only if it was running

    VM_STATE="$( vm_state $1 )"
    INITIAL_VM_STATE="$VM_STATE"

    case "x$INITIAL_VM_STATE" in
    xrunning|xstarting|xrestoring|xpaused)
	echo "INFO: `date`: Beginning to reboot VM '$1' (currently '$INITIAL_VM_STATE')..."
	echo "INFO: If 'vm/stop_timeout' is not set, this process will hang indefinitely!"

	echo "INFO: `date`: Trying acpipowerbutton..."
        FORCE_STOP_METHOD=acpipowerbutton stop_vm "$1"
	RES=$?

	if [ $RES != 0 ]; then
	    echo "INFO: `date`: That failed ($RES)"
	    echo "INFO: `date`: Trying poweroff..."
	    FORCE_STOP_METHOD=poweroff stop_vm "$1"
	    RES=$?

	    if [ $RES != 0 ]; then
                echo "INFO: `date`: That failed ($RES)"
	        echo "INFO: `date`: Trying reset..."
    		FORCE_STOP_METHOD=reset stop_vm "$1"
		RES=$?
	    fi
	fi
	echo "INFO: `date`: Done stopping (result=$RES)"
	sleeper 5
	;;
    esac

    RET=-1
    if [ x"$2" = x"ifruns" ]; then
	case "x$INITIAL_VM_STATE" in
	xrunning|xstarting|xrestoring|xpaused)
	    echo "INFO: `date`: Starting VM '$1' because it was '$INITIAL_VM_STATE'..."
	    start_vm "$1"
	    RET=$?
	    ;;
	x*) echo "INFO: `date`: VM '$1' was not running ($INITIAL_VM_STATE), not starting!" ;;
	esac
    else
	echo "INFO: `date`: Starting VM '$1'..."
	start_vm "$1"
	RET=$?
    fi
    echo "INFO: `date`: Done starting (result=$RET)"

    return $RET
}

vm_state() {
    $RUNAS /usr/bin/VBoxManage showvminfo "$1" --details --machinereadable | \
        grep VMState\= | tr -s '"' ' ' | cut -d " " -f2

    if [ $? -ne 0 ]; then
        echo >&2 "ERROR: Failed to get VMState for VM $1"
        exit $SMF_EXIT_ERR_FATAL
    fi
}

ABORT_COUNTER=""
addAbortedCounter() {
    RESTART_ABORTED_VM_FAILURES_MAXCOUNT="$( getproparg vm/restart_aborted_vm_failures_maxcount )" || \
	RESTART_ABORTED_VM_FAILURES_MAXCOUNT=""
    RESTART_ABORTED_VM_FAILURES_TIMEFRAME="$( getproparg vm/restart_aborted_vm_failures_timeframe )" || \
	RESTART_ABORTED_VM_FAILURES_TIMEFRAME=""

    if [ x"$RESTART_ABORTED_VM_FAILURES_MAXCOUNT" != x -a \
	x"$RESTART_ABORTED_VM_FAILURES_TIMEFRAME" != x -a \
	"$RESTART_ABORTED_VM_FAILURES_MAXCOUNT" -gt 0 -a \
	"$RESTART_ABORTED_VM_FAILURES_TIMEFRAME" -gt 0 \
    ]; then
	if [ x"$GDATE" != x -a \
	    -x "$GDATE" \
	]; then
	    TS_NOW="`TZ=UTC $GDATE +%s`" || TS_NOW=0
	else
	    echo "KICKER-INFO: `LANG=C TZ=UTC date`: aborted VM detected (state=$VM_STATE), but gdate is not available. Total abortion count over eternity will be used"
	    TS_NOW=0
	fi
	TS_CUTOFF="$(($TS_NOW-$RESTART_ABORTED_VM_FAILURES_TIMEFRAME))"

	### Chop off old entries, add the new one
	ABORT_COUNTER="$( for TS in $ABORT_COUNTER; do [ "$TS" -ge "$TS_CUTOFF" ] && echo "$TS"; done; echo "$TS_NOW" )"
	NUM="`echo "$ABORT_COUNTER" | wc -l`"
	if [ "$NUM" -gt "$RESTART_ABORTED_VM_FAILURES_MAXCOUNT" ]; then
            echo "KICKER-ERROR: `LANG=C TZ=UTC date`: VM $INSTANCE got into state $VM_STATE, too many times (num = $NUM, max = $RESTART_ABORTED_VM_FAILURES_MAXCOUNT) over the past $RESTART_ABORTED_VM_FAILURES_TIMEFRAME seconds. Requesting maintenance mode! Last abortion counts:"
	    echo "---"
	    echo "$ABORT_COUNTER"
	    echo "---"
	    echo "$TS_NOW  == now"
	    echo "---"
	    return 1
	fi
	if [ "$NUM" -gt "1" ]; then
            echo "KICKER-INFO: `LANG=C TZ=UTC date`: VM $INSTANCE got into state $VM_STATE $NUM times (max = $RESTART_ABORTED_VM_FAILURES_MAXCOUNT) over the past $RESTART_ABORTED_VM_FAILURES_TIMEFRAME seconds..."
	fi
    else
	echo "KICKER-INFO: `LANG=C TZ=UTC date`: aborted VM detected (state=$VM_STATE), but counter-over-timeframe is not configured or gdate is not available. Skipping abort-count checks."
    fi
    return 0
}

VMSVCCHECK_COUNTER=""
addVMSvcCheckCounter() {
    KICKER_VMSVCCHECK_FAILURES_MAXCOUNT="$( getproparg vm/kicker_vmsvccheck_failures_maxcount )" || \
	KICKER_VMSVCCHECK_FAILURES_MAXCOUNT=""
    KICKER_VMSVCCHECK_FAILURES_TIMEFRAME="$( getproparg vm/kicker_vmsvccheck_failures_timeframe )" || \
	KICKER_VMSVCCHECK_FAILURES_TIMEFRAME=""

    if [ x"$KICKER_VMSVCCHECK_FAILURES_MAXCOUNT" != x -a \
	x"$KICKER_VMSVCCHECK_FAILURES_TIMEFRAME" != x -a \
	"$KICKER_VMSVCCHECK_FAILURES_MAXCOUNT" -gt 0 -a \
	"$KICKER_VMSVCCHECK_FAILURES_TIMEFRAME" -gt 0 \
    ]; then
	if [ x"$GDATE" != x -a \
	    -x "$GDATE" \
	]; then
	    TS_NOW="`TZ=UTC $GDATE +%s`" || TS_NOW=0
	else
	    echo "KICKER-INFO: `LANG=C TZ=UTC date`: VM $INSTANCE service check method reported errors, but gdate is not available. Total failure count over eternity will be used"
	    TS_NOW=0
	fi
	TS_CUTOFF="$(($TS_NOW-$KICKER_VMSVCCHECK_FAILURES_TIMEFRAME))"

	### Chop off old entries, add the new one
	VMSVCCHECK_COUNTER="$( for TS in $VMSVCCHECK_COUNTER; do [ "$TS" -ge "$TS_CUTOFF" ] && echo "$TS"; done; echo "$TS_NOW" )"
	NUM="`echo "$VMSVCCHECK_COUNTER" | wc -l`"
	if [ "$NUM" -gt "$KICKER_VMSVCCHECK_FAILURES_MAXCOUNT" ]; then
            echo "KICKER-ERROR: `LANG=C TZ=UTC date`: VM $INSTANCE service check method reported errors too many times (num = $NUM, max = $KICKER_VMSVCCHECK_FAILURES_MAXCOUNT) over the past $KICKER_VMSVCCHECK_FAILURES_TIMEFRAME seconds. Requesting maintenance mode! Last failure counts:"
	    echo "---"
	    echo "$VMSVCCHECK_COUNTER"
	    echo "---"
	    echo "$TS_NOW  == now"
	    echo "---"
	    return 1
	fi
	if [ "$NUM" -gt "1" ]; then
            echo "KICKER-INFO: `LANG=C TZ=UTC date`: VM $INSTANCE service check method reported errors $NUM times (max = $KICKER_VMSVCCHECK_FAILURES_MAXCOUNT) over the past $KICKER_VMSVCCHECK_FAILURES_TIMEFRAME seconds..."
	fi
    else
	echo "KICKER-INFO: `LANG=C TZ=UTC date`: VM $INSTANCE service check method reported errors, but counter-over-timeframe is not configured or gdate is not available. Skipping failure-count checks."
    fi
    return 0
}

GOT_PAUSED=0
kick() {
    ### What happens if VM stops but not because of SMF controls?
    ### This continuously running routine should define what happens!

    ### Mirrors start() logic, but with a twist
    ### on continuously monitoring the VM state

    ### Check service state in order to quickly abort on failure/shutdown
    SVC_STATE=$( svcs -H -o state $SMF_FMRI )

    case x"$SVC_STATE" in
        xonline|'xoffline*')
            ;;
        x*) ### For other states - abort kicker
            echo "KICKER-INFO: `LANG=C TZ=UTC date`: service $SMF_FMRI is '$SVC_STATE', breaking the kicker loop" >&2
            return 1
            ;;
    esac

    ### Log progress...
    KICKER_DEBUG="$( GETPROPARG_QUIET=true getproparg vm/kicker_debug )" || KICKER_DEBUG=""

    ### Anti-self-DoS delay each cycle.
    ### NOTE this also affects "svcadm disable/restart" times
    ### because all of the service's processes must exit before
    ### it's complete. (hangs in 'online*' state until then)
    ### We have a PID file and a killer to remedy that in most cases.
    KICKER_FREQ="$( GETPROPARG_QUIET=true getproparg vm/kicker_freq )" || KICKER_FREQ="60"

    if [ x"$KICKER_NOSLEEP" != xtrue ]; then
	### TODO: Perhaps keep track of OS time to account for however long
	### it took to complete a previous KICKER loop (i.e. monitoring hook
	### execution time might ge deductible)?
        [ x"$KICKER_DEBUG" = xtrue ] && echo "KICKER-INFO: Sleeping $KICKER_FREQ"
        sleeper "$KICKER_FREQ"
    fi

    ### Update state info
    SVC_STATE=$( svcs -H -o state $SMF_FMRI )
    NEW_SVC_STATE="$SVC_STATE"
    case x"$SVC_STATE" in
        xonline) ;;
        'xoffline*')
            ### 'offline*' = a start method is still at work; don't interfere
            echo "KICKER-INFO: `LANG=C TZ=UTC date`: service $SMF_FMRI is '$SVC_STATE', skipping this cycle" >&2
            return 0;;
        x*) ### For other states - abort kicker
    	    ### 'online*' = a stop method is at work; don't interfere
            echo "KICKER-INFO: `LANG=C TZ=UTC date`: service $SMF_FMRI is '$SVC_STATE', breaking the kicker loop" >&2
            return 1
            ;;
    esac

    KICKER_NOKICK_FILE_NAME="$( GETPROPARG_QUIET=true getproparg vm/kicker_nokick_file_name)" || \
	KICKER_NOKICK_FILE_NAME=""
    [    x"$KICKER_NOKICK_FILE_NAME" = x'""' \
      -o x"$KICKER_NOKICK_FILE_NAME" = x"''" \
      -o x"$KICKER_NOKICK_FILE_NAME" = x \
    ] && KICKER_NOKICK_FILE_NAME="$KICKER_PIDFILE_NAME.nokick"

    [ -f "$KICKER_NOKICK_FILE_NAME" ] && \
	echo "KICKER-INFO: located '$KICKER_NOKICK_FILE_NAME', skipping cycle" && \
	return 0

    ### Virtual Machine's state according to VirtualBox
    VM_STATE="$( vm_state $INSTANCE )"

    ### Some flags control our reaction to failed VMs
    ### VMs which are not "running" may have been
    ### halted/saved/paused by user intentionally.
    ### We re-read these flags every cycle (if users
    ### don't forget "svcadm refresh VM_NAME"), so
    ### the user can set them to "false" before acting on
    ### his VM manually, otherwise it might go back up
    ### (if "true") - which may be unexpected.

    ### We have an overriding option, use it if set...
    KICKER_RESTART="$( GETPROPARG_QUIET=true getproparg vm/kicker_restart )" || \
	KICKER_RESTART=""
    case x"$KICKER_RESTART" in
        x[Nn][Oo][Nn][Ee]|x[Nn][Oo]|x[Oo][Ff][Ff]|x[Ff][Aa][Ll][Ss][Ee])
	    RESTART_ABORTED_VM=false
	    RESTART_PAUSED_VM=false
	    RESTART_HALTED_VM=false
	    RESTART_SAVED_VM=false
	    IGNORE_PAUSED_VM=true
	    ;;
        x[Aa][Ll][Ll]|x[Oo][Nn]|x[Tt][Rr][Uu][Ee])
	    RESTART_ABORTED_VM=true
	    RESTART_PAUSED_VM=true
	    RESTART_HALTED_VM=true
	    RESTART_SAVED_VM=true
	    IGNORE_PAUSED_VM=true
	    ;;
        *)
	    ### By default of the script all restarters are false
	    ### NOTE: may be different in XML manifest of the SMF service
            RESTART_ABORTED_VM="$( GETPROPARG_INHERIT=false getproparg vm/restart_aborted_vm )" || \
	    RESTART_ABORTED_VM="$( GETPROPARG_INHERIT=false getproparg vm/start_aborted_vm )" || \
            RESTART_ABORTED_VM="$( getproparg vm/restart_aborted_vm )" || \
	    RESTART_ABORTED_VM="$( getproparg vm/start_aborted_vm )" || \
	    RESTART_ABORTED_VM=false

            RESTART_PAUSED_VM="$( getproparg vm/restart_paused_vm )" || \
	    RESTART_PAUSED_VM="$( getproparg vm/start_paused_vm )" || \
	    RESTART_PAUSED_VM=false

            RESTART_HALTED_VM="$( getproparg vm/restart_halted_vm )" || \
	    RESTART_HALTED_VM=false

            RESTART_SAVED_VM="$( getproparg vm/restart_saved_vm )" || \
	    RESTART_SAVED_VM=false

	    IGNORE_PAUSED_VM="$( getproparg vm/ignore_paused_vm )" || \
	    IGNORE_PAUSED_VM=true
	    ;;
    esac

    ### Anti-spam counter, see below
    [ "x$VM_STATE" != "xpaused" ] && GOT_PAUSED=0

    ### Counter for 'unknown' VM states to cause offline/maintenance
    ### (if max >= 0). If state is known, counter is kept at zero.
    UNKNOWN_STATE_COUNTER_PRV="$UNKNOWN_STATE_COUNTER"
    UNKNOWN_STATE_COUNTER=0

    case "x$VM_STATE" in
    xrunning|xstarting|xrestoring)
        [ x"$KICKER_DEBUG" = xtrue ] && \
	    echo "KICKER-INFO: `LANG=C TZ=UTC date`: VM $INSTANCE is already in state $VM_STATE."
        NEW_SVC_STATE="online"

        KICKER_VMSVCCHECK_ENABLED="$( getproparg vm/kicker_vmsvccheck_enabled)" || \
	    KICKER_VMSVCCHECK_ENABLED="false"
        if [ x"$KICKER_VMSVCCHECK_ENABLED" = xtrue -a "x$VM_STATE" = xrunning ]; then
	    KICKER_VMSVCCHECK_METHOD="$( getproparg vm/kicker_vmsvccheck_method)" || \
		KICKER_VMSVCCHECK_METHOD=""
	    if [ x"$KICKER_VMSVCCHECK_METHOD" != x -a -x "$KICKER_VMSVCCHECK_METHOD" ]; then
		KICKER_VMSVCCHECK_STARTDELAY="$( getproparg vm/kicker_vmsvccheck_startdelay)" || \
		    KICKER_VMSVCCHECK_STARTDELAY="300"

	        OK=yes
		if [ x"$GDATE" != x -a -x "$GDATE" ]; then
		    TS_NOW="`TZ=UTC $GDATE +%s`" || TS_NOW=0
		    if [  x"$TS_VM_STARTED" != x \
			-a "$TS_VM_STARTED" -gt 0 \
			-a "$TS_VM_STARTED" -le "$TS_NOW" \
		    ]; then
			if [ "$(($TS_NOW-$TS_VM_STARTED))" -lt "$KICKER_VMSVCCHECK_STARTDELAY" ]; then
			    [ x"$KICKER_DEBUG" = xtrue ] && \
				echo "KICKER-INFO: `LANG=C TZ=UTC date`: VM $INSTANCE service check hookis enabled, but delay time since VM start has not yet expired, skipping check"
			    OK=no
		        fi
		    fi
	        fi

	        if [ x"$OK" = xyes ]; then
		    KICKER_VMSVCCHECK_METHOD_PARAMS="$( getproparg vm/kicker_vmsvccheck_method_params)" || \
			KICKER_VMSVCCHECK_METHOD_PARAMS=""

		    "$KICKER_VMSVCCHECK_METHOD" $KICKER_VMSVCCHECK_METHOD_PARAMS
		    KICKER_VMSVCCHECK_RESULT=$?

		    ### TODO: Test more. This logic was implemented from theory
		    ### but not yet extensively checked in field practice

### Hook for an arbitrary method+params of checking that the VM provides
### its services (web, dbms, ping, etc). As far as vbox-svc is concerned,
### this external method is an executable program or script which should
### return an error code of:
###   0 for okay (clear counter),
###   1 for failure detected, increase counter, reboot VM on overflow
###   2 for instant reboot VM (acpipoweroff-poweroff-reset-poweron),
###   3 for instant cause SMF maintenance
### It is encouraged that the method uses some limitation of its execution
### time, as each loop cycle will have to wait for the check to complete.
### Note for COS&HT users: see /opt/COSas/bin/timerun.sh - COSas package
### Note: for reboots to work it is critical to set a vm/stop_timeout

		    case "$KICKER_VMSVCCHECK_RESULT" in
			0) ### OK
			    [ x"$VMSVCCHECK_COUNTER" != x ] && \
				echo "KICKER-INFO: resetting error counter (was $VMSVCCHECK_COUNTER)"
			    VMSVCCHECK_COUNTER=""
			    ;;
			1) ### Single error
			    echo "KICKER-INFO: increasing error counter (was ${VMSVCCHECK_COUNTER:-0})"
			    if ! addVMSvcCheckCounter; then
			        echo "KICKER-INFO: requesting VM reboot due to repeated service-check failures..."
				if reboot_vm "$INSTANCE"; then
				    echo "KICKER-INFO: resetting error counters and startup-delay check"
				    NEW_SVC_STATE=online
			    	    if [ x"$GDATE" != x -a -x "$GDATE" ]; then
			    	        TS_VM_STARTED="`TZ=UTC $GDATE +%s`" || TS_VM_STARTED=0
				    fi
			    	    VMSVCCHECK_COUNTER=""
			        else
				    NEW_SVC_STATE=maintenance
				fi
			    fi
			    ;;
		        2) ### Instant reboot
			    echo "KICKER-INFO: requesting VM reboot due to a fatal service-check failure..."
			    if reboot_vm "$INSTANCE"; then
			        echo "KICKER-INFO: resetting error counters and startup-delay check"
				NEW_SVC_STATE=online
			        VMSVCCHECK_COUNTER=""
			    else
			        NEW_SVC_STATE=maintenance
			    fi
			    if [ x"$GDATE" != x -a -x "$GDATE" ]; then
			        TS_VM_STARTED="`TZ=UTC $GDATE +%s`" || TS_VM_STARTED=0
			    fi
			    ;;
			3) ### cause SMF maintenance
			    echo "KICKER-INFO: requesting SMF maintenance due to critical service-check failures..."
			    NEW_SVC_STATE="maintenance"
			    ;;
			esac
	        fi
	    else
		[ x"$KICKER_DEBUG" = xtrue ] && echo "KICKER-INFO: `LANG=C TZ=UTC date`: VM $INSTANCE has KICKER_VMSVCCHECK_ENABLED but no valid method: '$KICKER_VMSVCCHECK_METHOD'"
	    fi
        fi
        ;;
    xaborted)
        if [ "x$RESTART_ABORTED_VM" = "xtrue" ]; then
	    if addAbortedCounter; then
        	echo "KICKER-INFO: `LANG=C TZ=UTC date`: VM $INSTANCE got into state $VM_STATE, trying to start..."
    		start_vm $INSTANCE && NEW_SVC_STATE=online || NEW_SVC_STATE=maintenance

		if [ x"$GDATE" != x -a -x "$GDATE" ]; then
		    TS_VM_STARTED="`TZ=UTC $GDATE +%s`" || TS_VM_STARTED=0
		fi
	    else
        	echo "KICKER-ERROR: `LANG=C TZ=UTC date`: VM $INSTANCE got into state $VM_STATE, too many times (max = $RESTART_ABORTED_VM_FAILURES_MAXCOUNT) over the past $RESTART_ABORTED_VM_FAILURES_TIMEFRAME seconds. Requesting maintenance mode!"
		NEW_SVC_STATE=maintenance
	    fi
        else
            echo "KICKER-ERROR: `LANG=C TZ=UTC date`: VM $INSTANCE got into state $VM_STATE, but I won't start it."
            echo "KICKER-INFO: to auto-start an aborted VM set its 'vm/restart_aborted_vm' SMF property to 'boolean: true'."
            NEW_SVC_STATE="maintenance"
        fi
        ;;
    xpaused)
        ### A VM can also be paused if it is saving to disk
        if [ "x$IGNORE_PAUSED_VM" != "xtrue" ]; then
            [ -f "$KICKER_NOKICK_FILE_NAME" ] && \
		echo "KICKER-INFO: located '$KICKER_NOKICK_FILE_NAME', skipping cycle" && \
		return 0

            if [ "x$RESTART_PAUSED_VM" = "xtrue" ]; then
        	echo "KICKER-INFO: `LANG=C TZ=UTC date`: VM $INSTANCE got into state $VM_STATE, trying to unpause..."
        	resume_vm $INSTANCE && NEW_SVC_STATE=online || NEW_SVC_STATE=maintenance

	        if [ x"$GDATE" != x -a -x "$GDATE" ]; then
	    	    TS_VM_STARTED="`TZ=UTC $GDATE +%s`" || TS_VM_STARTED=0
		fi
            else
        	echo "KICKER-ERROR: `LANG=C TZ=UTC date`: VM $INSTANCE got into state $VM_STATE, but I won't start it."
        	echo "KICKER-INFO: to auto-unpause a VM set its 'vm/restart_paused_vm' SMF property to 'boolean: true'."
        	NEW_SVC_STATE="offline"
            fi
        else
	    ### If we asked to ignore the paused state, we might not want SPAM in logs ;)
	    GOT_PAUSED="$(($GOT_PAUSED+1))" || GOT_PAUSED=0
            [ x"$KICKER_DEBUG" = xtrue -o x"$GOT_PAUSED" = x1 ] && echo "KICKER-INFO: `LANG=C TZ=UTC date`: VM $INSTANCE got into state $VM_STATE. Ignoring per SMF service configuration."
        fi
        ;;
    xpoweroff)
        if [ "x$RESTART_HALTED_VM" = "xtrue" ]; then
            echo "KICKER-INFO: `LANG=C TZ=UTC date`: VM $INSTANCE got into state $VM_STATE, trying to start..."
            start_vm $INSTANCE && NEW_SVC_STATE=online || NEW_SVC_STATE=maintenance

	    if [ x"$GDATE" != x -a -x "$GDATE" ]; then
		TS_VM_STARTED="`TZ=UTC $GDATE +%s`" || TS_VM_STARTED=0
	    fi
        else
            echo "KICKER-ERROR: `LANG=C TZ=UTC date`: VM $INSTANCE got into state $VM_STATE, but I won't start it."
            echo "KICKER-INFO: to auto-restart a halted VM set its 'vm/restart_halted_vm' SMF property to 'boolean: true'."
            NEW_SVC_STATE="offline"
        fi
        ;;
    xsaved)
        [ -f "$KICKER_NOKICK_FILE_NAME" ] && echo "KICKER-INFO: located '$KICKER_NOKICK_FILE_NAME', skipping cycle" && return 0
        RESTART_SAVED_VM_ONCE_FILE_NAME="$( getproparg vm/kicker_restart_saved_vm_once_file_name )" || \
        RESTART_SAVED_VM_ONCE_FILE_NAME=""

        [ x"$RESTART_SAVED_VM_ONCE_FILE_NAME" = x'""' -o \
          x"$RESTART_SAVED_VM_ONCE_FILE_NAME" = x"''" -o \
          x"$RESTART_SAVED_VM_ONCE_FILE_NAME" = x"true" ] && RESTART_SAVED_VM_ONCE_FILE_NAME=""
        [ x"$RESTART_SAVED_VM_ONCE_FILE_NAME" = x -a -w "/var/run" -a x"$RUNAS" = x ] && \
	    RESTART_SAVED_VM_ONCE_FILE_NAME="/var/run/.vboxsvc-kicker-$INSTANCE.restart_saved_once"
        [ x"$RESTART_SAVED_VM_ONCE_FILE_NAME" = x ] && \
	    RESTART_SAVED_VM_ONCE_FILE_NAME="/tmp/.vboxsvc-kicker-$INSTANCE.restart_saved_once"

        echo "RESTART_SAVED_VM_ONCE_FILE_NAME='$RESTART_SAVED_VM_ONCE_FILE_NAME'"
        if [ x"$RESTART_SAVED_VM_ONCE_FILE_NAME" != xfalse ]; then
    	    if [ -f "$RESTART_SAVED_VM_ONCE_FILE_NAME" ]; then
		echo "KICKER-INFO: Found a 'RESTART_SAVED_VM_ONCE_FILE_NAME'='$RESTART_SAVED_VM_ONCE_FILE_NAME' file,"
		echo "      enforcing a saved VM restart attempt this time."

		rm -f "$RESTART_SAVED_VM_ONCE_FILE_NAME"
		RESTART_SAVED_VM=true
	    fi
        fi

        if [ "x$RESTART_SAVED_VM" = "xtrue" ]; then
            echo "KICKER-INFO: `LANG=C TZ=UTC date`: VM $INSTANCE got in state $VM_STATE, trying to unpause..."
            start_vm $INSTANCE && NEW_SVC_STATE=online || NEW_SVC_STATE=maintenance

	    if [ x"$GDATE" != x -a -x "$GDATE" ]; then
		TS_VM_STARTED="`TZ=UTC $GDATE +%s`" || TS_VM_STARTED=0
	    fi
    	else
            echo "KICKER-ERROR: `LANG=C TZ=UTC date`: VM $INSTANCE got into state $VM_STATE, but I won't start it."
            echo "KICKER-INFO: to auto-unpause a saved VM set its 'vm/restart_saved_vm' SMF property to 'boolean: true'."
            NEW_SVC_STATE="offline"
        fi
        ;;
    xsaving)
        echo "KICKER-INFO: `LANG=C TZ=UTC date`: VM $INSTANCE is now in state $VM_STATE, I can't start it. Maybe next cycle?"
        return 0
        ;;
    "")
        echo "KICKER-INFO: `LANG=C TZ=UTC date`: VM $INSTANCE is in bogus state (empty string),  I can't start it now. Has the host just booted?.. Hopefully next KICKER cycles would succeed."
        return 0
        ;;
    *)
        UNKNOWN_STATE_COUNTER="$(($UNKNOWN_STATE_COUNTER_PRV+1))" || UNKNOWN_STATE_COUNTER=1
        UNKNOWN_STATE_COUNTER_MAX="`getproparg vm/offline_unknown_state_maxcount`" || UNKNOWN_STATE_COUNTER_MAX=0
        if [ "$UNKNOWN_STATE_COUNTER_MAX" -ge 0 ]; then
	    echo "KICKER-ERROR: `LANG=C TZ=UTC date`: VM $INSTANCE is now in unknown state $VM_STATE, I can't start it."
	    if [ "$UNKNOWN_STATE_COUNTER" -gt "$UNKNOWN_STATE_COUNTER_MAX" ]; then
        	echo "KICKER-ERROR: offlining SMF service (counter $UNKNOWN_STATE_COUNTER > max $UNKNOWN_STATE_COUNTER_MAX)."
        	NEW_SVC_STATE="offline"
	    fi
        else
	    if [ x"$UNKNOWN_STATE_PRV" != x"$VM_STATE" ]; then
		UNKNOWN_STATE_COUNTER=1
	    fi
	    UNKNOWN_STATE_PRV="$VM_STATE"

	    if [ "$UNKNOWN_STATE_COUNTER" = 1 ]; then
		echo "KICKER-INFO: `LANG=C TZ=UTC date`: VM $INSTANCE is now in unknown state $VM_STATE, I can't start it. Offlining SMF service is disabled. Reporting only once."
	    fi
        fi
        ;;
    esac

    if [ "$UNKNOWN_STATE_COUNTER" = 0 ]; then
        UNKNOWN_STATE_PRV=""
    fi

    if [ x"$NEW_SVC_STATE" != x"$SVC_STATE" ]; then
        if [ x"$NEW_SVC_STATE" = xoffline -a \
	     x"$( GETPROPARG_QUIET=true getproparg vm/offline_is_maint )" = xtrue \
	]; then
            echo "KICKER-INFO: `LANG=C TZ=UTC date`: configured to cause MAINTENANCE instead of OFFLINE."
	    NEW_SVC_STATE="maintenance"
        fi

### NOTE: an unprivileged user may not have the rights to use svcadm
### In this case the simple loop-break would cause maintenance and
### restart by SMF. We'll protect against that with a lock file to
### cause many repetitive restart failures (3 by default) and SMF
### maintenance mode will kick in as we want.
### See docs for proper privilege delegation via RBAC profiles, i.e.
### http://hub.opensolaris.org/bin/view/Community+Group+smf/faq  chapter 2.1

        echo "KICKER-INFO: `LANG=C TZ=UTC date`: requesting SMF '$NEW_SVC_STATE' state (was '$SVC_STATE')."

	### By arbitrarily chosen default, we remain in current SMF status
	### (which is probably online). Maybe the VM will come back by user
	### activity in VirtualBox GUI or command-line interface?
        SVCADM_RET=-1
        SVCADM_OUT=""

        if [ x"$NEW_SVC_STATE" = xonline ]; then
	    ### Not sure if we'll really ever get to this point
    	    SVCADM_OUT="`LANG=C svcadm clear "$SMF_FMRI" 2>&1; LANG=C svcadm enable -t "$SMF_FMRI" 2>&1`"
    	    SVCADM_RET=$?
        fi

        if [ x"$NEW_SVC_STATE" = xmaintenance ]; then
    	    SVCADM_OUT="`LANG=C svcadm mark -tI maintenance "$SMF_FMRI" 2>&1`"
    	    SVCADM_RET=$?
        fi

        if [ x"$NEW_SVC_STATE" = xoffline ]; then
	    ### The VM was shut down and our flags specify that
	    ### it should not be restarted. 
    	    SVCADM_OUT="`LANG=C svcadm disable -t "$SMF_FMRI" 2>&1`"
    	    SVCADM_RET=$?
        fi

        if [ x"$SVCADM_RET" = "x-1" ]; then
	    echo "INFO: svcadm not called. Strange..."
	    return 0
        fi

        if echo "$SVCADM_OUT" | grep "Permission denied" >/dev/null; then
	    ### Expecting failure for non-root users...
	    echo "INFO: execution user '`id`' is not allowed to manipulate his SMF service. See docs on SMF and RBAC delegation, i.e. http://hub.opensolaris.org/bin/view/Community+Group+smf/faq  chapter 2.1"
	    echo "INFO: trying to set KICKER blockfile. Enabled ?= '$KICKER_BLOCKFILE_ENABLED'"
	    setBlockFile
	    [ x"$SVCADM_RET" = x0 ] && SVCADM_RET=-2
        else
            if [ x"$SVCADM_RET" != x0 ]; then
    		### Whatever the reason, we wanted maintenance anyway...
    		if [ x"$NEW_SVC_STATE" = xmaintenance -o \
    		     x"$NEW_SVC_STATE" = xoffline \
		]; then
		    echo "INFO: failed SMF manipulation to disable service."
	    	    echo "INFO: trying to set KICKER blockfile. Enabled ?= '$KICKER_BLOCKFILE_ENABLED'"
    		    setBlockFile
    		fi
            fi
        fi

        if [ "$SVCADM_RET" -lt 0 ]; then
	    echo "INFO: internally detected svcadm error (return code $SVCADM_RET), output:"
        else
	    echo "INFO: svcadm return code ($SVCADM_RET), output:"
        fi
        echo "---"
        echo "$SVCADM_OUT"
        echo "---"
        return "$SVCADM_RET"
    fi

    return 0
}

start() {
    VM_STATE=$( vm_state $INSTANCE )
    START_ABORTED_VM="$( getproparg vm/start_aborted_vm )" || START_ABORTED_VM=false
    START_PAUSED_VM="$( getproparg vm/start_paused_vm )" || START_PAUSED_VM=false

    case "x$VM_STATE" in
    xrunning|xstarting|xrestoring)
        echo "INFO: `LANG=C TZ=UTC date`: VM $INSTANCE is already in state $VM_STATE."
        true
        ;;
    xaborted)
        if [ "x$START_ABORTED_VM" = "xtrue" ]; then
            echo "INFO: `LANG=C TZ=UTC date`: VM $INSTANCE was in state $VM_STATE, trying to start..."
            start_vm $INSTANCE
        else
            echo "ERROR: `LANG=C TZ=UTC date`: VM $INSTANCE is in state $VM_STATE, I can't start it."
            echo "INFO: to auto-start an aborted VM set its 'vm/start_aborted_vm' SMF property to 'boolean: true'."
            false
        fi
        ;;
    xpaused)
        if [ "x$START_PAUSED_VM" = "xtrue" ]; then
            echo "INFO: `LANG=C TZ=UTC date`: VM $INSTANCE was in state $VM_STATE, trying to unpause..."
            resume_vm $INSTANCE
        else
            echo "ERROR: `LANG=C TZ=UTC date`: VM $INSTANCE is in state $VM_STATE, I can't start it."
            echo "INFO: to auto-unpause an aborted VM set its 'vm/start_paused_vm' SMF property to 'boolean: true'."
            false
        fi
        ;;
    xpoweroff|xsaved)
        echo "INFO: `LANG=C TZ=UTC date`: VM $INSTANCE is in state $VM_STATE, trying to start..."
        start_vm $INSTANCE
        ;;
    "") echo "INFO: `LANG=C TZ=UTC date`: VM $INSTANCE is in bogus state (empty string),  I can't start it now. Has the host just booted?.. Hopefully next KICKER cycles would succeed."
        true
        ;;
    *)
        echo "ERROR: `LANG=C TZ=UTC date`: VM $INSTANCE is in state $VM_STATE, I can't start it."
        false
        ;;
    esac
}

stop() {
    VM_STATE="$( vm_state $INSTANCE )"

    case "x$VM_STATE" in
    xrunning|xstarting|xrestoring|xpaused)
        echo "INFO: `LANG=C TZ=UTC date`: VM $INSTANCE is in state $VM_STATE, trying to stop..."
        stop_vm $INSTANCE
        ;;
    *)
        echo "INFO: `LANG=C TZ=UTC date`: VM $INSTANCE is in state $VM_STATE, I won't stop it any further."
        ;;
    esac
}

stopOldKicker() {
    if [ -s "$KICKER_PIDFILE_NAME" ]; then
	OLDPIDS="`cat "$KICKER_PIDFILE_NAME"`"

	echo "INFO: `LANG=C TZ=UTC date`: Removing old KICKER PID-file '$KICKER_PIDFILE_NAME'..."
	rm -f "$KICKER_PIDFILE_NAME"
	if [ $? != 0 ]; then
	    echo "ERROR: KICKER PID-file removal failed. Requesting maintenance mode! More data:"
	    ls -lad "$KICKER_PIDFILE_NAME"
	    ls -ladV "$KICKER_PIDFILE_NAME"
	    exit $SMF_EXIT_ERR_FATAL
	fi

	### TODO: "kill: Permission denied" check. Maintenance?
	[ x"$OLDPIDS" != x ] && echo "INFO: Trying to kill old KICKER loop (may fail if process already dead, worse if no perms). PID(s): $OLDPIDS and descendants..."
        for P in $OLDPIDS; do
	    pkill -P "$P"
	    kill "$P"
        done

    fi
}

removeBlockFile() {
    if [ x"$KICKER_BLOCKFILE_ENABLED" = xtrue -a \
	 x"$KICKER_BLOCKFILE_NAME" != x -a \
	-f "$KICKER_BLOCKFILE_NAME" \
    ]; then
        rm -f "$KICKER_BLOCKFILE_NAME"
	if [ $? != 0 ]; then
	    echo "ERROR: `LANG=C TZ=UTC date`: bogus file removal failed. Requesting maintenance mode! More data:"
	    ls -lad "$KICKER_BLOCKFILE_NAME"
	    ls -ladV "$KICKER_BLOCKFILE_NAME"
	    exit $SMF_EXIT_ERR_FATAL
	fi
    fi
}

setBlockFile() {
    if [ x"$KICKER_BLOCKFILE_ENABLED" = xtrue -a \
         x"$KICKER_BLOCKFILE_NAME" != x \
    ]; then
	MY_ID="`getUID`"
	echo "INFO: `LANG=C TZ=UTC date`: creating KICKER block-file '$KICKER_BLOCKFILE_NAME' with tag '$MY_ID'..."

	[ -f "$KICKER_BLOCKFILE_NAME" ] && removeBlockFile
	[ -f "$KICKER_BLOCKFILE_NAME" ] && chown "$MY_ID" "$KICKER_BLOCKFILE_NAME"
	echo "$MY_ID" > "$KICKER_BLOCKFILE_NAME"
    fi
}

testBlockFile() {
    if [ x"$KICKER_BLOCKFILE_ENABLED" = xtrue -a \
	 x"$KICKER_BLOCKFILE_NAME" != x -a \
	-f "$KICKER_BLOCKFILE_NAME" \
    ]; then
	echo "INFO: KICKER block-file exists: '$KICKER_BLOCKFILE_NAME'."

	### Check if age doesn't exceed set maximum
	KICKER_BLOCKFILE_AGE="-1"
	if [ x"$GDATE" = x ]; then
	    echo "ERROR: 'gdate' not available. Can't check KICKER block-file age."
	    echo "ERROR: Triggering SMF failure mode by setting zero block-file age."
	    echo "ERROR: Remove block-file manually to enable VM service."
	    echo "INFO: Consider installing gdate for better accuracy."
	else
	    TS_NOW="`TZ=UTC $GDATE +%s`" || TS_NOW=1
	    TS_FILE="`TZ=UTC $GDATE -r "$KICKER_BLOCKFILE_NAME" +%s`" || TS_FILE=0
	    KICKER_BLOCKFILE_AGE="$(($TS_NOW-$TS_FILE))" || KICKER_BLOCKFILE_AGE="0"
	    [ "$KICKER_BLOCKFILE_AGE" -lt 0 ] && echo "INFO: block-file age is negative ($KICKER_BLOCKFILE_AGE). Clock skew?"
	fi

	### Check if owners match (should contain UIDnumber)
	MY_ID="`getUID`"
	FILE_ID="`head -1 "$KICKER_BLOCKFILE_NAME"`"
	FILE_OWNER="`ls -nl "$KICKER_BLOCKFILE_NAME" | awk '{print $3 }'`"

	if [ x"$MY_ID" = x"$FILE_ID" -a x"$MY_ID" = x"$FILE_OWNER" ]; then
	    if [ "$KICKER_BLOCKFILE_AGE" -le "$KICKER_BLOCKFILE_MAXAGE" ]; then
		### Update the file for next SMF check...
		touch "$KICKER_BLOCKFILE_NAME"

		echo "INFO: `LANG=C TZ=UTC date`: KICKER block-file is valid (age=$KICKER_BLOCKFILE_AGE, maxage=$KICKER_BLOCKFILE_MAXAGE, tag='$MY_ID'), pushing for maintenance mode. See logs above, maybe they will explain - why."
		exit $SMF_EXIT_ERR_FATAL
	    else
		echo "INFO: `LANG=C TZ=UTC date`: KICKER block-file expired, removing (age=$KICKER_BLOCKFILE_AGE, maxage=$KICKER_BLOCKFILE_MAXAGE)"
	        removeBlockFile
	    fi
	else
	    echo "ERROR: `LANG=C TZ=UTC date`: bogus block file. Checked data:"
	    echo "    MY_ID       = $MY_ID"
	    echo "    FILE_ID     = $FILE_ID"
	    echo "    FILE_OWNER  = $FILE_OWNER"

	    echo "INFO: attempting to remove bogus KICKER block file."
	    removeBlockFile
	fi
    fi
    echo ""
    return 0
}

run_as() {
    RUNAS_USER="$1"
    shift

    echo "INFO: Running in context of '$RUNAS_USER'..." >&2

    ### Running as another user via 'su' may cause echoing of shell greetings
    ### we don't want them in property values, etc. so redirect stderr/stdout
    #    su - "$RUNAS_USER" -c "$*"
    ( su - "$RUNAS_USER" -c " ($*) 2>&4 1>&3" ) 3>&1 4>&2 1>/dev/null 2>/dev/null
}

get_run_as() {
    RUN_USER="$( GETPROPARG_QUIET=false getproparg method_context/user )" || RUN_USER="root"
    [ x"$RUN_USER" = x ] && RUN_USER="root"

    CURR_USER_ID="`getUID`"
    if RUN_USER_ID="`getUID "$RUN_USER"`"; then
	### No error getting an ID
	if [ x"$CURR_USER_ID" != x"$RUN_USER_ID" ]; then
	    RUNAS="run_as $RUN_USER" && export RUNAS
	    echo "$RUN_USER_ID"
	fi
    else
	echo "ERROR: unknown user name from SMF property 'method_context/user'='$RUN_USER', skipping RUNAS and probably erring on VM state..." >&2
	echo "    Possible causes: invalid VM service set-up or ldap/nis/... user-catalog error" >&2
    fi
    echo "$CURR_USER_ID"
}

getState() {
    ### export SMF_FMRI='svc:/site/xvm/vbox:VM_NAME' in the caller

    RUN_USER="`get_run_as 2>/dev/null`"
    get_run_as >/dev/null
    VM_STATE=$( vm_state $INSTANCE )

    case "x$VM_STATE" in
    xrunning|xstarting|xrestoring)
	SVC_RET=0 ;;
    xpaused)
	SVC_RET=1 ;;
    xsaving)
	SVC_RET=2 ;;
    xsaved)
	SVC_RET=3 ;;
    xpoweroff)
	SVC_RET=10 ;;
    xaborted)
	SVC_RET=20 ;;
    "")
	# Bogus state, occasionally VBox 3.0.12 has no string to report
	# In GUI it maps to definite states, i.e. when VM snapshots are rolling
	SVC_RET=125;;
    *)
	SVC_RET=126;;
    esac

    echo "INFO: `LANG=C TZ=UTC date`: VM '$INSTANCE' is in state '$VM_STATE'."
    echo "INFO: Returning status: '$SVC_RET'"

    echo "INFO: SMF service status:"
    svcs -p "$SMF_FMRI"
    echo "   'svcs' RETCODE = '$?'"

    echo 'INFO: data from `ps` process listing:'
    ps -ef | grep -v grep | grep "comment $INSTANCE"

    return $SVC_RET
}

############################################################################
### Actual body of work

[ x"$DEBUG_SMF" = x ] && DEBUG_SMF="$( GETPROPARG_QUIET=true getproparg vm/debug_smf )"
[ $? != 0 ] && DEBUG_SMF=false
[ x"$DEBUG_SMF" = xtrue ] && echo "INFO: Enabling SMF script debug..." && set -x

GETPROPARG_QUIET=true get_run_as >/dev/null 2>/dev/null

### Check for transient/child/contract(default) mode...
#duration=""
#if /bin/svcprop -q -c -p startd/duration $SMF_FMRI 2>/dev/null ; then
#    duration="`/bin/svcprop -c -p startd/duration $SMF_FMRI`"
#fi

### Not all users may have write permissions to /var/run -
### so by default we use /tmp as it also clears on reboot
KICKER_PIDFILE_NAME="$( GETPROPARG_QUIET=true getproparg vm/kicker_pidfile_name)" || \
    KICKER_PIDFILE_NAME=""
[ x"$KICKER_PIDFILE_NAME" = x'""' -o x"$KICKER_PIDFILE_NAME" = x"''" ] && \
    KICKER_PIDFILE_NAME=""
[ x"$KICKER_PIDFILE_NAME" = x -a -w "/var/run" -a x"$RUNAS" = x ] && \
    KICKER_PIDFILE_NAME="/var/run/.vboxsvc-kicker-$INSTANCE.pid"
[ x"$KICKER_PIDFILE_NAME" = x ] && \
    KICKER_PIDFILE_NAME="/tmp/.vboxsvc-kicker-$INSTANCE.pid"

KICKER_BLOCKFILE_ENABLED="$( GETPROPARG_QUIET=true getproparg vm/kicker_blockfile_enabled)" || \
    KICKER_BLOCKFILE_ENABLED=""
KICKER_BLOCKFILE_NAME="$( GETPROPARG_QUIET=true getproparg vm/kicker_blockfile_name)" || \
    KICKER_BLOCKFILE_NAME=""
KICKER_BLOCKFILE_MAXAGE="$( GETPROPARG_QUIET=true getproparg vm/kicker_blockfile_maxage)" || \
    KICKER_BLOCKFILE_MAXAGE=""
[ x"$KICKER_BLOCKFILE_ENABLED" = x ] && KICKER_BLOCKFILE_ENABLED="true"
[ x"$KICKER_BLOCKFILE_NAME" = x'""' -o x"$KICKER_BLOCKFILE_NAME" = x"''" ] && \
    KICKER_BLOCKFILE_NAME=""
[ x"$KICKER_BLOCKFILE_NAME" = x -a -w "/var/run" -a x"$RUNAS" = x ] && \
    KICKER_BLOCKFILE_NAME="/var/run/.vboxsvc-kicker-$INSTANCE.block"
[ x"$KICKER_BLOCKFILE_NAME" = x ] && \
    KICKER_BLOCKFILE_NAME="/tmp/.vboxsvc-kicker-$INSTANCE.block"
[ x"$KICKER_BLOCKFILE_MAXAGE" = x ] && KICKER_BLOCKFILE_MAXAGE="60"

GDATE_LIST="/opt/COSac/bin/gdate /opt/sfw/bin/gdate /usr/local/bin/date /usr/local/bin/gdate /usr/sfw/bin/gdate /usr/bin/gdate"
GDATE=""

[ x"$GDATE" != x -a ! -x "$GDATE" ] && GDATE=""
[ x"$GDATE" = x ] && for F in $GDATE_LIST; do
    if [ -x "$F" ]; then
        GDATE="$F"
        break
    fi
done
[ x"$GDATE" != x -a ! -x "$GDATE" ] && GDATE=""
if [ x"$GDATE" = x ]; then
    gdate && GDATE="`which gdate | head -1`"
fi
[ x"$GDATE" != x -a ! -x "$GDATE" ] && GDATE=""

SVC_RET=-1
case "$1" in
start)
    stopOldKicker
    testBlockFile

    VM_STATE="$( vm_state "$INSTANCE" )"
    case "x$VM_STATE" in
    xrunning|xstarting|xrestoring|xpaused)
        echo "INFO: `LANG=C TZ=UTC date`: VM '$INSTANCE' is in state '$VM_STATE',"
        echo "      trying to save VM state before starting SMF service..."
        FORCE_STOP_METHOD=savestate stop_vm "$INSTANCE"
	;;
    esac

    echo "INFO: trying to start VM '$INSTANCE'..."
    start
    SVC_RET=$?

    ( ### KICKER loop
      if [ x"$GDATE" != x -a -x "$GDATE" ]; then
	 TS_VM_STARTED="`TZ=UTC $GDATE +%s`" || TS_VM_STARTED=0
      fi

      sleeper 20
      echo "INFO: `LANG=C TZ=UTC date`: Starting KICKER monitoring of VM state."
      echo "INFO: First KICKER run may report unset SMF service parameters"
      echo "      where we had to apply defaults; further runs shouldn't."

      KICKER_NOKICK_FILE_NAME="$( GETPROPARG_QUIET=true getproparg vm/kicker_nokick_file_name)"
      [    x"$KICKER_NOKICK_FILE_NAME" = x'""' \
	-o x"$KICKER_NOKICK_FILE_NAME" = x"''" \
	-o x"$KICKER_NOKICK_FILE_NAME" = x \
      ] && KICKER_NOKICK_FILE_NAME="$KICKER_PIDFILE_NAME.nokick"

      KICKER_NOSLEEP=true kick || exit

      ### Just to inform the user if the variable is set...
      RESTART_SAVED_VM_ONCE_FILE_NAME="$( getproparg vm/kicker_restart_saved_vm_once_file_name )" || \
	RESTART_SAVED_VM_ONCE_FILE_NAME=""

      GETPROPARG_QUIET=true
      export GETPROPARG_QUIET
      echo "INFO: `LANG=C TZ=UTC date`: Starting KICKER endless loop for VM '$INSTANCE'"

      ### Here we enforce additional sleep, beside one defined by SMF property
      while kick; do sleeper 10; done ) &
    echo $! > "$KICKER_PIDFILE_NAME"
    ;;
stop)
    stopOldKicker
    stop
    SVC_RET=$?
    ;;
startgui)
    ### export SMF_FMRI='svc:/site/xvm/vbox:VM_NAME' in the caller
    if [ x"$SMF_FMRI" = x -o x"$INSTANCE" = x ]; then
	echo "ERROR: requires valid SMF_FMRI of the VM instance!" >&2
	exit 1
    fi

    if [ x"$DISPLAY" = x ]; then
	echo "ERROR: GUI start requires a valid DISPLAY variable!" >&2
	exit 2
    fi

    RUN_USER="`get_run_as 2>/dev/null`"
    get_run_as >/dev/null

    KICKER_NOKICK_FILE_NAME="$( GETPROPARG_QUIET=true getproparg vm/kicker_nokick_file_name)"
    [    x"$KICKER_NOKICK_FILE_NAME" = x'""' \
      -o x"$KICKER_NOKICK_FILE_NAME" = x"''" \
      -o x"$KICKER_NOKICK_FILE_NAME" = x \
    ] && KICKER_NOKICK_FILE_NAME="$KICKER_PIDFILE_NAME.nokick"

    $RUNAS touch "$KICKER_NOKICK_FILE_NAME"

    echo "INFO: trying to stop (savestate) VM '$INSTANCE' just in case it is running..."
    echo "INFO: failure due to already stopped VM is okay here"
    FORCE_STOP_METHOD=savestate stop_vm "$INSTANCE"
    echo "INFO: done stopping ($?)"
    echo ""

    echo "INFO: trying to start VM '$INSTANCE' in GUI mode (DISPLAY='$DISPLAY', RUNAS='$RUNAS')..."
    if [ x"$RUNAS" != x ]; then
	xhost +localhost
	$RUNAS DISPLAY="$DISPLAY" /usr/bin/VBoxManage startvm "$INSTANCE" --type gui
        SVC_RET="$?"
    else
	/usr/bin/VBoxManage startvm "$INSTANCE" --type gui
        SVC_RET="$?"
    fi

    [ -f "$KICKER_NOKICK_FILE_NAME" ] && $RUNAS rm -f "$KICKER_NOKICK_FILE_NAME"

    if [ x"$SVC_RET" = x0 ]; then
	### Running as another user via 'su' may cause echoing of shell greetings
	### we don't want them in property values, so run this as current user
        RESTART_SAVED_VM_ONCE_FILE_NAME="$( getproparg vm/kicker_restart_saved_vm_once_file_name )" || \
	RESTART_SAVED_VM_ONCE_FILE_NAME=""

        [   x"$RESTART_SAVED_VM_ONCE_FILE_NAME" = x'""' -o \
	    x"$RESTART_SAVED_VM_ONCE_FILE_NAME" = x"''" -o \
    	    x"$RESTART_SAVED_VM_ONCE_FILE_NAME" = x"true" ] && \
		RESTART_SAVED_VM_ONCE_FILE_NAME=""
	[ x"$RESTART_SAVED_VM_ONCE_FILE_NAME" = x -a -w "/var/run" -a x"$RUNAS" = x ] && \
		RESTART_SAVED_VM_ONCE_FILE_NAME="/var/run/.vboxsvc-kicker-$INSTANCE.restart_saved_once"
	[ x"$RESTART_SAVED_VM_ONCE_FILE_NAME" = x ] && \
		RESTART_SAVED_VM_ONCE_FILE_NAME="/tmp/.vboxsvc-kicker-$INSTANCE.restart_saved_once"

        if [ x"$RESTART_SAVED_VM_ONCE_FILE_NAME" != xfalse ]; then
#         if [ ! -f "$RESTART_SAVED_VM_ONCE_FILE_NAME" ]; then
	    echo "INFO: trying to leave a RESTART_SAVED_VM_ONCE_FILE_NAME file ($RESTART_SAVED_VM_ONCE_FILE_NAME)..."
	    $RUNAS touch "$RESTART_SAVED_VM_ONCE_FILE_NAME"
#	  fi
	fi
    else
	echo "ERROR: VM '$INSTANCE' startup error detected. Return code: '$SVC_RET'"
    fi
    ;;
getstate|state|status)
    ### export SMF_FMRI='svc:/site/xvm/vbox:VM_NAME' in the caller
    getState
    SVC_RET=$?
    exit $SVC_RET
    ;;
reboot)
    ### export SMF_FMRI='svc:/site/xvm/vbox:VM_NAME' in the caller
    RUN_USER="`get_run_as 2>/dev/null`"
    get_run_as >/dev/null

    KICKER_NOKICK_FILE_NAME="$( GETPROPARG_QUIET=true getproparg vm/kicker_nokick_file_name)"
    [    x"$KICKER_NOKICK_FILE_NAME" = x'""' \
      -o x"$KICKER_NOKICK_FILE_NAME" = x"''" \
      -o x"$KICKER_NOKICK_FILE_NAME" = x \
    ] && KICKER_NOKICK_FILE_NAME="$KICKER_PIDFILE_NAME.nokick"

    $RUNAS touch "$KICKER_NOKICK_FILE_NAME"

    reboot_vm "$INSTANCE" $2
    SVC_RET=$?

    [ -f "$KICKER_NOKICK_FILE_NAME" ] && \
	$RUNAS rm -f "$KICKER_NOKICK_FILE_NAME"

    exit $SVC_RET
    ;;
reset)
    ### export SMF_FMRI='svc:/site/xvm/vbox:VM_NAME' in the caller
    RUN_USER="`get_run_as 2>/dev/null`"
    get_run_as >/dev/null

    KICKER_NOKICK_FILE_NAME="$( GETPROPARG_QUIET=true getproparg vm/kicker_nokick_file_name)"
    [    x"$KICKER_NOKICK_FILE_NAME" = x'""' \
      -o x"$KICKER_NOKICK_FILE_NAME" = x"''" \
      -o x"$KICKER_NOKICK_FILE_NAME" = x \
    ] && KICKER_NOKICK_FILE_NAME="$KICKER_PIDFILE_NAME.nokick"

    $RUNAS touch "$KICKER_NOKICK_FILE_NAME"

    FORCE_STOP_METHOD=reset stop_vm "$INSTANCE"
    SVC_RET=$?

    [ -f "$KICKER_NOKICK_FILE_NAME" ] && $RUNAS rm -f "$KICKER_NOKICK_FILE_NAME"

    exit $SVC_RET
    ;;
help|--help|-help|-h|'-?'|'/?')
    printHelp
    echo "INFO: `LANG=C TZ=UTC date`: printed help. Did not try to change state of VM '$INSTANCE'"
    SVC_RET=0
    ;;
*)
    echo "ERROR: Unknown parameter(s) passed: '$0 $@'"
    printHelp
    SVC_RET=2
    ;;
esac

if [ "$SVC_RET" -ne 0 ]; then
    echo "ERROR: `LANG=C TZ=UTC date`: VM $INSTANCE failed to start/stop."
    exit $SMF_EXIT_ERR_FATAL
fi

exit $SMF_EXIT_OK
