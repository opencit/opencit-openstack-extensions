# vim: tabstop=4 shiftwidth=4 softtabstop=4

# Copyright (c) 2012 Intel, Inc.
# Copyright (c) 2011-2012 OpenStack Foundation
# All Rights Reserved.
#
#    Licensed under the Apache License, Version 2.0 (the "License"); you may
#    not use this file except in compliance with the License. You may obtain
#    a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
#    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
#    License for the specific language governing permissions and limitations
#    under the License.

"""
Filter to add support for Trusted Computing Pools.

Filter that only schedules tasks on a host if the integrity (trust)
of that host matches the trust requested in the `extra_specs' for the
flavor.  The `extra_specs' will contain a key/value pair where the
key is `trust'.  The value of this pair (`trusted'/`untrusted') must
match the integrity of that host (obtained from the Attestation
service) before the task can be scheduled on that host.

Note that the parameters to control access to the Attestation Service
are in the `nova.conf' file in a separate `trust' section.  For example,
the config file will look something like:

    [DEFAULT]
    verbose=True
    ...
    [trust]
    server=attester.mynetwork.com

Details on the specific parameters can be found in the file `trust_attest.py'.

Details on setting up and using an Attestation Service can be found at
the Open Attestation project at:

    https://github.com/OpenAttestation/OpenAttestation
"""

import httplib
import socket
import ssl
import json
import ast

from oslo.config import cfg

from nova import context
from nova import db
from nova.openstack.common.gettextutils import _
from nova.openstack.common import jsonutils
from nova.openstack.common import log as logging
from nova.openstack.common import timeutils
from nova.scheduler import filters

from lxml import etree
import base64
from base64 import b64encode
import random

LOG = logging.getLogger(__name__)

trusted_opts = [
    cfg.StrOpt('attestation_server',
               help='attestation server http'),
    cfg.StrOpt('attestation_server_ca_file',
               help='attestation server Cert file for Identity verification'),
    cfg.StrOpt('attestation_port',
               default='8443',
               help='attestation server port'),
    cfg.StrOpt('attestation_api_url',
               default='/mtwilson/v2/host-attestations',
               help='attestation web API URL'),
    cfg.StrOpt('attestation_host_url',
               default='/mtwilson/v2/hosts',
               help='attestation web API URL'),
    cfg.StrOpt('attestation_auth_blob',
               help='attestation authorization blob - must change'),
    cfg.IntOpt('attestation_auth_timeout',
               default=60,
               help='Attestation status cache valid period length'),
]

CONF = cfg.CONF
trust_group = cfg.OptGroup(name='trusted_computing', title='Trust parameters')
CONF.register_group(trust_group)
CONF.register_opts(trusted_opts, group=trust_group)

class HTTPSClientAuthConnection(httplib.HTTPSConnection):
    """
    Class to make a HTTPS connection, with support for full client-based
    SSL Authentication
    """

    def __init__(self, host, port, key_file, cert_file, ca_file, timeout=None):
        httplib.HTTPSConnection.__init__(self, host,
                                         key_file=key_file,
                                         cert_file=cert_file)
        self.host = host
        self.port = port
        self.key_file = key_file
        self.cert_file = cert_file
        self.ca_file = ca_file
        self.timeout = timeout

    def connect(self):
        """
        Connect to a host on a given (SSL) port.
        If ca_file is pointing somewhere, use it to check Server Certificate.

        Redefined/copied and extended from httplib.py:1105 (Python 2.6.x).
        This is needed to pass cert_reqs=ssl.CERT_REQUIRED as parameter to
        ssl.wrap_socket(), which forces SSL to check server certificate
        against our client certificate.
        """
        sock = socket.create_connection((self.host, self.port), self.timeout)
        self.sock = ssl.wrap_socket(sock, self.key_file, self.cert_file,
                                    ca_certs=self.ca_file,
                                    cert_reqs=ssl.CERT_REQUIRED)


