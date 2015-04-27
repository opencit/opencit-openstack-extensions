#!/bin/sh

# Policy Agent install script
# Outline:
# 1. source the "functions.sh" file:  mtwilson-linux-util-3.0-SNAPSHOT.sh
# 2. load existing environment configuration
# 3. look for ~/policyagent.env and source it if it's there
# 4. prompt for installation variables if they are not provided
# 5. determine if we are installing as root or non-root user; set paths
# 6. detect java
# 7. if java not installed, and we have it bundled, install it
# 8. unzip policyagent archive policyagent-zip-0.1-SNAPSHOT.zip into /opt/policyagent, overwrite if any files already exist
# 9. link /usr/local/bin/policyagent -> /opt/policyagent/bin/policyagent, if not already there
# 10. add policyagent to startup services
# 11. look for POLICYAGENT_PASSWORD environment variable; if not present print help message and exit:
#     Policy Agent requires a master password
#     to generate a password run "export POLICYAGENT_PASSWORD=$(policyagent generate-password) && echo POLICYAGENT_PASSWORD=$POLICYAGENT_PASSWORD"
#     you must store this password in a safe place
#     losing the master password will result in data loss
# 12. policyagent setup
# 13. policyagent start

#####

# default settings
# note the layout setting is used only by this script
# and it is not saved or used by the app script
export POLICYAGENT_HOME=${POLICYAGENT_HOME:-/opt/policyagent}
POLICYAGENT_LAYOUT=${POLICYAGENT_LAYOUT:-home}

# the env directory is not configurable; it is defined as POLICYAGENT_HOME/env and
# the administrator may use a symlink if necessary to place it anywhere else
export POLICYAGENT_ENV=$POLICYAGENT_HOME/env

