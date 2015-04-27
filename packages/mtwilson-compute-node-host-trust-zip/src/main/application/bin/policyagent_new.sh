#!/bin/bash

# chkconfig: 2345 80 30
# description: Intel Policy Agent

### BEGIN INIT INFO
# Provides:          policyagent
# Required-Start:    $remote_fs $syslog
# Required-Stop:     $remote_fs $syslog
# Should-Start:      $portmap
# Should-Stop:       $portmap
# X-Start-Before:    nis
# X-Stop-After:      nis
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# X-Interactive:     true
# Short-Description: policyagent
# Description:       Main script to run policyagent commands
### END INIT INFO
DESC="POLICYAGENT"
NAME=policyagent

# the home directory must be defined before we load any environment or
# configuration files; it is explicitly passed through the sudo command
export POLICYAGENT_HOME=${POLICYAGENT_HOME:-/opt/policyagent}

# the env directory is not configurable; it is defined as POLICYAGENT_HOME/env and
# the administrator may use a symlink if necessary to place it anywhere else
export POLICYAGENT_ENV=$POLICYAGENT_HOME/env

policyagent_load_env() {
  local env_files="$@"
  local env_file_exports
  for env_file in $env_files; do
    if [ -n "$env_file" ] && [ -f "$env_file" ]; then
      . $env_file
      env_file_exports=$(cat $env_file | grep -E '^[A-Z0-9_]+\s*=' | cut -d = -f 1)
      if [ -n "$env_file_exports" ]; then eval export $env_file_exports; fi
    fi
  done  
}

if [ -z "$POLICYAGENT_USERNAME" ]; then
  policyagent_load_env $POLICYAGENT_HOME/env/policyagent-username
fi

###################################################################################################

# if non-root execution is specified, and we are currently root, start over; the POLICYAGENT_SUDO variable limits this to one attempt
# we make an exception for the uninstall command, which may require root access to delete users and certain directories
if [ -n "$POLICYAGENT_USERNAME" ] && [ "$POLICYAGENT_USERNAME" != "root" ] && [ $(whoami) == "root" ] && [ -z "$POLICYAGENT_SUDO" ] && [ "$1" != "uninstall" ]; then
  sudo -u $POLICYAGENT_USERNAME POLICYAGENT_USERNAME=$POLICYAGENT_USERNAME POLICYAGENT_HOME=$POLICYAGENT_HOME POLICYAGENT_PASSWORD=$POLICYAGENT_PASSWORD POLICYAGENT_SUDO=true policyagent $*
  exit $?
fi

###################################################################################################