class AttestationService(object):
    # Provide access wrapper to attestation server to get integrity report.

    def __init__(self):
        self.api_url = CONF.trusted_computing.attestation_api_url
        self.host = CONF.trusted_computing.attestation_server
        self.port = CONF.trusted_computing.attestation_port
        self.auth_blob = CONF.trusted_computing.attestation_auth_blob
        self.key_file = None
        self.cert_file = None
        self.ca_file = CONF.trusted_computing.attestation_server_ca_file
        self.request_count = 100

    def _do_request(self, method, action_url, params, headers):
        # Connects to the server and issues a request.
        # :returns: result data
        # :raises: IOError if the request fails

        action_url = "%s?host_id=%s&limit=1" % (self.api_url, params) #"%s" % (self.api_url)
        try:
            c = HTTPSClientAuthConnection(self.host, self.port,
                                          key_file=self.key_file,
                                          cert_file=self.cert_file,
                                          ca_file=self.ca_file)

            c.request(method, action_url, json.dumps(params), headers)
            res = c.getresponse()
            status_code = res.status
            if status_code in (httplib.OK,
                               httplib.CREATED,
                               httplib.ACCEPTED,
                               httplib.NO_CONTENT):
                return httplib.OK, res
            return status_code, None

        except (socket.error, IOError):
            return IOError, None

    def _request(self, cmd, subcmd, host_uuid):
        # Setup the header & body for the request
        params = {"host_uuid": host_uuid}

        headers = {}
        auth = base64.encodestring(self.auth_blob).replace('\n', '')
        if self.auth_blob:
            headers['x-auth-blob'] = self.auth_blob
            headers['Authorization'] = "Basic " + auth
            headers['Accept'] = 'application/samlassertion+xml'
            #headers['Content-Type'] = 'application/json'
        #status, res = self._do_request(cmd, subcmd, params, headers)
        status, res = self._do_request(cmd, subcmd, host_uuid, headers)
        if status == httplib.OK:
            data = res.read()
            return status, data
        else:
            return status, None

    def do_attestation(self, host_uuid):
        """Attests compute nodes through OAT service.

        :param hosts: hosts list to be attested
        :returns: dictionary for trust level and validate time
        """
        result = None

        #status, data = self._request("POST", "PollHosts", hosts)
        #status, data = self._request("POST", "", host_uuid)
        status, data = self._request("GET", "", host_uuid)

        return data 

