#!/bin/bash

# OpenStack controller uninstall script
# Outline:
# 1.  define HOME directory
# 2.  define ENV directory and load application environment variables
# 3.  source functions script
# 4.  define application directory layout
# 5.  remove existing mtwilson monit configuration scripts
# 6.  stop running services
# 7.  delete contents of HOME directory
# 8.  if root:
#     remove startup scripts
#     remove PATH symlinks

#####

# default settings
# note the layout setting is used only by this script
# and it is not saved or used by the app script
export OPENSTACK_EXT_HOME=${OPENSTACK_EXT_HOME:-/opt/openstack-ext}
OPENSTACK_EXT_LAYOUT=${OPENSTACK_EXT_LAYOUT:-home}

# the env directory is not configurable; it is defined as OPENSTACK_EXT_HOME/env and
# the administrator may use a symlink if necessary to place it anywhere else
export OPENSTACK_EXT_ENV=$OPENSTACK_EXT_HOME/env

# load application environment variables if already defined
if [ -d $OPENSTACK_EXT_ENV ]; then
  OPENSTACK_EXT_ENV_FILES=$(ls -1 $OPENSTACK_EXT_ENV/*)
  for env_file in $OPENSTACK_EXT_ENV_FILES; do
    . $env_file
    env_file_exports=$(cat $env_file | grep -E '^[A-Z0-9_]+\s*=' | cut -d = -f 1)
    if [ -n "$env_file_exports" ]; then eval export $env_file_exports; fi
  done
fi

# source functions script
. $OPENSTACK_EXT_HOME/bin/functions.sh

# source patch-util script
. $OPENSTACK_EXT_HOME/bin/patch-util.sh

source $OPENSTACK_EXT_ENV/openstack-ext-layout > /dev/null 2>&1

if [ "$DISTRIBUTION_LOCATION" == "" ]; then
        DISTRIBUTION_LOCATION=$(/usr/bin/python -c "from distutils.sysconfig import get_python_lib; print(get_python_lib())")
fi
echo $DISTRIBUTION_LOCATION

if [ "$OPENSTACK_DASHBOARD_LOCATION" == "" ]; then
	$OPENSTACK_DASHBOARD_LOCATION="/usr/share/openstack-dashboard"
fi
echo "$OPENSTACK_DASHBOARD_LOCATION" 

# define application directory layout
if [ "$OPENSTACK_EXT_LAYOUT" == "linux" ]; then
  export OPENSTACK_EXT_REPOSITORY=${OPENSTACK_EXT_REPOSITORY:-/var/opt/openstack-ext}
elif [ "$OPENSTACK_EXT_LAYOUT" == "home" ]; then
  export OPENSTACK_EXT_REPOSITORY=${OPENSTACK_EXT_REPOSITORY:-$OPENSTACK_EXT_HOME/repository}
fi
export OPENSTACK_EXT_BIN=$OPENSTACK_EXT_HOME/bin

# note that the env dir is not configurable; it is defined as "env" under home
export OPENSTACK_EXT_ENV=$OPENSTACK_EXT_HOME/env

function getFlavour() {
  flavour=""
  grep -c -i ubuntu /etc/*-release > /dev/null
  if [ $? -eq 0 ] ; then
    flavour="ubuntu"
  fi
  grep -c -i "red hat" /etc/*-release > /dev/null
  if [ $? -eq 0 ] ; then
    flavour="rhel"
  fi
  grep -c -i fedora /etc/*-release > /dev/null
  if [ $? -eq 0 ] ; then
    flavour="fedora"
  fi
  grep -c -i suse /etc/*-release > /dev/null
  if [ $? -eq 0 ] ; then
    flavour="suse"
  fi
  grep -c -i centos /etc/*-release > /dev/null
  if [ $? -eq 0 ]; then
    flavour="centos"
  fi
  if [ "$flavour" == "" ] ; then
    echo_failure "Unsupported linux flavor, Supported versions are ubuntu, rhel, fedora, centos and suse"
    exit -1
  else
    echo $flavour
  fi
}

function openstackRestart() {
  if [ "$FLAVOUR" == "ubuntu" ]; then
     if [[ "$NOVA_CONFIG_DIR_LOCATION_PATH" != "" ]]; then
        ps aux | grep python | grep "nova-api" | awk '{print $2}' | xargs kill -9
         nohup nova-api --config-dir /etc/nova/ > /dev/null 2>&1 &
 	ps aux | grep python | grep "nova-cert" | awk '{print $2}' | xargs kill -9
         nohup nova-cert --config-dir /etc/nova/ > /dev/null 2>&1 &
 	ps aux | grep python | grep "nova-consoleauth" | awk '{print $2}' | xargs kill -9
         nohup nova-consoleauth --config-dir /etc/nova/ > /dev/null 2>&1 &
 	ps aux | grep python | grep "nova-scheduler" | awk '{print $2}' | xargs kill -9
         nohup nova-scheduler --config-dir /etc/nova/ > /dev/null 2>&1 &
 	ps aux | grep python | grep "nova-conductor" | awk '{print $2}' | xargs kill -9
         nohup nova-conductor --config-dir /etc/nova/ > /dev/null 2>&1 &
 	ps aux | grep python | grep "nova-novncproxy" | awk '{print $2}' | xargs kill -9
         nohup nova-novncproxy --config-dir /etc/nova/ > /dev/null 2>&1 &
     else
    	service nova-api restart
    	service nova-cert restart
    	service nova-consoleauth restart
    	service nova-scheduler restart
    	service nova-conductor restart
    	service nova-novncproxy restart
     fi
        service apache2 restart
  elif [ "$FLAVOUR" == "rhel" -o "$FLAVOUR" == "fedora" -o "$FLAVOUR" == "suse" ] ; then
     if [[ "$NOVA_CONFIG_DIR_LOCATION_PATH" != "" ]]; then
        ps aux | grep python | grep "nova-api" | awk '{print $2}' | xargs kill -9
         nohup nova-api --config-dir /etc/nova/ > /dev/null 2>&1 &
 	ps aux | grep python | grep "nova-cert" | awk '{print $2}' | xargs kill -9
         nohup nova-cert --config-dir /etc/nova/ > /dev/null 2>&1 &
 	ps aux | grep python | grep "nova-consoleauth" | awk '{print $2}' | xargs kill -9
         nohup nova-consoleauth --config-dir /etc/nova/ > /dev/null 2>&1 &
 	ps aux | grep python | grep "nova-scheduler" | awk '{print $2}' | xargs kill -9
         nohup nova-scheduler --config-dir /etc/nova/ > /dev/null 2>&1 &
 	ps aux | grep python | grep "nova-conductor" | awk '{print $2}' | xargs kill -9
         nohup nova-conductor --config-dir /etc/nova/ > /dev/null 2>&1 &
 	ps aux | grep python | grep "nova-novncproxy" | awk '{print $2}' | xargs kill -9
         nohup nova-novncproxy --config-dir /etc/nova/ > /dev/null 2>&1 &
     else
    	service openstack-nova-api restart
    	service openstack-nova-cert restart
    	service openstack-nova-consoleauth restart
    	service openstack-nova-scheduler restart
    	service openstack-nova-conductor restart
    	service openstack-nova-novncproxy restart
     fi
   	service apache2 restart

  else
    echo_failure "Cannot determine nova controller restart command based on linux flavor"
    exit -1
  fi
}




function getOpenstackVersion() {
   novaManageLocation=`which nova-manage`
  if [ `echo $?` == 0 ] ; then
     version="$(python -c "from nova import version; print version.version_string()")"
  else
     echo_failure "nova-manage does not exist"
     echo_failure "nova compute must be installed"
     exit -1
  fi
  echo $version
}

### PATCH REVERSAL ###
COMPUTE_COMPONENTS="mtwilson-openstack-host-tag-vm"
FLAVOUR=$(getFlavour)
version=$(getOpenstackVersion)

function find_patch() {
  local component=$1
  local version=$2
  local major=$(echo $version | awk -F'.' '{ print $1 }')
  local minor=$(echo $version | awk -F'.' '{ print $2 }')
  local patch=$(echo $version | awk -F'.' '{ print $3 }')
  local patch_suffix=".patch"
  echo "$major $minor $patch"

  if ! [[ $patch =~ ^[0-9]+$ ]]; then
    echo "Will try to find out patch for $major.$minor release"
    patch=""
  fi

  patch_dir=""
  if [ -e $OPENSTACK_EXT_REPOSITORY/$component/$version ]; then
    patch_dir=$OPENSTACK_EXT_REPOSITORY/$component/$version
  elif [ ! -z $patch ]; then
    for i in $(seq $patch -1 0); do
      echo "check for $OPENSTACK_EXT_REPOSITORY/$component/$major.$minor.$i"
      if [ -e $OPENSTACK_EXT_REPOSITORY/$component/$major.$minor.$i ]; then
        patch_dir=$OPENSTACK_EXT_REPOSITORY/$component/$major.$minor.$i
        break
      fi
    done
  fi
  if [ -z $patch_dir ] && [ -e $OPENSTACK_EXT_REPOSITORY/$component/$major.$minor ]; then
    patch_dir=$OPENSTACK_EXT_REPOSITORY/$component/$major.$minor
  fi

  if [ -z $patch_dir ]; then
    echo_failure "Could not find suitable patches for Openstack version $version"
    exit -1
  else
    echo "Applying patches from directory $patch_dir"
  fi
}

for component in $COMPUTE_COMPONENTS; do
  find_patch $component $version
  revert_patch "/" "$patch_dir/root.patch" 1
    if [ $? -ne 0 ]; then
      echo_failure "Error while reverting root patches."
      echo_failure "Continuing with installation. If it fails while applying patches uninstall openstack-ext component and then rerun installer."
    fi
    revert_patch "$DISTRIBUTION_LOCATION/" "$patch_dir/distribution-location.patch" 1
    if [ $? -ne 0 ]; then
      echo_failure "Error while reverting distribution-location patches."
      echo_failure "Continuing with installation. If it fails while applying patches uninstall openstack-ext component and then rerun installer."
    fi
    revert_patch "$OPENSTACK_DASHBOARD_LOCATION/" "$patch_dir/openstack-dashboard.patch" 1
    if [ $? -ne 0 ]; then
      echo_failure "Error while reverting openstack-dashboard patches."
      echo_failure "Continuing with installation. If it fails while applying patches uninstall openstack-ext component and then rerun installer."
    fi
  done

novaConfFile="/etc/nova/nova.conf"
if [ ! -f "$novaConfFile" ]; then
  novaConfFile="$NOVA_CONFIG_DIR_LOCATION_PATH/nova.conf"
fi
# Remove filter entry from config file
sed -i '/^scheduler_default_filters=/ s/,TrustAssertionFilter//g' "$novaConfFile"

openstackRestart

# delete OPENSTACK_EXT_HOME
if [ -d $OPENSTACK_EXT_HOME ]; then
  rm -rf $OPENSTACK_EXT_HOME 2>/dev/null
fi

echo_success "OpenStack controller uninstall complete"

