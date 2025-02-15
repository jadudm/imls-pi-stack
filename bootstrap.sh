#!/usr/bin/env bash

# TESTING ENV VARS
# NOLOCKDOWN - prevents the pi from hardening and locking down. For testing.
# NOREBOOT - prevents reboot at end of bootstrap.sh
# DEVELOP - sets NOLOCKDOWN, NOREBOOT and pulls from development branch instead of production versions.
#
# Usage:
# DEVELOP=1 bash <(curl -s ...)

# We assume this script will be curl'd in.
# We assume it will be curl'd in and sudo will prompt for a password.

# It is for configuring a Raspberry Pi to be part of a pilot data collection effort.
# That pilot is being run in partnership between 10x/18F/IMLS.
# If you are not one of the people taking part in that pilot, then this
# software will *not* be useful to you.
# It will do things to your Raspberry Pi.
# Things you might not want.
# You have been warned.
# Here be krackens.

# CRITICAL GLOBALS
PLAYBOOK_WORKING_DIR="/opt/imls"
GHUSER="jadudm"

# A GLOBAL CATCH
# If something goes wrong, set this to 1.
# If the _error function is ever used, it sets this automatically.
SOMETHING_WENT_WRONG=0

# PURPOSE
# Creates a temporary logfile in a way that lets the OS
# decide where it should go.
create_logfile () {
    SETUP_LOGFILE=$(mktemp -t "setup-log-XXX")
    export SETUP_LOGFILE
}

mangle_console () {
    # https://serverfault.com/questions/103501/how-can-i-fully-log-all-bash-scripts-actions
    # Save all the pipes.
    # 3 is Stdout. 4 is stderr.
    exec 3>&1 4>&2
    # Restore some.
    trap 'exec 2>&4 1>&3' 0 1 2 3
    exec 1>> /dev/null 2>&1
}

# PURPOSE
# Sets up redirects so that STDOUT and STDERR make their way to
# a temporary logfile.
setup_logging () {
    mangle_console
    # Redirect stdout/stderr to a logfile.
    exec 1>> "${SETUP_LOGFILE}" 2>&1
    _status "Logfile started. It can be accessed for debugging purposes."
    _variable "SETUP_LOGFILE"
}


# COLORS!
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
PURPLE='\033[0;35m'
# No color
NC='\033[0m'

_log_event () {
    TAG="$1"
    [ -f /usr/local/bin/log-event ] && /usr/local/bin/log-event --tag "${TAG}" --info "{\"message\": \"$2\"}"
}

_msg () {
    TAG="$1"
    COLOR="$2"
    MSG="$3"
    printf "[%s] %s\n" "${TAG}" "${MSG}" >&1
    printf "[%b%s%b] %s\n" "${COLOR}" "${TAG}" "${NC}" "${MSG}" >&3
}

_status () {
    MSG="$1"
    _msg "STATUS" "${GREEN}" "${MSG}"
    # [ -f /usr/local/bin/log-event ] && /usr/local/bin/log-event --tag "bootstrap status" --info "{\"message\": \"${MSG}\"}"
    _log_event "bootstrap status" "${MSG}"
}

_debug () {
    MSG="$1"
    _msg "DEBUG" "${YELLOW}" "${MSG}"
    # [ -f /usr/local/bin/log-event ] && /usr/local/bin/log-event --tag "bootstrap debug" --info "{\"message\": \"${MSG}\"}"
    _log_event "bootstrap debug" "${MSG}"

}

_error () {
    SOMETHING_WENT_WRONG=1
    MSG="$1"
    _msg "ERROR" "${RED}" "${MSG}"
    # [ -f /usr/local/bin/log-event ] && /usr/local/bin/log-event --tag "bootstrap error" --info "{\"message\": \"${MSG}\"}"
    _log_event "bootstrap error" "${MSG}"

}

_variable () {
    VAR="$1"
    _msg "${VAR}" "${PURPLE}" "${!VAR}"
}

####################################
# CHECKS
# These are helper functions for checking if things exist,
# etc. Used a lot, clarifies the code.