class TrustAssertionFilter(filters.BaseHostFilter):

    def __init__(self):
        self.attestservice = AttestationService()
        self.compute_nodes = {}
        admin = context.get_admin_context()

        # Fetch compute node list to initialize the compute_nodes,
        # so that we don't need poll OAT service one by one for each
        # host in the first round that scheduler invokes us.
        self.compute_nodes = db.compute_node_get_all(admin)


    def host_passes(self, host_state, filter_properties):
        """Only return hosts with required Trust level."""
        verify_asset_tag = False
        verify_trust_status = False

        spec = filter_properties.get('request_spec', {})
        image_props = spec.get('image', {}).get('properties', {})

	# Get the Tag verification flag from the image properties 
        tag_selections = image_props.get('tags') # comma seperated values
        trust_verify = image_props.get('trust') # comma seperated values

        if('mtwilson_trustpolicy_location' in image_props):
            trust_verify = 'true'
        
        #if tag_selections is None or tag_selections == 'Trust':
        if trust_verify == 'true':
            verify_trust_status = True
            if tag_selections != None and tag_selections != {} and  tag_selections != 'None':
                verify_asset_tag = True

        
        if not verify_trust_status:
            # Filter returns success/true if neither trust or tag has to be verified.
            return True

        # Get the host UUID based on the hostname
        host_uuid = self.get_hypervisor_uuid(host_state.hypervisor_hostname)
        if (host_uuid == ''):
            # Sometimes the host is registered with the host IP. So, try getting the host UUID based on the ip
            host_uuid = self.get_hypervisor_uuid(host_state.host_ip)

        if (host_uuid == ''):
            return False

        host_data = self.attestservice.do_attestation(host_uuid)
        trust, asset_tag = self.verify_and_parse_saml(host_data)
        if not trust:
            return False

        if verify_asset_tag:
            # Verify the asset tag restriction
            LOG.error(asset_tag)
            LOG.error(tag_selections)
            return self.verify_asset_tag(asset_tag, tag_selections)


        return True


    def verify_and_parse_saml(self, saml_data):
        trust = False
        asset_tag = {}

        # Trust attestation service responds with a JSON in case the given host name is not found
        # Need to update this after the mt. wilson service is updated to return consistent message formats
        try:
            if json.loads(saml_data):
                return trust, asset_tag
        except:
            LOG.debug("System does not exist in the Mt. Wilson portal")

        ns = {'saml2p': '{urn:oasis:names:tc:SAML:2.0:protocol}',
              'saml2': '{urn:oasis:names:tc:SAML:2.0:assertion}'}

        try:
            # xpath strings
            xp_attributestatement = '{saml2}AttributeStatement/{saml2}Attribute'.format(**ns)
            xp_attributevalue = '{saml2}AttributeValue'.format(**ns)

            doc = etree.XML(saml_data)
            elements = doc.findall(xp_attributestatement)
    
            for el in elements:
                if el.attrib['Name'].lower() == 'trusted':
                    if el.find(xp_attributevalue).text == 'true':
                        trust = True
                elif el.attrib['Name'].lower().startswith("tag"):
                    asset_tag[el.attrib['Name'].lower().split('[')[1].split(']')[0].lower()] = el.find(xp_attributevalue).text.lower()

            return trust, asset_tag
        except:
            return trust, asset_tag

    # Verifies the asset tag match with the tag selections provided by the user.
    def verify_asset_tag(self, host_tags, tag_selections):
        # host_tags is the list of tags set on the host
        # tag_selections is the list of tags set as the policy of the image
        ret_status = False
        selection_details = {}

        try: 
            sel_tags = ast.literal_eval(tag_selections.lower())

            iteration_status = True
            for tag in list(sel_tags.keys()):
                if tag not in list(host_tags.keys()) or host_tags[tag] not in sel_tags[tag]:
                #if tag not in dict((k.lower(),v) for k,v in host_tags.items()).keys() or host_tags[tag.lower()].lower() not in (val.upper() for val in sel_tags[tag]:
                    iteration_status = False
            if(iteration_status):
                ret_status = True
        except:
            ret_status = False

        return ret_status

    # Retrieve the hypervisor UUID based on the hostname
    def get_hypervisor_uuid(self, hostname):
        try:
            host = CONF.trusted_computing.attestation_server
            port = CONF.trusted_computing.attestation_port
            auth_blob = CONF.trusted_computing.attestation_auth_blob
            host_url = CONF.trusted_computing.attestation_host_url + '?nameEqualTo=' + hostname
            LOG.error(host_url)
            if  hasattr(ssl,'SSLContext') and CONF.trusted_computing.attestation_server_ca_file:
                LOG.info("Using SSL context HTTPS client connection to attestation server with SSL certificate verification")
                as_context = ssl.SSLContext(ssl.PROTOCOL_TLSv1_2)
                as_context.verify_mode = ssl.CERT_REQUIRED
                as_context.check_hostname = True
                as_context.load_verify_locations(CONF.trusted_computing.attestation_server_ca_file)
                c = httplib.HTTPSConnection(host, port=port, context=as_context)
            else:
                LOG.info("Using socket HTTPS client connection to attestation server with SSL certificate verification")
                c = HTTPSClientAuthConnection(host, port, key_file=None, cert_file=None, ca_file=CONF.trusted_computing.attestation_server_ca_file)
				 
            userAndPass = b64encode(auth_blob).decode("ascii")
            headers = { 'Authorization' : 'Basic %s' %  userAndPass , 'Accept': 'application/json'}
            c.request('GET', host_url, headers=headers)
            res = c.getresponse()
            res_data = res.read()
            return json.loads(res_data)['hosts'][0]['id']
        except Exception:
            LOG.error("Exception")
            return ""


