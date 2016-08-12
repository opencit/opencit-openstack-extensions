#!/bin/sh

# Mtwilson OpenStack Controller Extensions install script
# Outline:
# 1. load existing environment configuration
# 2. source the "functions.sh" file:  mtwilson-linux-util-*.sh
# 2. load installer environment file, if present
# 3. force root user installation
# 4. validate input variables and prompt
# 5. read variables from trustagent configuration to input to nova.conf
# 6. update nova.conf
# 7. install prerequisites
# 8. unzip mtwilson-openstack-controller archive mtwilson-openstack-controller-zip-*.zip
# 9. apply openstack extension patches
# 10. remove trusted_filter.py if exists
# 11. sync nova database
# 12. restart openstack services

#####

# default settings
# note the layout setting is used only by this script
# and it is not saved or used by the app script
DISTRIBUTION_LOCATION=""
NOVA_CONFIG_DIR_LOCATION_PATH=""
OPENSTACK_DASHBOARD_LOCATION=""
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
UNINSTALL_SCRIPT_FILE=$(ls -1 mtwilson-openstack-controller-uninstall.sh | head -n 1)

# load installer environment file, if present
if [ -f ~/mtwilson-openstack-controller.env ]; then
  echo "Loading environment variables from $(cd ~ && pwd)/mtwilson-openstack-controller.env"
  . ~/mtwilson-openstack-controller.env
  env_file_exports=$(cat ~/mtwilson-openstack-controller.env | grep -E '^[A-Z0-9_]+\s*=' | cut -d = -f 1)
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

for directory in $OPENSTACK_EXT_REPOSITORY $OPENSTACK_EXT_BIN $OPENSTACK_EXT_ENV; do
  mkdir -p $directory
  chmod 700 $directory
done


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
while [ -z "$MTWILSON_TLS_CERT_SHA1" ]; do
  prompt_with_default_password MTWILSON_TLS_CERT_SHA1 "Mtwilson Server TLS Certificate SHA1:" "$MTWILSON_TLS_CERT_SHA1"
done
while [ -z "$MTWILSON_ASSET_TAG_API_USERNAME" ]; do
  prompt_with_default MTWILSON_ASSET_TAG_API_USERNAME "Mtwilson Asset Tag API Username:" "tagadmin"
done
while [ -z "$MTWILSON_ASSET_TAG_API_PASSWORD" ]; do
  prompt_with_default_password MTWILSON_ASSET_TAG_API_PASSWORD "Mtwilson Asset Tag API Password:" "$MTWILSON_ASSET_TAG_API_PASSWORD"
done
mtwilsonAssetTagAuthBlob="$MTWILSON_ASSET_TAG_API_USERNAME:$MTWILSON_ASSET_TAG_API_PASSWORD"

# set mtwilson ca certificate paths
mtwilsonServerCaFile="/etc/nova/as-ssl.crt"
mtwilsonServerCaFilePem="${mtwilsonServerCaFile}.pem"

# file operations
mkdir -p $(dirname ${mtwilsonServerCaFile})
rm -f ${mtwilsonServerCaFile}
rm -f ${mtwilsonServerCaFilePem}

# download mtwilson server ssl cert
openssl s_client -showcerts -connect ${MTWILSON_SERVER}:${MTWILSON_SERVER_PORT} </dev/null 2>/dev/null | openssl x509 -outform DER > ${mtwilsonServerCaFile}

# take the sha1 of the downloaded mtwilson server ssl cert
measured_server_tls_cert_sha1=$(sha1sum ${mtwilsonServerCaFile} 2>/dev/null | cut -f1 -d " ")

# compare the mtwilson server measure ssl cert sha1 to the value defined in the trustagent config
if [ "${MTWILSON_TLS_CERT_SHA1}" != "${measured_server_tls_cert_sha1}" ]; then
  echo "SHA1 of downloaded SSL certificate [${measured_server_tls_cert_sha1}] does not match the expected value [${MTWILSON_TLS_CERT_SHA1}]"
  rm -f ${mtwilsonServerCaFile}
  rm -f ${mtwilsonServerCaFilePem}
  exit -1
fi

# convert DER to PEM formatted cert
openssl x509 -inform der -in ${mtwilsonServerCaFile} -out ${mtwilsonServerCaFilePem}
chown nova:nova ${mtwilsonServerCaFilePem}

# update openstack-dashboard settings.py
if [ "$OPENSTACK_DASHBOARD_LOCATION" == "" ]; then
 OPENSTACK_DASHBOARD_LOCATION="/usr/share/openstack-dashboard"
fi

# copy mtwilson ca certificate to path accessible by apache2 server and set ownership and permission
apache2MtwilsonServerCaFilePem="${OPENSTACK_DASHBOARD_LOCATION}/openstack_dashboard/conf/as-ssl.crt.pem"
rm -f ${apache2MtwilsonServerCaFilePem}
cp ${mtwilsonServerCaFilePem} ${apache2MtwilsonServerCaFilePem}
chmod 644 ${apache2MtwilsonServerCaFilePem}

