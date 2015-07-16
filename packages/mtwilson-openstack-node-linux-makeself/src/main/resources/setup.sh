#!/bin/sh

# Mtwilson OpenStack Node Extensions install script
# Outline:
# 1. load existing environment configuration
# 2. source the "functions.sh" file:  mtwilson-linux-util-*.sh
# 3. look for ~/mtwilson-openstack-node.env and source it if it's there
# 4. force root user installation
# 5. read variables from trustagent configuration to input to nova.conf
# 6. update nova.conf
# 7. install prerequisites
# 8. unzip mtwilson-openstack-node archive mtwilson-openstack-node-zip-*.zip
# 9. apply openstack extension patches
# 10. check for policyagent
# 11. rootwrap: add policyagent to compute.filters
# 12. rootwrap: ensure /usr/local/bin is defined in exec_dirs variable in rootwrap.conf
# 13. rootwrap: add nova to sudoers list

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


# functions script (mtwilson-linux-util-3.0-SNAPSHOT.sh) is required
# we use the following functions:
# java_detect java_ready_report 
# echo_failure echo_warning
# register_startup_script
UTIL_SCRIPT_FILE=$(ls -1 mtwilson-linux-util-*.sh | head -n 1)
if [ -n "$UTIL_SCRIPT_FILE" ] && [ -f "$UTIL_SCRIPT_FILE" ]; then
  . $UTIL_SCRIPT_FILE
fi

PATCH_UTIL_SCRIPT_FILE=$(ls -1 mtwilson-linux-patch-util-*.sh | head -n 1)
if [ -n "$PATCH_UTIL_SCRIPT_FILE" ] && [ -f "$PATCH_UTIL_SCRIPT_FILE" ]; then
  . $PATCH_UTIL_SCRIPT_FILE
fi


## load installer environment file, if present
if [ -f ~/mtwilson-openstack-node.env ]; then
  echo "Loading environment variables from $(cd ~ && pwd)/mtwilson-openstack-node.env"
  . ~/mtwilson-openstack-node.env
  env_file_exports=$(cat ~/mtwilson-openstack-node.env | grep -E '^[A-Z0-9_]+\s*=' | cut -d = -f 1)
  if [ -n "$env_file_exports" ]; then eval export $env_file_exports; fi
else
  echo "No environment file"
fi

if [ "$OPENSTACK_EXT_LAYOUT" == "linux" ]; then
  export OPENSTACK_EXT_REPOSITORY=${OPENSTACK_EXT_REPOSITORY:-/var/opt/openstack-ext}
elif [ "$OPENSTACK_EXT_LAYOUT" == "home" ]; then
  export OPENSTACK_EXT_REPOSITORY=${OPENSTACK_EXT_REPOSITORY:-$OPENSTACK_EXT_HOME/repository}
fi
export OPENSTACK_EXT_BIN=$OPENSTACK_EXT_HOME/bin

for directory in $OPENSTACK_EXT_REPOSITORY $OPENSTACK_EXT_BIN; do
  mkdir -p $directory
  chmod 700 $directory
done

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

function openstack_update_property_in_file() {
  local property="${1}"
  local filename="${2}"
  local value="${3}"

  if [ -f "$filename" ]; then
    local ispresent=$(grep "^${property}" "$filename")
    if [ -n "$ispresent" ]; then
      # first escape the pipes new value so we can use it with replacement command, which uses pipe | as the separator
      local escaped_value=$(echo "${value}" | sed 's/|/\\|/g')
      local sed_escaped_value=$(sed_escape "$escaped_value")
      # replace just that line in the file and save the file
      updatedcontent=`sed -re "s|^(${property})\s*=\s*(.*)|\1=${sed_escaped_value}|" "${filename}"`
      # protect against an error
      if [ -n "$updatedcontent" ]; then
        echo "$updatedcontent" > "${filename}"
      else
        echo_warning "Cannot write $property to $filename with value: $value"
        echo -n 'sed -re "s|^('
        echo -n "${property}"
        echo -n ')=(.*)|\1='
        echo -n "${escaped_value}"
        echo -n '|" "'
        echo -n "${filename}"
        echo -n '"'
        echo
      fi
    else
      # property is not already in file so add it. extra newline in case the last line in the file does not have a newline
      echo "" >> "${filename}"
      echo "${property}=${value}" >> "${filename}"
    fi
  else
    # file does not exist so create it
    echo "${property}=${value}" > "${filename}"
  fi
}

