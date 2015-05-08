#!/bin/sh

# Mtwilson OpenStack Controller Extensions install script
# Outline:
# 1. source the "functions.sh" file:  mtwilson-linux-util-*.sh
# 2. load installer environment file, if present
# 3. force root user installation
# 4. validate input variables and prompt
# 5. read variables from trustagent configuration to input to nova.conf
# 6. update nova.conf
# 7. install prerequisites
# 8. unzip mtwilson-openstack-controller archive mtwilson-openstack-controller-zip-*.zip
# 9. apply openstack extension patches
# 10. sync nova database
# 11. restart openstack services

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

# load installer environment file, if present
if [ -f ~/mtwilson-openstack-controller.env ]; then
  echo "Loading environment variables from $(cd ~ && pwd)/mtwilson-openstack-controller.env"
  . ~/mtwilson-openstack-controller.env
  env_file_exports=$(cat ~/mtwilson-openstack-controller.env | grep -E '^[A-Z0-9_]+\s*=' | cut -d = -f 1)
  if [ -n "$env_file_exports" ]; then eval export $env_file_exports; fi
else
  echo "No environment file"
fi

# enforce root user installation
if [ "$(whoami)" != "root" ]; then
  echo_failure "Running as $(whoami); must install as root"
  exit -1
fi

# validate input variables and prompt
while [ -z "$MTWILSON_SERVER" ]; do
  prompt_with_default MTWILSON_SERVER "Mtwilson Server:" "server_address"
done
while [ -z "$MTWILSON_SERVER_PORT" ]; do
  prompt_with_default MTWILSON_SERVER_PORT "Mtwilson Server Port:" "8443"
done
while [ -z "$MTWILSON_ASSET_TAG_API_USERNAME" ]; do
  prompt_with_default MTWILSON_ASSET_TAG_API_USERNAME "Mtwilson Asset Tag API Username:" "tagadmin"
done
while [ -z "$MTWILSON_ASSET_TAG_API_PASSWORD" ]; do
  prompt_with_default_password MTWILSON_ASSET_TAG_API_PASSWORD "Mtwilson Asset Tag API Password:" "$MTWILSON_ASSET_TAG_API_PASSWORD"
done
mtwilsonAssetTagAuthBlob="$MTWILSON_ASSET_TAG_API_USERNAME:$MTWILSON_ASSET_TAG_API_PASSWORD"

# update openstack-dashboard settings.py
openstackDashboardSettingsFile="/usr/share/openstack-dashboard/openstack_dashboard/settings.py"
if [ ! -f "$openstackDashboardSettingsFile" ]; then
  echo_failure "Could not find $openstackDashboardSettingsFile"
  echo_failure "OpenStack controller must be installed first"
  exit -1
fi
assetTagServiceExistsInSettingsFile=$(grep '^ASSET_TAG_SERVICE = {$' "$openstackDashboardSettingsFile")
if [ -n "$assetTagServiceExistsInSettingsFile" ]; then
  sed -i '/^ASSET_TAG_SERVICE = {/,/^}/d' "$openstackDashboardSettingsFile"
fi

sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' -i "$openstackDashboardSettingsFile" #remove empty lines at EOF
echo -e "\n" >> "$openstackDashboardSettingsFile"
echo "ASSET_TAG_SERVICE = {" >> "$openstackDashboardSettingsFile"
echo "    'IP': '$MTWILSON_SERVER'," >> "$openstackDashboardSettingsFile"
echo "    'port': '$MTWILSON_SERVER_PORT'," >> "$openstackDashboardSettingsFile"
echo "    'certificate_url': '/certificate-requests'," >> "$openstackDashboardSettingsFile"
echo "    'auth_blob': '$mtwilsonAssetTagAuthBlob'," >> "$openstackDashboardSettingsFile"
echo "    'api_url': '/mtwilson/v2/host-attestations'," >> "$openstackDashboardSettingsFile"
echo "    'host_url': '/mtwilson/v2/hosts'," >> "$openstackDashboardSettingsFile"
echo "    'tags_url': '/mtwilson/v2/tag-kv-attributes.json?filter=false'" >> "$openstackDashboardSettingsFile"
echo "}" >> "$openstackDashboardSettingsFile"

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
  echo_failure "OpenStack controller must be installed first"
  exit -1