# load environment variables; these may override the defaults set above and
# also note that policyagent-username file is loaded twice, once before sudo and
# once here after sudo.
if [ -d $POLICYAGENT_ENV ]; then
  policyagent_load_env $(ls -1 $POLICYAGENT_ENV/*)
fi

# default directory layout follows the 'home' style
export POLICYAGENT_CONFIGURATION=${POLICYAGENT_CONFIGURATION:-${POLICYAGENT_CONF:-$POLICYAGENT_HOME/configuration}}
export POLICYAGENT_JAVA=${POLICYAGENT_JAVA:-$POLICYAGENT_HOME/java}
export POLICYAGENT_BIN=${POLICYAGENT_BIN:-$POLICYAGENT_HOME/bin}
export POLICYAGENT_REPOSITORY=${POLICYAGENT_REPOSITORY:-$POLICYAGENT_HOME/repository}
export POLICYAGENT_LOGS=${POLICYAGENT_LOGS:-$POLICYAGENT_HOME/logs}

# needed for if certain methods are called from policyagent.sh like java_detect, etc.
POLICYAGENT_INSTALL_LOG_FILE=${POLICYAGENT_INSTALL_LOG_FILE:-"$POLICYAGENT_LOGS/policyagent_install.log"}
export INSTALL_LOG_FILE="$POLICYAGENT_INSTALL_LOG_FILE"

###################################################################################################

# load linux utility
if [ -f "$POLICYAGENT_BIN/functions.sh" ]; then
  . $POLICYAGENT_BIN/functions.sh
fi
if [ -f "$POLICYAGENT_BIN/policyagent-functions.sh" ]; then
  . $POLICYAGENT_BIN/policyagent-functions.sh
fi

###################################################################################################

# all other variables with defaults
POLICYAGENT_APPLICATION_LOG_FILE=${POLICYAGENT_APPLICATION_LOG_FILE:-$POLICYAGENT_LOGS/policyagent.log}
touch "$POLICYAGENT_APPLICATION_LOG_FILE"
chown "$POLICYAGENT_USERNAME":"$POLICYAGENT_USERNAME" "$POLICYAGENT_APPLICATION_LOG_FILE"
chmod 600 "$POLICYAGENT_APPLICATION_LOG_FILE"
JAVA_REQUIRED_VERSION=${JAVA_REQUIRED_VERSION:-1.7}
JAVA_OPTS=${JAVA_OPTS:-"-Dlogback.configurationFile=$POLICYAGENT_CONFIGURATION/logback.xml"}

POLICYAGENT_SETUP_FIRST_TASKS=${POLICYAGENT_SETUP_FIRST_TASKS:-"update-extensions-cache-file"}
POLICYAGENT_SETUP_TASKS=${POLICYAGENT_SETUP_TASKS:-"password-vault"}

# the standard PID file location /var/run is typically owned by root;
# if we are running as non-root and the standard location isn't writable 
# then we need a different place
POLICYAGENT_PID_FILE=${POLICYAGENT_PID_FILE:-/var/run/policyagent.pid}
if [ ! -w "$POLICYAGENT_PID_FILE" ] && [ ! -w $(dirname "$POLICYAGENT_PID_FILE") ]; then
  POLICYAGENT_PID_FILE=$POLICYAGENT_REPOSITORY/policyagent.pid
fi

###################################################################################################

# generated variables
JARS=$(ls -1 $POLICYAGENT_JAVA/*.jar)
CLASSPATH=$(echo $JARS | tr ' ' ':')

if [ -z "$JAVA_HOME" ]; then java_detect; fi
CLASSPATH=$CLASSPATH:$(find "$JAVA_HOME" -name jfxrt*.jar | head -n 1)

# the classpath is long and if we use the java -cp option we will not be
# able to see the full command line in ps because the output is normally
# truncated at 4096 characters. so we export the classpath to the environment
export CLASSPATH

###################################################################################################

# run a policyagent command
policyagent_run() {
  local args="$*"
  java $JAVA_OPTS com.intel.mtwilson.launcher.console.Main $args
  return $?
}

# run default set of setup tasks and check if admin user needs to be created
policyagent_complete_setup() {
  # run all setup tasks, don't use the force option to avoid clobbering existing
  # useful configuration files
  policyagent_run setup $POLICYAGENT_SETUP_FIRST_TASKS
  policyagent_run setup $POLICYAGENT_SETUP_TASKS
}

# arguments are optional, if provided they are the names of the tasks to run, in order
policyagent_setup() {
  local args="$*"
  java $JAVA_OPTS com.intel.mtwilson.launcher.console.Main setup $args
  return $?
}

policyagent_start() {
    if [ -z "$POLICYAGENT_PASSWORD" ]; then
      echo_failure "Master password is required; export POLICYAGENT_PASSWORD"
      return 1
    fi

    # check if we're already running - don't start a second instance
    if policyagent_is_running; then
      echo "Policy Agent is running"
      return 0
    fi

    # check if we need to use authbind or if we can start java directly
    prog="java"
    if [ -n "$POLICYAGENT_USERNAME" ] && [ "$POLICYAGENT_USERNAME" != "root" ] && [ $(whoami) != "root" ] && [ -n $(which authbind) ]; then
      prog="authbind java"
      JAVA_OPTS="$JAVA_OPTS -Djava.net.preferIPv4Stack=true"
    fi

    # the subshell allows the java process to have a reasonable current working
    # directory without affecting the user's working directory. 
    # the last background process pid $! must be stored from the subshell.
    (
      cd $POLICYAGENT_HOME
      $prog $JAVA_OPTS com.intel.mtwilson.launcher.console.Main start >>$POLICYAGENT_APPLICATION_LOG_FILE 2>&1 &
      echo $! > $POLICYAGENT_PID_FILE
    )
    if policyagent_is_running; then
      echo_success "Started Policy Agent"
    else
      echo_failure "Failed to start Policy Agent"
    fi
}

# returns 0 if Policy Agent is running, 1 if not running
# side effects: sets POLICYAGENT_PID if Policy Agent is running, or to empty otherwise
policyagent_is_running() {
  POLICYAGENT_PID=
  if [ -f $POLICYAGENT_PID_FILE ]; then
    POLICYAGENT_PID=$(cat $POLICYAGENT_PID_FILE)
    local is_running=`ps -A -o pid | grep "^\s*${POLICYAGENT_PID}$"`
    if [ -z "$is_running" ]; then
      # stale PID file
      POLICYAGENT_PID=
    fi
  fi
  if [ -z "$POLICYAGENT_PID" ]; then
    # check the process list just in case the pid file is stale
    POLICYAGENT_PID=$(ps -A ww | grep -v grep | grep java | grep "com.intel.mtwilson.launcher.console.Main start" | grep "$POLICYAGENT_CONFIGURATION" | awk '{ print $1 }')
  fi
  if [ -z "$POLICYAGENT_PID" ]; then
    # Policy Agent is not running
    return 1
  fi
  # Policy Agent is running and POLICYAGENT_PID is set
  return 0
}


policyagent_stop() {
  if policyagent_is_running; then
    kill -9 $POLICYAGENT_PID
    if [ $? ]; then
      echo "Stopped Policy Agent"
      # truncate pid file instead of erasing,
      # because we may not have permission to create it
      # if we're running as a non-root user
      echo > $POLICYAGENT_PID_FILE
    else
      echo "Failed to stop Policy Agent"
    fi
  fi
}

# removes Policy Agent home directory (including configuration and data if they are there).
# if you need to keep those, back them up before calling uninstall,
# or if the configuration and data are outside the home directory
# they will not be removed, so you could configure POLICYAGENT_CONFIGURATION=/etc/policyagent
# and POLICYAGENT_REPOSITORY=/var/opt/policyagent and then they would not be deleted by this.
policyagent_uninstall() {
    remove_startup_script policyagent
    rm -f /usr/local/bin/policyagent
    rm -rf /opt/policyagent
    groupdel policyagent > /dev/null 2>&1
    userdel policyagent > /dev/null 2>&1
}

print_help() {
    echo "Usage: $0 start|stop|uninstall|version"
    echo "Usage: $0 setup [--force|--noexec] [task1 task2 ...]"
    echo "Available setup tasks:"
    echo $POLICYAGENT_SETUP_TASKS | tr ' ' '\n'
}

###################################################################################################

# here we look for specific commands first that we will handle in the
# script, and anything else we send to the java application

case "$1" in
  help)
    print_help
    ;;
  start)
    policyagent_start
    ;;
  stop)
    policyagent_stop
    ;;
  restart)
    policyagent_stop
    policyagent_start
    ;;
  status)
    if policyagent_is_running; then
      echo "Policy Agent is running"
      exit 0
    else
      echo "Policy Agent is not running"
      exit 1
    fi
    ;;
  setup)
    shift
    if [ -n "$1" ]; then
      policyagent_setup $*
    else
      policyagent_complete_setup
    fi
    ;;
  uninstall)
    policyagent_stop
    policyagent_uninstall
    ;;
  version)
    echo "Project Version: ${project.version}"
    echo "Build Timestamp: ${build.timestamp}"
    echo "Branch: ${git.branch}"
  *)
    if [ -z "$*" ]; then
      print_help
    else
      #echo "args: $*"
      java $JAVA_OPTS com.intel.mtwilson.launcher.console.Main $*
    fi
    ;;
esac


exit $?
