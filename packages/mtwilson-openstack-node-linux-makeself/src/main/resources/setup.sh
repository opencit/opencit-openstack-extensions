#!/bin/sh

# Mtwilson OpenStack Node Extensions install script
# Outline:
# 1. source the "functions.sh" file:  mtwilson-linux-util-*.sh
# 2. force root user installation
# 3. read variables from trustagent configuration to input to nova.conf
# 4. update nova.conf
# 5. install prerequisites
# 6. unzip mtwilson-openstack-node archive mtwilson-openstack-node-zip-*.zip
# 7. apply openstack extension patches
# 8. check for policyagent
# 9. rootwrap: add policyagent to compute.filters
# 10. rootwrap: ensure /usr/local/bin is defined in exec_dirs variable in rootwrap.conf
# 11. rootwrap: add nova to sudoers list

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

# read variables from trustagent configuration to input to nova.conf
trustagentHomeDir="/opt/trustagent"
trustagentConfDir="$trustagentHomeDir/configuration"
trustagentPropertiesFile="$trustagentConfDir/trustagent.properties"
if [ ! -f "$trustagentPropertiesFile" ]; then
  echo_failure "Could not find $trustagentPropertiesFile"
  echo_failure "Mtwilson Trust Agent must be installed first"
  exit -1
fi
mtwilsonServer=$(read_property_from_file "mtwilson.api.url" "$trustagentPropertiesFile" | awk -F'/' '{print $3}' | awk -F':' '{print $1}' | tr -d '\\')
if [ -z "$mtwilsonServer" ]; then
  echo_failure "Error reading Mtwilson server from configuration"
  exit -1
fi
mtwilsonServerPort=$(read_property_from_file "mtwilson.api.url" "$trustagentPropertiesFile" | awk -F'/' '{print $3}' | awk -F':' '{print $2}')
if [ -z "$mtwilsonServerPort" ]; then
  echo_failure "Error reading Mtwilson server port from configuration"
  exit -1
fi
mtwilsonVmAttestationApiUsername=$(read_property_from_file "mtwilson.api.username" "$trustagentPropertiesFile")
if [ -z "$mtwilsonVmAttestationApiUsername" ]; then
  echo_failure "Error reading Mtwilson VM attestation API username from configuration"
  exit -1
fi
mtwilsonVmAttestationApiPassword=$(read_property_from_file "mtwilson.api.password" "$trustagentPropertiesFile")
if [ -z "$mtwilsonVmAttestationApiPassword" ]; then
  echo_failure "Error reading Mtwilson VM attestation API password from configuration"
  exit -1
fi
mtwilsonVmAttestationApiUrlPath="/mtwilson/v2/vm-attestations"
mtwilsonVmAttestationAuthBlob="'$mtwilsonVmAttestationApiUsername:$mtwilsonVmAttestationApiPassword'"

# update nova.conf
novaConfFile="/etc/nova/nova.conf"
if [ ! -f "$novaConfFile" ]; then
  echo_failure "Could not find $novaConfFile"
  echo_failure "OpenStack compute node must be installed first"
  exit -1
fi
novaConfTrustedComputingExists=$(grep '^\[trusted_computing\]$' "$novaConfFile")
if [ -n "$novaConfTrustedComputingExists" ]; then
  update_property_in_file "attestation_server_ip" "$novaConfFile" "$mtwilsonServer"
  update_property_in_file "attestation_server_port" "$novaConfFile" "$mtwilsonServerPort"
  update_property_in_file "attestation_api_url" "$novaConfFile" "$mtwilsonVmAttestationApiUrlPath"
  update_property_in_file "attestation_auth_blob" "$novaConfFile" "$mtwilsonVmAttestationAuthBlob"
else
  echo -e "\n" >> "$novaConfFile"
  echo "# Intel(R) Cloud Integrity Technology" >> "$novaConfFile"
  echo "[trusted_computing]" >> "$novaConfFile"
  echo "attestation_server_ip=$mtwilsonServer" >> "$novaConfFile"
  echo "attestation_server_port=$mtwilsonServerPort" >> "$novaConfFile"
  echo "attestation_api_url=$mtwilsonVmAttestationApiUrlPath" >> "$novaConfFile"
  echo "attestation_auth_blob=$mtwilsonVmAttestationAuthBlob" >> "$novaConfFile"
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
    service nova-api-metadata restart
    service nova-network restart
    service nova-compute restart
  elif [ "$FLAVOUR" == "rhel" -o "$FLAVOUR" == "fedora" -o "$FLAVOUR" == "suse" ] ; then
    service openstack-nova-api-metadata restart
    service openstack-nova-network restart
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
COMPUTE_COMPONENTS="mtwilson-openstack-policyagent-hooks mtwilson-openstack-asset-tag"
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

# Check for policyagent
if [ ! -x  /usr/local/bin/policyagent ]; then
  echo_failure "Could not find policyagent"
  exit -1
fi

# rootwrap compute.filters
computeFiltersFile="/etc/nova/rootwrap.d/compute.filters"
if [ ! -f "$computeFiltersFile" ]; then
  computeFiltersFile="/usr/share/nova/rootwrap/compute.filters"
fi
if [ ! -f "$computeFiltersFile" ]; then
  echo_failure "Could not find $computeFiltersFile"
  exit -1
fi
computeFiltersPolicyagentExists=$(grep '^policyagent:' "$computeFiltersFile")
if [ -n "$computeFiltersPolicyagentExists" ]; then
  sed -i 's/^policyagent:.*/policyagent: CommandFilter, \/usr\/local\/bin\/policyagent, root/g' "$computeFiltersFile"
else
  echo "policyagent: CommandFilter, /usr/local/bin/policyagent, root" >> "$computeFiltersFile"
fi

# rootwrap.conf
rootwrapConfFile="/etc/nova/rootwrap.conf"
if [ ! -f "$rootwrapConfFile" ]; then
  echo_failure "Could not find $rootwrapConfFile"
  exit -1
fi
rootwrapConfExecDirsExists=$(grep '^exec_dirs=' "$rootwrapConfFile")
if [ -n "$rootwrapConfExecDirsExists" ]; then
  rootwrapConfAlreadyHasLocalBin=$(echo "$rootwrapConfExecDirsExists" | grep '/usr/local/bin')
  if [ -z "$rootwrapConfAlreadyHasLocalBin" ]; then
    sed -i '/^exec_dirs=/ s/$/,\/usr\/local\/bin/g' "$rootwrapConfFile"
  fi
else
  echo "exec_dirs=/usr/local/bin" >> "$rootwrapConfFile"
fi

# add nova to sudoers
etcSudoersFile="/etc/sudoers"
if [ ! -f "$etcSudoersFile" ]; then
  echo_failure "Could not find $etcSudoersFile"
  exit -1
fi
etcSudoersNovaExists=$(grep $'^nova\s' "$etcSudoersFile")
if [ -n "$etcSudoersNovaExists" ]; then
  sed -i 's/^nova\s.*/nova ALL = (root) NOPASSWD: \/usr\/bin\/nova-rootwrap '$(sed_escape "$rootwrapConfFile")' \*/g' "$etcSudoersFile"
else
  echo "nova ALL = (root) NOPASSWD: /usr/bin/nova-rootwrap /etc/nova/rootwrap.conf *" >> "$etcSudoersFile"
fi

#chown -R nova:nova /var/run/libvirt/
#chmod 777 /var/run/libvirt/libvirt-sock

openstackRestart

echo_success "OpenStack Compute Node Extensions Installation complete"
