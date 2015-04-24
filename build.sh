#!/bin/bash

# NOTE: this script must be run from the dcg_security-openstack-extensions folder as current directory
# NOTE: this build.sh script will be replaced by an ant/maven combination, and a lot of changes to the
#       build itself instead of using the same .tar.gz for both compute node and openstack

mkdir -p packages/mtwilson-openstack-compute-node/target
mkdir -p packages/mtwilson-openstack-controller/target

tar cfz packages/mtwilson-openstack-compute-node/target/mtwilson-openstack-compute-node.tgz cinder nova Openstack
tar cfz packages/mtwilson-openstack-controller/target/mtwilson-openstack-controller.tgz cinder nova Openstack
