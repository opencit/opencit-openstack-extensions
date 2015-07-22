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
    # from Openstack_applyPatches.sh; necessary?
    service nova-compute restart
    service nova-api restart
    service nova-cert restart
    service nova-consoleauth restart
    service nova-scheduler restart
    service nova-conductor restart
    service nova-novncproxy restart
    service nova-network restart

    # from Naresh's instructions
    #service nova-api restart
    #service nova-scheduler restart
    service apache2 restart
  elif [ "$FLAVOUR" == "rhel" -o "$FLAVOUR" == "fedora" -o "$FLAVOUR" == "suse" ] ; then
    # from Openstack_applyPatches.sh; necessary?
    service openstack-nova-compute restart
    service openstack-nova-api restart
    service openstack-nova-cert restart
    service openstack-nova-consoleauth restart
    service openstack-nova-scheduler restart
    service openstack-nova-conductor restart
    service openstack-nova-novncproxy restart
    service openstack-nova-network restart

    # from Naresh's instructions
    #service openstack-nova-api restart
    #service openstack-nova-scheduler restart
    service apache2 restart
  else
    echo_failure "Cannot determine nova controller restart command based on linux flavor"
    exit -1
  fi
}

function getOpenstackVersion() {
  if [ -x /usr/bin/nova-manage ] ; then
    version=$(/usr/bin/nova-manage --version 2>&1)
  else
    echo_failure "/usr/bin/nova-manage does not exist"
    echo_failure "nova compute must be installed"
    exit -1
  fi
  echo $version
}

### PATCH REVERSAL ###
COMPUTE_COMPONENTS="mtwilson-openstack-asset-tag"
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

  patch_file=""
  if [ -e $OPENSTACK_EXT_REPOSITORY/$component/$version$patch_suffix ]; then
    patch_file=$OPENSTACK_EXT_REPOSITORY/$component/$version$patch_suffix
  elif [ ! -z $patch ]; then
    for i in $(seq $patch -1 0); do
      echo "check for $OPENSTACK_EXT_REPOSITORY/$component/$major.$minor.$i$patch_suffix"
      if [ -e $OPENSTACK_EXT_REPOSITORY/$component/$major.$minor.$i$patch_suffix ]; then
        patch_file=$OPENSTACK_EXT_REPOSITORY/$component/$major.$minor.$i$patch_suffix
        break
      fi
    done
  fi
  if [ -z $patch_file ] && [ -e $OPENSTACK_EXT_REPOSITORY/$component/$major.$minor$patch_suffix ]; then
    patch_file=$OPENSTACK_EXT_REPOSITORY/$component/$major.$minor$patch_suffix
  fi

  if [ -z $patch_file ]; then
    echo_failure "Could not find suitable patches for Openstack version $version"
    exit -1
  else
    echo "Applying patches from file $patch_file"
  fi
}

for component in $COMPUTE_COMPONENTS; do
  find_patch $component $version
  revert_patch "/" $patch_file 1
  if [ $? -ne 0 ]; then
    echo_failure "Error while reverting patches."
    exit -1
  fi
done

novaConfFile="/etc/nova/nova.conf"
# Remove filter entry from config file
sed -i '/^scheduler_default_filters=/ s/,TrustAssertionFilter//g' "$novaConfFile"

openstackRestart

# delete OPENSTACK_EXT_HOME
if [ -d $OPENSTACK_EXT_HOME ]; then
  rm -rf $OPENSTACK_EXT_HOME 2>/dev/null
fi

echo_success "OpenStack controller uninstall complete"