openstackDashboardSettingsFile="$OPENSTACK_DASHBOARD_LOCATION/openstack_dashboard/settings.py"
if [ ! -f "$openstackDashboardSettingsFile" ]; then
  openstackDashboardSettingsFile="/usr/share/openstack-dashboard/openstack_dashboard/settings.py"
fi
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
echo "    'tags_url': '/mtwilson/v2/tag-kv-attributes.json?filter=false'," >> "$openstackDashboardSettingsFile"
echo "    'attestation_server_ca_file': '$apache2MtwilsonServerCaFilePem'" >> "$openstackDashboardSettingsFile"
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
    echo -e "\n" >> "$novaConfFile"
  fi

  sed -i 's/^[#]*\('"$property"'=.*\)$/\1/' "$novaConfFile"   # remove comment '#'
  local propertyExists=$(grep '^'"$property"'=.*$' "$novaConfFile")
  if [ -n "$propertyExists" ]; then
    openstack_update_property_in_file "$property" "$novaConfFile" "$value"
  else
    echo -e "\n" >> "$novaConfFile"
    # insert at end of header block
    sed -e '/^\['${header}'\]/{:a;n;/^$/!ba;i\'${property}'='${value} -e '}' -i "$novaConfFile"
  fi
}

# update nova.conf
novaConfFile="$NOVA_CONFIG_DIR_LOCATION_PATH/nova.conf"
if [ ! -f "$novaConfFile" ]; then
 	novaConfFile="/etc/nova/nova.conf"
fi
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
updateNovaConf "attestation_server_ca_file" "${mtwilsonServerCaFilePem}" "trusted_computing" "$novaConfFile"
updateNovaConf "scheduler_driver" "nova.scheduler.filter_scheduler.FilterScheduler" "DEFAULT" "$novaConfFile"
schedulerDefaultFiltersExists=$(grep '^scheduler_default_filters=' "$novaConfFile")
if [ -n "$schedulerDefaultFiltersExists" ]; then
  alreadyIncludesRamFilter=$(echo "$schedulerDefaultFiltersExists" | grep 'RamFilter')
  if [ -z "$alreadyIncludesRamFilter" ]; then
    sed -i '/^scheduler_default_filters=/ s/$/,RamFilter/g' "$novaConfFile"
  fi
  alreadyIncludesComputeFilter=$(echo "$schedulerDefaultFiltersExists" | grep 'ComputeFilter')
  if [ -z "$alreadyIncludesComputeFilter" ]; then
    sed -i '/^scheduler_default_filters=/ s/$/,ComputeFilter/g' "$novaConfFile"
  fi
  alreadyIncludesTrustAssertionFilter=$(echo "$schedulerDefaultFiltersExists" | grep 'TrustAssertionFilter')
  if [ -z "$alreadyIncludesTrustAssertionFilter" ]; then
    sed -i '/^scheduler_default_filters=/ s/$/,TrustAssertionFilter/g' "$novaConfFile"
  fi
else
  updateNovaConf "scheduler_default_filters" "RamFilter,ComputeFilter,TrustAssertionFilter" "DEFAULT" "$novaConfFile"
fi

# make sure unzip and authbind are installed
MTWILSON_OPENSTACK_YUM_PACKAGES="zip unzip patch patchutils"
MTWILSON_OPENSTACK_APT_PACKAGES="zip unzip patch patchutils"
MTWILSON_OPENSTACK_YAST_PACKAGES="zip unzip patch patchutils"
MTWILSON_OPENSTACK_ZYPPER_PACKAGES="zip unzip patch patchutils"
auto_install "Installer requirements" "MTWILSON_OPENSTACK"
if [ $? -ne 0 ]; then echo_failure "Failed to install prerequisites through package installer"; exit -1; fi

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

