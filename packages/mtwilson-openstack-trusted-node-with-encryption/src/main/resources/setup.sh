#!/bin/sh

# mtwilson comprehensive compute node install script
# Outline:
# 1. source the "functions.sh" file:  mtwilson-linux-util-3.0-SNAPSHOT.sh
# 2. load existing environment configuration
# 3. look for ~/mtwilson-openstack.env and source it if it's there
# enforce root user installation
# install prerequisites
# install Mtwilson Trust Agent and Measurement Agent
# install Mtwilson VRTM
# install Mtwilson Policy Agent
# install Mtwilson OpenStack compute node extensions

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
if [ -f ~/mtwilson-openstack.env ]; then
  echo "Loading environment variables from $(cd ~ && pwd)/mtwilson-openstack.env"
  . ~/mtwilson-openstack.env
  env_file_exports=$(cat ~/mtwilson-openstack.env | grep -E '^[A-Z0-9_]+\s*=' | cut -d = -f 1)
  if [ -n "$env_file_exports" ]; then eval export $env_file_exports; fi
else
  echo "No environment file"
fi

# enforce root user installation
if [ "$(whoami)" != "root" ]; then
  echo_failure "Running as $(whoami); must install as root"
  exit -1
fi

# install prerequisites
MTWILSON_OPENSTACK_YUM_PACKAGES="zip unzip"
MTWILSON_OPENSTACK_APT_PACKAGES="zip unzip"
MTWILSON_OPENSTACK_YAST_PACKAGES="zip unzip"
MTWILSON_OPENSTACK_ZYPPER_PACKAGES="zip unzip"
auto_install "Installer requirements" "MTWILSON_OPENSTACK"
if [ $? -ne 0 ]; then echo_failure "Failed to install prerequisites through package installer"; exit -1; fi

### INSTALL MTWILSON TRUST AGENT WITH MEASUREMENT AGENT
echo "Installing mtwilson trust agent..."
TRUSTAGENT_PACKAGE=`ls -1 mtwilson-trustagent-installer-*.bin 2>/dev/null | tail -n 1`
if [ -z "$TRUSTAGENT_PACKAGE" ]; then
  echo_failure "Failed to find mtwilson trust agent installer package"
  exit -1
fi
./$TRUSTAGENT_PACKAGE
if [ $? -ne 0 ]; then echo_failure "Failed to install mtwilson trust agent"; exit -1; fi

### INSTALL MTWILSON VRTM
echo "Installing mtwilson VRTM..."
VRTM_PACKAGE=`ls -1 vrtm-*.bin 2>/dev/null | tail -n 1`
if [ -z "$VRTM_PACKAGE" ]; then
  echo_failure "Failed to find mtwilson VRTM installer package"
  exit -1
fi
./$VRTM_PACKAGE
if [ $? -ne 0 ]; then echo_failure "Failed to install mtwilson VRTM"; exit -1; fi

### INSTALL MTWILSON POLICY AGENT
echo "Installing mtwilson policy agent..."
POLICYAGENT_PACKAGE=`ls -1 mtwilson-policyagent-with-encryption-*.bin 2>/dev/null | tail -n 1`
if [ -z "$POLICYAGENT_PACKAGE" ]; then
  echo_failure "Failed to find mtwilson policy agent with encryption installer package"
  exit -1
fi
./$POLICYAGENT_PACKAGE
if [ $? -ne 0 ]; then echo_failure "Failed to install mtwilson policy agent"; exit -1; fi

### INSTALL MTWILSON OPENSTACK COMPUTE NODE EXTENSIONS
echo "Installing mtwilson openstack compute node extensions..."
MTWILSON_OPENSTACK_PACKAGE=`ls -1 mtwilson-openstack-node-*.bin 2>/dev/null | tail -n 1`
if [ -z "$MTWILSON_OPENSTACK_PACKAGE" ]; then
  echo_failure "Failed to find mtwilson openstack compute node extensions installer package"
  exit -1
fi
./$MTWILSON_OPENSTACK_PACKAGE
if [ $? -ne 0 ]; then echo_failure "Failed to install mtwilson openstack compute node extensions"; exit -1; fi

echo_success "Installation complete"