function updateNovaConf() {
  local property="$1"
  local value="$2"
  local header="$3"
  local novaConfFile="$4"

  if [ "$#" -ne 4 ]; then
    echo_failure "Usage: updateNovaConf [PROPERTY] [VALUE] [HEADER] [NOVA_CONF_FILE_PATH]"
    return -1
  fi

  local headerExists=$(grep '^\['${header}'\]$' "$novaConfFile")
  if [ -z "$headerExists" ]; then
    sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' -i "$novaConfFile" #remove empty lines at EOF
    echo -e "\n" >> "$novaConfFile"
    echo "# Intel(R) Cloud Integrity Technology" >> "$novaConfFile"
    echo "[${header}]" >> "$novaConfFile"
    echo -e "\n" >> "$novaConfFile"
  fi

  sed -i 's/^[#]*\('"$property"'=.*\)$/\1/' "$novaConfFile"   # remove comment '#'
  local propertyExists=$(grep '^'"$property"'=.*$' "$novaConfFile")
  if [ -n "$propertyExists" ]; then
    openstack_update_property_in_file "$property" "$novaConfFile" "$value"
  else
    # insert at end of header block
    sed -e '/^\['${header}'\]/{:a;n;/^$/!ba;i\'${property}'='${value} -e '}' -i "$novaConfFile"
  fi
}

# update nova.conf
novaConfFile="/etc/nova/nova.conf"
if [ ! -f "$novaConfFile" ]; then
  echo_failure "Could not find $novaConfFile"
  echo_failure "OpenStack compute node must be installed first"
  exit -1
fi
updateNovaConf "attestation_server_ip" "$mtwilsonServer" "trusted_computing" "$novaConfFile"
updateNovaConf "attestation_server_port" "$mtwilsonServerPort" "trusted_computing" "$novaConfFile"
updateNovaConf "attestation_api_url" "$mtwilsonVmAttestationApiUrlPath" "trusted_computing" "$novaConfFile"
updateNovaConf "attestation_auth_blob" "$mtwilsonVmAttestationAuthBlob" "trusted_computing" "$novaConfFile"

# make sure unzip and authbind are installed
MTWILSON_OPENSTACK_YUM_PACKAGES="zip unzip patchutils"
MTWILSON_OPENSTACK_APT_PACKAGES="zip unzip patchutils"
MTWILSON_OPENSTACK_YAST_PACKAGES="zip unzip patchutils"
MTWILSON_OPENSTACK_ZYPPER_PACKAGES="zip unzip patchutils"
auto_install "Installer requirements" "MTWILSON_OPENSTACK"
if [ $? -ne 0 ]; then echo_failure "Failed to install prerequisites through package installer"; exit -1; fi

# extract mtwilson-openstack-node  (mtwilson-openstack-node-zip-0.1-SNAPSHOT.zip)
echo "Extracting application..."
MTWILSON_OPENSTACK_ZIPFILES=`ls -1 mtwilson-openstack-node-*.zip 2>/dev/null`
for MTWILSON_OPENSTACK_ZIPFILE in $MTWILSON_OPENSTACK_ZIPFILES; do
  echo "Extract $MTWILSON_OPENSTACK_ZIPFILE"
  unzip -oq $MTWILSON_OPENSTACK_ZIPFILE -d $OPENSTACK_EXT_REPOSITORY
done

# copy utilities script file to application folder
cp $UTIL_SCRIPT_FILE $OPENSTACK_EXT_HOME/bin/functions.sh
cp $PATCH_UTIL_SCRIPT_FILE $OPENSTACK_EXT_HOME/bin/patch-util.sh


# set permissions
chmod 700 $OPENSTACK_EXT_HOME/bin/*.sh

cd $OPENSTACK_EXT_REPOSITORY

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
    service openstack-nova-metadata-api restart
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
  version=$(getOpenstackVersion).patch
  #applyPatches $component $version
  apply_patch $DISTRIBUTION_LOCATION $OPENSTACK_EXT_REPOSITORY/$component/$version 1
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

# rootwrap.conf
rootwrapConfFile="/etc/nova/rootwrap.conf"
if [ ! -f "$rootwrapConfFile" ]; then
  echo_failure "Could not find $rootwrapConfFile"
  exit -1
fi

# rootwrap compute.filters
for computeFiltersDir in `grep filters_path $rootwrapConfFile | awk 'BEGIN{FS="="}{print $2}' | sed 's/,/ /g'`
do
       if [ -f "$computeFiltersDir"/compute.filters ] ; then
               export computeFiltersFile="$computeFiltersDir"/compute.filters
               echo "Using compute.filters at $computeFiltersFile"
               break
       fi
done

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
