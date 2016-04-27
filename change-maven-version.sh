#!/bin/bash

# define action usage commands
usage() { echo "Usage: $0 [-v \"version\"]" >&2; exit 1; }

# set option arguments to variables and echo usage on failures
version=
while getopts ":v:" o; do
  case "${o}" in
    v)
      version="${OPTARG}"
      ;;
    \?)
      echo "Invalid option: -$OPTARG"
      usage
      ;;
    *)
      usage
      ;;
  esac
done

if [ -z "$version" ]; then
  echo "Version not specified" >&2
  exit 2
fi

changeVersionCommand="mvn versions:set -DnewVersion=${version}"
changeParentVersionCommand="mvn versions:update-parent -DallowSnapshots=true -DparentVersion=${version}"
mvnInstallCommand="mvn clean install"

(cd mtwilson-openstack-maven-root && $changeVersionCommand)
if [ $? -ne 0 ]; then echo "Failed to change maven version on \"mtwilson-openstack-maven-root\" folder" >&2; exit 3; fi
ant ready
if [ $? -ne 0 ]; then echo "Failed to run \"ant ready\" command" >&2; exit 3; fi
$changeVersionCommand
if [ $? -ne 0 ]; then echo "Failed to change maven version at top level" >&2; exit 3; fi
$changeParentVersionCommand
if [ $? -ne 0 ]; then echo "Failed to change maven parent versions" >&2; exit 3; fi
(cd compute-node/mtwilson-openstack-policyagent-hooks && $changeVersionCommand)
if [ $? -ne 0 ]; then echo "Failed to change maven version on \"compute-node/mtwilson-openstack-policyagent-hooks\" folder" >&2; exit 3; fi
(cd compute-node/mtwilson-openstack-vm-attestation && $changeVersionCommand)
if [ $? -ne 0 ]; then echo "Failed to change maven version on \"compute-node/mtwilson-openstack-vm-attestation\" folder" >&2; exit 3; fi
(cd controller/mtwilson-openstack-host-tag-vm && $changeVersionCommand)
if [ $? -ne 0 ]; then echo "Failed to change maven version on \"controller/mtwilson-openstack-host-tag-vm\" folder" >&2; exit 3; fi
(cd mtwilson-linux-patch-util && $changeVersionCommand)
if [ $? -ne 0 ]; then echo "Failed to change maven version on \"mtwilson-linux-patch-util\" folder" >&2; exit 3; fi

(cd packages  && $changeVersionCommand)
if [ $? -ne 0 ]; then echo "Failed to change maven version on \"packages\" folder" >&2; exit 3; fi
(cd packages  && $changeParentVersionCommand)
if [ $? -ne 0 ]; then echo "Failed to change maven parent versions in \"packages\" folder" >&2; exit 3; fi
(cd packages/mtwilson-openstack-controller && $changeVersionCommand)
if [ $? -ne 0 ]; then echo "Failed to change maven version on \"packages/mtwilson-openstack-controller\" folder" >&2; exit 3; fi
(cd packages/mtwilson-openstack-node && $changeVersionCommand)
if [ $? -ne 0 ]; then echo "Failed to change maven version on \"packages/mtwilson-openstack-node\" folder" >&2; exit 3; fi
(cd packages/mtwilson-openstack-trusted-node-rhel && $changeVersionCommand)
if [ $? -ne 0 ]; then echo "Failed to change maven version on \"packages/mtwilson-openstack-trusted-node-rhel\" folder" >&2; exit 3; fi
(cd packages/mtwilson-openstack-trusted-node-ubuntu && $changeVersionCommand)
if [ $? -ne 0 ]; then echo "Failed to change maven version on \"packages/mtwilson-openstack-trusted-node-ubuntu\" folder" >&2; exit 3; fi

sed -i 's/\-[0-9\.]*\(\-SNAPSHOT\|\(\-\|\.zip$\|\.bin$\|\.jar$\)\)/-'${version}'\2/g' build.targets
if [ $? -ne 0 ]; then echo "Failed to change versions in \"build.targets\" file" >&2; exit 3; fi
