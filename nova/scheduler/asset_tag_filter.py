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
               default='/OpenAttestationWebServices/V1.0',
               help='attestation web API URL'),
    cfg.StrOpt('attestation_auth_blob',
               help='attestation authorization blob - must change'),
    cfg.IntOpt('attestation_auth_timeout',
               default=60,
               help='Attestation status cache valid period length'),
    cfg.StrOpt('asset_tag_server',
               help='asset tag server http'),
    cfg.StrOpt('asset_tag_server_port',
               default='9999',
               help='asset tag server port'),
    cfg.StrOpt('asset_tag_server_url',
               default='/selections',
               help='asset tag web API URL'),
    cfg.StrOpt('asset_tag_server_auth_blob',
               help='attestation authorization blob - must change'),
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
                                    ca_certs=self.ca_file)
                                    #cert_reqs=ssl.CERT_REQUIRED)


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
        self.ca_file = None
        self.request_count = 100

    def _do_request(self, method, action_url, params, headers):
        # Connects to the server and issues a request.
        # :returns: result data
        # :raises: IOError if the request fails

        action_url = "%s?%s" % (self.api_url, params)
        try:
            c = HTTPSClientAuthConnection(self.host, self.port,
                                          key_file=self.key_file,
                                          cert_file=self.cert_file,
                                          ca_file=self.ca_file)
            c.request(method, action_url, '', headers)
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

    def _request(self, cmd, subcmd, host):
        params = "hostName=" + host
        headers = {}
        auth = base64.encodestring(self.auth_blob).replace('\n', '')
        if self.auth_blob:
            headers['x-auth-blob'] = self.auth_blob
            headers['Authorization'] = "Basic " + auth
        status, res = self._do_request(cmd, subcmd, params, headers)
        if status == httplib.OK:
            data = res.read()
            return status, data
        else:
            return status, None

    def do_attestation(self, hosts):
        """Attests compute nodes through OAT service.

        :param hosts: hosts list to be attested
        :returns: dictionary for trust level and validate time
        """
        result = None

        #status, data = self._request("POST", "PollHosts", hosts)
        status, data = self._request("GET", "", hosts)

        return data 

class AssetTagService(object):
    # Provide access wrapper to Asset Tag server to perform the asset tag verification

    def __init__(self):
        self.host = CONF.trusted_computing.asset_tag_server
        self.api_url = CONF.trusted_computing.asset_tag_server_url
        self.port = CONF.trusted_computing.asset_tag_server_port
        self.auth_blob = CONF.trusted_computing.asset_tag_server_auth_blob

    # Get the tags for the given selection ID
    def get_selection_details(self, selection_id):
        c = httplib.HTTPSConnection(self.host + ':' + self.port)
        userAndPass = b64encode(self.auth_blob).decode("ascii")
        headers = { 'Authorization' : 'Basic %s' %  userAndPass }
        c.request('GET', '/selections?id=' + selection_id + "&" + str(random.random()), headers=headers)
        res = c.getresponse()
        res_data = res.read()
        tags = jsonutils.loads(res_data)[0]['tags']

        tag_dictionary = {}
        for tag in tags:
            if tag['tagName'].lower() not in tag_dictionary:
                tag_dictionary[tag['tagName'].lower()] = [tag['tagValue']]
            else:
                tag_dictionary[tag['tagName'].lower()].append(tag['tagValue'])

        return tag_dictionary

class TrustAssertionFilter(filters.BaseHostFilter):

    def __init__(self):
        self.attestservice = AttestationService()
        self.assettagservice = AssetTagService()
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
        #if tag_selections is None or tag_selections == 'Trust':
        if trust_verify == 'true':
            verify_trust_status = True
            if tag_selections != None and tag_selections != {}:
                verify_asset_tag = True

        
        if not verify_trust_status:
            # Filter returns success/true if neither trust or tag has to be verified.
            return True

        host_data = self.attestservice.do_attestation(host_state.host_ip)
        trust, asset_tag = self.verify_and_parse_saml(host_data)
        if not trust:
            return False

        if verify_asset_tag:
            # Verify the asset tag restriction
            return self.verify_asset_tag(asset_tag, tag_selections)


        return True


    def verify_and_parse_saml(self, saml_data):
        trust = False
        asset_tag = {}

        # MT. Wilson service responds with a JSON in case the given host name is not found
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
                    asset_tag[el.attrib['Name'].lower().split('[')[1].split(']')[0]] = el.find(xp_attributevalue).text

            return trust, asset_tag
        except:
            return trust, asset_tag

    # Verifies the asset tag match with the tag selections provided by the user.
    def verify_asset_tag(self, host_tags, tag_selections):
        ret_status = False
        selection_details = {}
        sel_tags = ast.literal_eval(tag_selections)

        iteration_status = True
        for tag in list(sel_tags.keys()):
            if tag not in list(host_tags.keys()) or host_tags[tag] not in sel_tags[tag]:
                iteration_status = False
        if(iteration_status):
            ret_status = True

        return ret_status