# load application environment variables if already defined
if [ -d $POLICYAGENT_ENV ]; then
  POLICYAGENT_ENV_FILES=$(ls -1 $POLICYAGENT_ENV/*)
  for env_file in $POLICYAGENT_ENV_FILES; do
    . $env_file
    env_file_exports=$(cat $env_file | grep -E '^[A-Z0-9_]+\s*=' | cut -d = -f 1)
    if [ -n "$env_file_exports" ]; then eval export $env_file_exports; fi
  done
fi

# functions script (mtwilson-linux-util-3.0-SNAPSHOT.sh) is required
# we use the following functions:
# java_detect java_ready_report 
# echo_failure echo_warning
# register_startup_script
UTIL_SCRIPT_FILE=$(ls -1 mtwilson-linux-util-*.sh | head -n 1)
if [ -n "$UTIL_SCRIPT_FILE" ] && [ -f "$UTIL_SCRIPT_FILE" ]; then
  . $UTIL_SCRIPT_FILE
fi
POLICYAGENT_UTIL_SCRIPT_FILE=$(ls -1 policyagent-functions.sh | head -n 1)
if [ -n "$POLICYAGENT_UTIL_SCRIPT_FILE" ] && [ -f "$POLICYAGENT_UTIL_SCRIPT_FILE" ]; then
  . $POLICYAGENT_UTIL_SCRIPT_FILE
fi

# load installer environment file, if present
if [ -f ~/policyagent.env ]; then
  echo "Loading environment variables from $(cd ~ && pwd)/policyagent.env"
  . ~/policyagent.env
  env_file_exports=$(cat ~/policyagent.env | grep -E '^[A-Z0-9_]+\s*=' | cut -d = -f 1)
  if [ -n "$env_file_exports" ]; then eval export $env_file_exports; fi
else
  echo "No environment file"
fi

# determine if we are installing as root or non-root
if [ "$(whoami)" == "root" ]; then
  # create a policyagent user if there isn't already one created
  POLICYAGENT_USERNAME=${POLICYAGENT_USERNAME:-policyagent}
  if ! getent passwd $POLICYAGENT_USERNAME 2>&1 >/dev/null; then
    useradd --comment "Mt Wilson Policy Agent" --home $POLICYAGENT_HOME --system --shell /bin/false $POLICYAGENT_USERNAME
    usermod --lock $POLICYAGENT_USERNAME
    # note: to assign a shell and allow login you can run "usermod --shell /bin/bash --unlock $POLICYAGENT_USERNAME"
  fi
else
  # already running as policyagent user
  POLICYAGENT_USERNAME=$(whoami)
  echo_warning "Running as $POLICYAGENT_USERNAME; if installation fails try again as root"
  if [ ! -w "$POLICYAGENT_HOME" ] && [ ! -w $(dirname $POLICYAGENT_HOME) ]; then
    export POLICYAGENT_HOME=$(cd ~ && pwd)
  fi
fi

# if an existing policyagent is already running, stop it while we install
if which policyagent; then
  policyagent stop
fi

# define application directory layout
if [ "$POLICYAGENT_LAYOUT" == "linux" ]; then
  export POLICYAGENT_CONFIGURATION=${POLICYAGENT_CONFIGURATION:-/etc/policyagent}
  export POLICYAGENT_REPOSITORY=${POLICYAGENT_REPOSITORY:-/var/opt/policyagent}
  export POLICYAGENT_LOGS=${POLICYAGENT_LOGS:-/var/log/policyagent}
elif [ "$POLICYAGENT_LAYOUT" == "home" ]; then
  export POLICYAGENT_CONFIGURATION=${POLICYAGENT_CONFIGURATION:-$POLICYAGENT_HOME/configuration}
  export POLICYAGENT_REPOSITORY=${POLICYAGENT_REPOSITORY:-$POLICYAGENT_HOME/repository}
  export POLICYAGENT_LOGS=${POLICYAGENT_LOGS:-$POLICYAGENT_HOME/logs}
fi
export POLICYAGENT_BIN=$POLICYAGENT_HOME/bin
export POLICYAGENT_JAVA=$POLICYAGENT_HOME/java

# note that the env dir is not configurable; it is defined as "env" under home
export POLICYAGENT_ENV=$POLICYAGENT_HOME/env

policyagent_backup_configuration() {
  if [ -n "$POLICYAGENT_CONFIGURATION" ] && [ -d "$POLICYAGENT_CONFIGURATION" ]; then
    datestr=`date +%Y%m%d.%H%M`
    backupdir=/var/backup/policyagent.configuration.$datestr
    cp -r $POLICYAGENT_CONFIGURATION $backupdir
  fi
}

policyagent_backup_repository() {
  if [ -n "$POLICYAGENT_REPOSITORY" ] && [ -d "$POLICYAGENT_REPOSITORY" ]; then
    datestr=`date +%Y%m%d.%H%M`
    backupdir=/var/backup/policyagent.repository.$datestr
    cp -r $POLICYAGENT_REPOSITORY $backupdir
  fi
}

# backup current configuration and data, if they exist
policyagent_backup_configuration
policyagent_backup_repository

if [ -d $POLICYAGENT_CONFIGURATION ]; then
  backup_conf_dir=$POLICYAGENT_REPOSITORY/backup/configuration.$(date +"%Y%m%d.%H%M")
  mkdir -p $backup_conf_dir
  cp -R $POLICYAGENT_CONFIGURATION/* $backup_conf_dir
fi

# create application directories (chown will be repeated near end of this script, after setup)
for directory in $POLICYAGENT_HOME $POLICYAGENT_CONFIGURATION $POLICYAGENT_ENV $POLICYAGENT_REPOSITORY $POLICYAGENT_LOGS; do
  mkdir -p $directory
  chown -R $POLICYAGENT_USERNAME:$POLICYAGENT_USERNAME $directory
  chmod 700 $directory
done

# store directory layout in env file
echo "# $(date)" > $POLICYAGENT_ENV/policyagent-layout
echo "export POLICYAGENT_HOME=$POLICYAGENT_HOME" >> $POLICYAGENT_ENV/policyagent-layout
echo "export POLICYAGENT_CONFIGURATION=$POLICYAGENT_CONFIGURATION" >> $POLICYAGENT_ENV/policyagent-layout
echo "export POLICYAGENT_REPOSITORY=$POLICYAGENT_REPOSITORY" >> $POLICYAGENT_ENV/policyagent-layout
echo "export POLICYAGENT_JAVA=$POLICYAGENT_JAVA" >> $POLICYAGENT_ENV/policyagent-layout
echo "export POLICYAGENT_BIN=$POLICYAGENT_BIN" >> $POLICYAGENT_ENV/policyagent-layout
echo "export POLICYAGENT_LOGS=$POLICYAGENT_LOGS" >> $POLICYAGENT_ENV/policyagent-layout

# store policyagent username in env file
echo "# $(date)" > $POLICYAGENT_ENV/policyagent-username
echo "export POLICYAGENT_USERNAME=$POLICYAGENT_USERNAME" >> $POLICYAGENT_ENV/policyagent-username

# store the auto-exported environment variables in env file
# to make them available after the script uses sudo to switch users;
# we delete that file later
echo "# $(date)" > $POLICYAGENT_ENV/policyagent-setup
for env_file_var_name in $env_file_exports
do
  eval env_file_var_value="\$$env_file_var_name"
  echo "export $env_file_var_name=$env_file_var_value" >> $POLICYAGENT_ENV/policyagent-setup
done

POLICYAGENT_PROPERTIES_FILE=${POLICYAGENT_PROPERTIES_FILE:-"$POLICYAGENT_CONFIGURATION/policyagent.properties"}
touch "$POLICYAGENT_PROPERTIES_FILE"
chown "$POLICYAGENT_USERNAME":"$POLICYAGENT_USERNAME" "$POLICYAGENT_PROPERTIES_FILE"
chmod 600 "$POLICYAGENT_PROPERTIES_FILE"

# load existing environment; set variables will take precendence
load_policyagent_conf
load_policyagent_defaults

## policyagent requires java 1.7 or later
## detect or install java (jdk-1.7.0_51-linux-x64.tar.gz)
#JAVA_REQUIRED_VERSION=${JAVA_REQUIRED_VERSION:-1.7}
#java_detect
#if ! java_ready; then
#  # java not installed, check if we have the bundle
#  JAVA_INSTALL_REQ_BUNDLE=$(ls -1 java-*.bin 2>/dev/null | head -n 1)
#  if [ -n "$JAVA_INSTALL_REQ_BUNDLE" ]; then
#    java_install
#    java_detect
#  fi
#fi
#if ! java_ready_report; then
#  echo_failure "Java $JAVA_REQUIRED_VERSION not found"
#  exit 1
#fi

# make sure unzip and authbind are installed
POLICYAGENT_YUM_PACKAGES="zip unzip authbind"
POLICYAGENT_APT_PACKAGES="zip unzip authbind"
POLICYAGENT_YAST_PACKAGES="zip unzip authbind"
POLICYAGENT_ZYPPER_PACKAGES="zip unzip authbind"
auto_install "Installer requirements" "POLICYAGENT"
if [ $? -ne 0 ]; then echo_failure "Failed to install prerequisites through package installer"; exit -1; fi

# setup authbind to allow non-root policyagent to listen on ports 80 and 443
if [ -n "$POLICYAGENT_USERNAME" ] && [ "$POLICYAGENT_USERNAME" != "root" ] && [ -d /etc/authbind/byport ]; then
  touch /etc/authbind/byport/80 /etc/authbind/byport/443
  chmod 500 /etc/authbind/byport/80 /etc/authbind/byport/443
  chown $POLICYAGENT_USERNAME /etc/authbind/byport/80 /etc/authbind/byport/443
fi

# delete existing java files, to prevent a situation where the installer copies
# a newer file but the older file is also there
if [ -d $POLICYAGENT_HOME/java ]; then
  rm $POLICYAGENT_HOME/java/*.jar
fi

# extract policyagent  (policyagent-zip-0.1-SNAPSHOT.zip)
echo "Extracting application..."
POLICYAGENT_ZIPFILE=`ls -1 policyagent-*.zip 2>/dev/null | head -n 1`
unzip -oq $POLICYAGENT_ZIPFILE -d $POLICYAGENT_HOME

# copy utilities script file to application folder
cp $UTIL_SCRIPT_FILE $POLICYAGENT_HOME/bin/functions.sh

# set permissions
chown -R $POLICYAGENT_USERNAME:$POLICYAGENT_USERNAME $POLICYAGENT_HOME
chmod 755 $POLICYAGENT_HOME/bin/*

# link /usr/local/bin/policyagent -> /opt/policyagent/bin/policyagent
EXISTING_POLICYAGENT_COMMAND=`which policyagent`
if [ -z "$EXISTING_POLICYAGENT_COMMAND" ]; then
  ln -s $POLICYAGENT_HOME/bin/policyagent.sh /usr/local/bin/policyagent
fi


# register linux startup script
register_startup_script $POLICYAGENT_HOME/bin/policyagent.sh policyagent

# setup the policyagent, unless the NOSETUP variable is defined
if [ -z "$POLICYAGENT_NOSETUP" ]; then
  # the master password is required
  if [ -z "$POLICYAGENT_PASSWORD" ]; then
    echo_failure "Master password required in environment variable POLICYAGENT_PASSWORD"
    echo 'To generate a new master password, run the following command:

  POLICYAGENT_PASSWORD=$(policyagent generate-password) && echo POLICYAGENT_PASSWORD=$POLICYAGENT_PASSWORD

The master password must be stored in a safe place, and it must
be exported in the environment for all other policyagent commands to work.

LOSS OF MASTER PASSWORD WILL RESULT IN LOSS OF PROTECTED KEYS AND RELATED DATA

After you set POLICYAGENT_PASSWORD, run the following command to complete installation:

  policyagent setup

'
    exit 1
  fi

  policyagent config mtwilson.extensions.fileIncludeFilter.contains "${MTWILSON_EXTENSIONS_FILEINCLUDEFILTER_CONTAINS:-mtwilson,policyagent}" >/dev/null
  policyagent setup
fi

# delete the temporary setup environment variables file
rm -f $POLICYAGENT_ENV/policyagent-setup

# ensure the policyagent owns all the content created during setup
for directory in $POLICYAGENT_HOME $POLICYAGENT_CONFIGURATION $POLICYAGENT_JAVA $POLICYAGENT_BIN $POLICYAGENT_ENV $POLICYAGENT_REPOSITORY $POLICYAGENT_LOGS; do
  chown -R $POLICYAGENT_USERNAME:$POLICYAGENT_USERNAME $directory
done

# start the server, unless the NOSETUP variable is defined
if [ -z "$POLICYAGENT_NOSETUP" ]; then policyagent start; fi
echo_success "Installation complete"