function getDistributionLocation() {
  if [ "$DISTRIBUTION_LOCATION" == "" ]; then
	DISTRIBUTION_LOCATION=$(/usr/bin/python -c "from distutils.sysconfig import get_python_lib; print(get_python_lib())") 
  if [ $? -ne 0 ]; then echo_failure "Failed to determine distribution location"; echo_failure "Check nova compute configuration"; exit -1; fi
fi  
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

### Apply patches
COMPUTE_COMPONENTS="mtwilson-openstack-host-tag-vm"
FLAVOUR=$(getFlavour)
DISTRIBUTION_LOCATION=$(getDistributionLocation)
version=$(getOpenstackVersion)

echo "# $(date)" > $OPENSTACK_EXT_ENV/openstack-ext-layout
echo "export OPENSTACK_EXT_HOME=$OPENSTACK_EXT_HOME" >> $OPENSTACK_EXT_ENV/openstack-ext-layout
echo "export OPENSTACK_EXT_REPOSITORY=$OPENSTACK_EXT_REPOSITORY" >> $OPENSTACK_EXT_ENV/openstack-ext-layout
echo "export OPENSTACK_EXT_BIN=$OPENSTACK_EXT_BIN" >> $OPENSTACK_EXT_ENV/openstack-ext-layout
echo "export NOVA_CONFIG_DIR_LOCATION_PATH=$NOVA_CONFIG_DIR_LOCATION_PATH" >> $OPENSTACK_EXT_ENV/openstack-ext-layout
echo "export DISTRIBUTION_LOCATION=$DISTRIBUTION_LOCATION" >> $OPENSTACK_EXT_ENV/openstack-ext-layout
echo "export OPENSTACK_DASHBOARD_LOCATION=$OPENSTACK_DASHBOARD_LOCATION" >> $OPENSTACK_EXT_ENV/openstack-ext-layout

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
	echo "$patch_dir"
  elif [ ! -z $patch ]; then
    for i in $(seq $patch -1 0); do
      echo "check for $OPENSTACK_EXT_REPOSITORY/$component/$major.$minor.$i"
      if [ -e $OPENSTACK_EXT_REPOSITORY/$component/$major.$minor.$i ]; then
        patch_dir=$OPENSTACK_EXT_REPOSITORY/$component/$major.$minor.$i
	echo "$patch_dir"
        break
      fi
    done
  fi
  if [ -z $patch_dir ] && [ -e $OPENSTACK_EXT_REPOSITORY/$component/$major.$minor ]; then
    patch_dir=$OPENSTACK_EXT_REPOSITORY/$component/$major.$minor
	echo "$patch_dir"
  fi

  if [ -z $patch_dir ]; then
    echo_failure "Could not find suitable patches for Openstack version $version"
    exit -1
  else
    echo "Applying patches from directory $patch_dir"
  fi
}

# Uninstall previously installed patches
for component in $COMPUTE_COMPONENTS; do
  if [ -d $OPENSTACK_EXT_REPOSITORY/$component ]; then
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
  fi
done

# extract mtwilson-openstack-controller  (mtwilson-openstack-controller-zip-0.1-SNAPSHOT.zip)
echo "Extracting application..."
MTWILSON_OPENSTACK_ZIPFILES=`ls -1 mtwilson-openstack-controller-*.zip 2>/dev/null | head -n 1`

for MTWILSON_OPENSTACK_ZIPFILE in $MTWILSON_OPENSTACK_ZIPFILES; do
  echo "Extract $MTWILSON_OPENSTACK_ZIPFILE"
  unzip -oq $MTWILSON_OPENSTACK_ZIPFILE -d $OPENSTACK_EXT_REPOSITORY
done

# copy utilities script file to application folder
cp $UTIL_SCRIPT_FILE $OPENSTACK_EXT_HOME/bin/functions.sh
cp $PATCH_UTIL_SCRIPT_FILE $OPENSTACK_EXT_HOME/bin/patch-util.sh
cp $UNINSTALL_SCRIPT_FILE $OPENSTACK_EXT_HOME/bin/mtwilson-openstack-controller-uninstall.sh


# set permissions
chmod 700 $OPENSTACK_EXT_HOME/bin/*.sh

cd $OPENSTACK_EXT_REPOSITORY


for component in $COMPUTE_COMPONENTS; do
  find_patch $component $version
	echo "$patch_dir/root.patch"
  apply_patch "/" "$patch_dir/root.patch" 1
  if [ $? -ne 0 ]; then
    echo_failure "Error while applying patches."
    exit -1
  fi
   apply_patch "$DISTRIBUTION_LOCATION/" "$patch_dir/distribution-location.patch" 1
if [ $? -ne 0 ]; then
    echo_failure "Error while applying patches."
    exit -1
  fi
 apply_patch "$OPENSTACK_DASHBOARD_LOCATION/" "$patch_dir/openstack-dashboard.patch" 1
	if [ $? -ne 0 ]; then
    echo_failure "Error while applying patches."
    exit -1
  fi

done

find /usr/share/openstack-dashboard/ -name "*.pyc" -delete
NOVACLIENT_LOCATION=`find "/" -name "novaclient"`
if [ `echo $?` == 0 ] ; then
find $NOVACLIENT_LOCATION -name "*.pyc" -delete
fi
find $DISTRIBUTION_LOCATION/nova -name "*.pyc" -delete

# remove trusted_filter.py if exists
trustedFilterFile=$(find "$DISTRIBUTION_LOCATION" -name "trusted_filter.py")
if [ -f "$trustedFilterFile" ]; then
  rm -f "$trustedFilterFile"
fi

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
