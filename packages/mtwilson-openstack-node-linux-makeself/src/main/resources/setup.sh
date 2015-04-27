#!/bin/sh

# Mtwilson OpenStack Node Extensions install script
# Outline:
# 1.  source the "functions.sh" file:  mtwilson-linux-util-*.sh
# 2.  force root user installation
# 3.  install prerequisites
# 4. unzip mtwilson-openstack-node archive mtwilson-openstack-node-zip-*.zip
# 5. apply openstack extension patches

#####

# functions script (mtwilson-linux-util-3.0-SNAPSHOT.sh) is required
# we use the following functions:
# java_detect java_ready_report 
# echo_failure echo_warning
# register_startup_script
UTIL_SCRIPT_FILE=$(ls -1 mtwilson-linux-util-*.sh | head -n 1)
if [ -n "$UTIL_SCRIPT_FILE" ] && [ -f "$UTIL_SCRIPT_FILE" ]; then
  . $UTIL_SCRIPT_FILE
fi

## load installer environment file, if present
#if [ -f ~/mtwilson-openstack-node.env ]; then
#  echo "Loading environment variables from $(cd ~ && pwd)/mtwilson-openstack-node.env"
#  . ~/mtwilson-openstack-node.env
#  env_file_exports=$(cat ~/mtwilson-openstack-node.env | grep -E '^[A-Z0-9_]+\s*=' | cut -d = -f 1)
#  if [ -n "$env_file_exports" ]; then eval export $env_file_exports; fi
#else
#  echo "No environment file"
#fi

# enforce root user installation
if [ "$(whoami)" != "root" ]; then
  echo_failure "Running as $(whoami); must install as root"
  exit -1
fi

# make sure unzip and authbind are installed
MTWILSON_OPENSTACK_YUM_PACKAGES="zip unzip"
MTWILSON_OPENSTACK_APT_PACKAGES="zip unzip"
MTWILSON_OPENSTACK_YAST_PACKAGES="zip unzip"
MTWILSON_OPENSTACK_ZYPPER_PACKAGES="zip unzip"
auto_install "Installer requirements" "MTWILSON_OPENSTACK"
if [ $? -ne 0 ]; then echo_failure "Failed to install prerequisites through package installer"; exit -1; fi

# extract mtwilson-openstack-node  (mtwilson-openstack-node-zip-0.1-SNAPSHOT.zip)
echo "Extracting application..."
MTWILSON_OPENSTACK_ZIPFILE=`ls -1 mtwilson-openstack-node-*.zip 2>/dev/null | head -n 1`
unzip -oq $MTWILSON_OPENSTACK_ZIPFILE

### OpenStack Extensions methods
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
  if [ "$flavour" == "" ] ; then
    echo_failure "Unsupported linux flavor, Supported versions are ubuntu, rhel, fedora"
    exit -1
  else
    echo $flavour
  fi
}
function openstackRestart() {
  if [ "$FLAVOUR" == "ubuntu" ]; then
    service nova-compute restart
  elif [ "$FLAVOUR" == "rhel" -o "$FLAVOUR" == "fedora" -o "$FLAVOUR" == "suse" ] ; then
    service openstack-nova-compute restart
  else
    echo_failure "Cannot determine nova compute restart command based on linux flavor"
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
function getDistributionLocation() {
  DISTRIBUTION_LOCATION=$(/usr/bin/python -c "from distutils.sysconfig import get_python_lib; print(get_python_lib())")
  if [ $? -ne 0 ]; then echo_failure "Failed to determine distribution location"; echo_failure "Check nova compute configuration"; exit -1; fi
  echo $DISTRIBUTION_LOCATION
}
function applyPatches() {
  component=$1
  version=$2
  echo "Applying patch for $component and $version"
  if [ -d $component/$version ]; then
    cd $component/$version
    listOfFiles=$(find . -type f)
    for file in $listOfFiles; do
      # This is an anomaly and might go away with later 
      # Openstack versions anomaly is openstack-dashboard does not lie
      # in standard dist packages
      if [ $component == "openstack-dashboard" ] ; then
        target=$(echo $file | cut -c2-)
      else
        target=$(echo $DISTRIBUTION_LOCATION/$file)
      fi
      targetMd5=$(md5sum $target | awk '{print $1}')
      sourceMd5=$(md5sum $file | awk '{print $1}')
      if [ $targetMd5 == $sourceMd5 ] ; then
        echo "$file md5sum matched, skipping patch"
      else
        echo "Patching file: $target"
        mv $target $target.mh.bak
        cp $file $target
      fi
    done
    cd -
  else
    echo_failure "ERROR: Could not find the patch for $component and $version"
    echo_failure "Patches are supported only for the following versions"
    echo $(ls $component)
    exit -1
  fi
}

### Apply patches
COMPUTE_COMPONENTS="mtwilson-openstack-policyagent-hooks"
FLAVOUR=$(getFlavour)
DISTRIBUTION_LOCATION=$(getDistributionLocation)
for component in $COMPUTE_COMPONENTS; do
  version=$(getOpenstackVersion)
  applyPatches $component $version
done

find $DISTRIBUTION_LOCATION/nova -name "*.pyc" -delete
if [ -d /var/log/nova ] ; then
  chown -R nova:nova /var/log/nova
fi
openstackRestart

# Check for policyagent
if [ ! -x  /usr/local/bin/policyagent ]; then
  echo_failure "Could not find policyagent"
  exit -1
fi

echo_success "Installation complete"