fi
updateNovaConf "attestation_server" "$MTWILSON_SERVER" "trusted_computing" "$novaConfFile"
updateNovaConf "attestation_port" "$MTWILSON_SERVER_PORT" "trusted_computing" "$novaConfFile"
updateNovaConf "attestation_auth_blob" "$mtwilsonAssetTagAuthBlob" "trusted_computing" "$novaConfFile"
updateNovaConf "attestation_api_url" "/mtwilson/v2/host-attestations" "trusted_computing" "$novaConfFile"
updateNovaConf "attestation_host_url" "/mtwilson/v2/hosts" "trusted_computing" "$novaConfFile"
updateNovaConf "attestation_server_ca_file" "/etc/nova/ssl.crt" "trusted_computing" "$novaConfFile"
updateNovaConf "scheduler_driver" "nova.scheduler.filter_scheduler.FilterScheduler" "DEFAULT" "$novaConfFile"

updateNovaConf "scheduler_default_filters" "RamFilter,ComputeFilter,TrustAssertionFilter" "DEFAULT" "$novaConfFile"

# make sure unzip and authbind are installed
MTWILSON_OPENSTACK_YUM_PACKAGES="zip unzip"
MTWILSON_OPENSTACK_APT_PACKAGES="zip unzip"
MTWILSON_OPENSTACK_YAST_PACKAGES="zip unzip"
MTWILSON_OPENSTACK_ZYPPER_PACKAGES="zip unzip"
auto_install "Installer requirements" "MTWILSON_OPENSTACK"
if [ $? -ne 0 ]; then echo_failure "Failed to install prerequisites through package installer"; exit -1; fi

# extract mtwilson-openstack-controller  (mtwilson-openstack-controller-zip-0.1-SNAPSHOT.zip)
echo "Extracting application..."
MTWILSON_OPENSTACK_ZIPFILE=`ls -1 mtwilson-openstack-controller-*.zip 2>/dev/null | head -n 1`
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
      target=$(echo $file | cut -c2-)
      targetMd5=$(md5sum $target 2>/dev/null | awk '{print $1}')
      sourceMd5=$(md5sum $file | awk '{print $1}')
      if [ "$targetMd5" == "$sourceMd5" ] ; then
        echo "$file md5sum matched, skipping patch"
      else
        if [ -f "$target" ]; then
          echo "Patching file: $target"
          mv $target $target.mh.bak
        else
          echo "Creating file: $target"
        fi
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

# remove trusted_filter.py if exists
trusted_filter.py

### Apply patches
COMPUTE_COMPONENTS="mtwilson-openstack-asset-tag"
FLAVOUR=$(getFlavour)
DISTRIBUTION_LOCATION=$(getDistributionLocation)
version=$(getOpenstackVersion)
for component in $COMPUTE_COMPONENTS; do
  applyPatches $component $version
done

find /usr/share/openstack-dashboard/ -name "*.pyc" -delete
find $DISTRIBUTION_LOCATION/novaclient -name "*.pyc" -delete
find $DISTRIBUTION_LOCATION/nova -name "*.pyc" -delete

echo "Syncing nova database"
if [ -d /var/log/nova ]	; then
  chown -R nova:nova /var/log/nova
fi
su -s /bin/sh -c "nova-manage db sync" nova

if [ -d /var/log/nova ] ; then
  chown -R nova:nova /var/log/nova
fi

openstackRestart

echo_success "OpenStack Controller Extensions Installation complete"