# https://stackoverflow.com/questions/592620/how-can-i-check-if-a-program-exists-from-a-bash-script
command_exists () {
    type "$1" &> /dev/null ;
}

command_does_not_exist () {
    if command_exists "$1"; then
        return 1
    else
        return 0
    fi
}

# PURPOSE
# Restores the file descriptors after capturing/redirecting.
restore_console () {
    # https://stackoverflow.com/questions/21106465/restoring-stdout-and-stderr-to-default-value
    # Reconnect stdout and close the third filedescriptor.
    exec 1>&4 4>&-
    # Reconnect stderr
    exec 1>&3 3>&-
}

initial_update () {
    echo "Doing an initial software update."
    mangle_console
    sudo apt update
    restore_console
}

fix_the_time () {
    echo "Setting the time."
    mangle_console
    sudo apt install -y ntp ntpdate
    sudo service ntp stop
    sudo ntpdate 0.us.pool.ntp.org
    sudo service ntp start
    restore_console
}

shim () {
    echo "Setting up the environment."
    mangle_console
    if [[ -n "${DEVELOP}" ]]; then
        bash <(curl -s https://raw.githubusercontent.com/${GHUSER}/imls-pi-stack/main/dev.shim)
        restore_console
        _debug "Set up a development environment"
    else
        bash <(curl -s https://raw.githubusercontent.com/${GHUSER}/imls-pi-stack/main/prod.shim)
        restore_console
        _debug "Set up a production environment"
    fi
}

check_for_usb_wifi () {
    echo "Checking for wifi..."
    mangle_console
    sudo apt install -y lshw
    if [[ "$(/usr/local/bin/wifi-hardware-search-cli --exists)" =~ "false" ]]; then
        _log_event "check_for_usb_wifi" "usb wifi not found"
        restore_console
        echo "********************* PANIC OH NOES! *********************"
        echo "We think you did not plug in the USB wifi adapter!"
        echo "Please do the following:"
        echo ""
        echo " 1. Plug in the USB wifi adapter."
        echo " 2. Push the up arrow. (This brings back the bash command.)"
        echo " 3. Press enter."
        echo ""
        echo "This will start the setup process again."
        echo "********************* PANIC OH NOES! *********************"
        echo ""
        exit 1
    fi
    restore_console
}

read_initial_configuration () {
    # just in case
    mkdir -p "${PLAYBOOK_WORKING_DIR}"
    _debug "Running input-initial-configuration"
    sudo /usr/local/bin/input-initial-configuration --path "${PLAYBOOK_WORKING_DIR}/auth.yaml" --fcfs-seq --tag --word-pairs --write
}

bootstrap_ansible () {
    _status "Bootstrapping Ansible"
    _status "Updating sources."
    echo "deb http://ppa.launchpad.net/ansible/ansible/ubuntu trusty main" | sudo tee -a /etc/apt/sources.list
    _status "Installing dirmngr."
    sudo apt-get install dirmngr -y
    _status "Adding local keys."
    sudo apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 93C4A3FD7BB9C367
    _status "Doing an update. This may take a moment. Be patient."
    sudo apt-get update
    _status "Installing the most recent ansible."
    sudo apt-get install -y ansible
}

# PURPOSE
# This clones and runs the playbook for configuring the
# RPi for the IMLS/10x/18F data collection pilot.
# ansible_pull_playbook () {
#     _status "Installing hardening playbook."
#     ansible-galaxy collection install devsec.hardening

#     pushd "${PLAYBOOK_WORKING_DIR}/source/imls-playbook" || return
#         _status "Running the playbook. This will take a while."
#         # For testing/dev purposes, we might not want to lock things down
#         # when we're done. The lockdown flag is required to run the
#         # hardening and lockdown roles.

#         # -z checks if the var is UNSET.
#         if [[ -z "${NOLOCKDOWN}" && -z "${DEVELOP}" ]]; then
#             ansible-playbook -i inventory.yaml playbook.yaml --extra-vars "lockdown=yes, version=$(cat ../prod-version.txt)"
#         else
#             _status "Running playbook WITHOUT lockdown"
#             ansible-playbook -vvv -i inventory.yaml playbook.yaml --extra-vars "develop=yes, version=$(cat ../dev-version.txt)"
#         fi
#         ANSIBLE_EXIT_STATUS=$?
#     popd || return
#     _status "Done running playbook."
#     if [ "${ANSIBLE_EXIT_STATUS}" -ne 0 ]; then
#         _err "Ansible playbook failed."
#         _err "Exit code: ${ANSIBLE_EXIT_STATUS}"
#         _err "Check the log: ${SETUP_LOGFILE}"
#     fi
# }


# PURPOSE
# Clones a "bootstrap" playbook. All it does is install
# the service units that run the full playbook.
serviceunit_playbook () {
    _status "Installing serviceunit playbook."

    pushd "${PLAYBOOK_WORKING_DIR}/source/imls-playbook" || return
        _status "Running the serviceunit playbook. This may take a bit."
        # -z checks if the var is UNSET.
        if [[ -z "${NOLOCKDOWN}" && -z "${DEVELOP}" ]]; then
            ansible-playbook -i inventory.yaml serviceunits.yaml  --extra-vars "lockdown=yes, version=$(cat ../prod-version.txt)"
        else
            _status "Running playbook WITHOUT lockdown"
            ansible-playbook -vvv -i inventory.yaml serviceunits.yaml --extra-vars "develop=yes, version=$(cat ../dev-version.txt)"
        fi
        ANSIBLE_EXIT_STATUS=$?
    popd || return
    _status "Done running serviceunit playbook."
    if [ "${ANSIBLE_EXIT_STATUS}" -ne 0 ]; then
        _err "Ansible serviceunit playbook failed."
        _err "Exit code: ${ANSIBLE_EXIT_STATUS}"
        _err "Check the log: ${SETUP_LOGFILE}"
    fi
}

enable_playbooks () {
    _status "Enabling playbooks"
    flagfile="${PLAYBOOK_WORKING_DIR}/RUNPLAYBOOKS"
    sudo touch "${flagfile}"
    sudo chmod a+r "${flagfile}"
}

disable_interactive_login () {
    # https://www.raspberrypi.org/forums/viewtopic.php?t=21632
    # Disables console and desktop login using the builtin script.
    # This tells the pi to boot to the console login, but not to auto-login `pi`
    # https://github.com/RPi-Distro/raspi-config/blob/master/raspi-config#L1308
    sudo /usr/bin/raspi-config nonint do_boot_behaviour B1
}

main () {
    echo "*****************************************************************"
    echo "* Thank you for participating in the IMLS pilot project.        *"
    echo "* We are going to configure this Raspberry Pi as a wifi sensor. *"
    echo "* Expect this process to take about 20 to 30 minutes.           *"
    echo "*****************************************************************"
    initial_update
    fix_the_time
    shim
    _log_event "bootstrap" "done running shim"
    # After shim, we can use `log-event`
    check_for_usb_wifi
    read_initial_configuration
    create_logfile
    setup_logging
    bootstrap_ansible
    # ansible_pull_playbook
    serviceunit_playbook
    disable_interactive_login
    if [ "${SOMETHING_WENT_WRONG}" -ne 0 ]; then
        _error "Things finished with errors."
        _error "We have logged the errors at ${SETUP_LOGFILE}"
        [ -f /usr/local/bin/log-event ] && /usr/local/bin/log-event --tag "bootstrap something_went_wrong" --file "${SETUP_LOGFILE}"
    else
        _status "All done!"
        _status "We're rebooting in one minute!"
        enable_playbooks

        # If the NOREBOOT or DEVELOP flags are NOT set, then reboot.
        if [[ -z "${NOREBOOT}" && -z "${DEVELOP}" ]]; then
            sleep 60
            sudo reboot
        else
            _status "Reboot prevented by env flag."
        fi
    fi
}

main
