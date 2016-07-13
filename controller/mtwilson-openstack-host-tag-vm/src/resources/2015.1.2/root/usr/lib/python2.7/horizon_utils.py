from django.conf import settings  # noqa
from django import http
from horizon import exceptions
from horizon import forms
from horizon import messages
import glanceclient as glance_client

from openstack_dashboard import api
from oslo.serialization import jsonutils

import urllib2
import httplib
import socket
import ssl
import base64
from base64 import b64encode
import random
import logging
import json
from lxml import etree

logging.basicConfig()
LOG = logging.getLogger(__name__)

ASSET_TAG_SERVICE = getattr(settings, 'ASSET_TAG_SERVICE', {})

class SelectionUtils:

    def get_selections(self):
        try:
            host = ASSET_TAG_SERVICE['IP']
            port = ASSET_TAG_SERVICE['port']
            selection_url = ASSET_TAG_SERVICE['tags_url']
            auth_blob = ASSET_TAG_SERVICE['auth_blob']
            server_ca_file = ASSET_TAG_SERVICE['attestation_server_ca_file']
            # Setup the SSL context for certificate verification

            if  hasattr(ssl,'SSLContext') and server_ca_file:
                LOG.info("Using SSL context HTTPS client connection to attestation server with SSL certificate verification")
                as_context = ssl.SSLContext(ssl.PROTOCOL_TLSv1_2)
                as_context.verify_mode = ssl.CERT_REQUIRED
                as_context.check_hostname = True
                as_context.load_verify_locations(server_ca_file)
                c = httplib.HTTPSConnection(host, port=port, context=as_context)
            else:
                LOG.info("Using socket HTTPS client connection to attestation server with SSL certificate verification")
                c = HTTPSClientAuthConnection(host, port, key_file=None, cert_file=None, ca_file=server_ca_file)
			
            userAndPass = b64encode(auth_blob).decode("ascii")
            headers = { 'Authorization' : 'Basic %s' %  userAndPass }
            c.request('GET', selection_url + str(random.random()), headers=headers)
            res = c.getresponse()
            res_data = res.read()
            return res_data
        except Exception:
            LOG.error("Exception")
            return ""


    def get_image_selection(self, image):
       if('mtwilson_trustpolicy_location' in image.properties):
           image.properties['trust'] = 'true'
       return json.dumps(image.properties)

    def get_instance_asset_selection(self, instance):

       image_id = instance.image['id']
       api.glance.image_get(None, image_id)
       return None 

    def get_hypervisr_trust_status(self, host):
        trust_status = {}
        trust_status["trust"] =  "false"
        trust_status["tags"] =  {}

        # Get the host UUID based on the hostname
        host_uuid = self.get_hypervisor_uuid(host.hypervisor_hostname)
        if (host_uuid == ''):
            # Sometimes the host is registered with the host IP. So, try getting the host UUID based on the ip
            host_uuid = self.get_hypervisor_uuid(host.host_ip)

        if (host_uuid == ''):
            return trust_status

        attestservice = AttestationService()
        host_data = attestservice.do_attestation(host_uuid)
        trust_status = self.verify_and_parse_saml(host_data)
        return trust_status

    def get_hypervisor_uuid(self, hostname):
        try:
            host = ASSET_TAG_SERVICE['IP']
            port = ASSET_TAG_SERVICE['port']
            host_url = ASSET_TAG_SERVICE['host_url'] + "?nameEqualTo=" + hostname
            auth_blob = ASSET_TAG_SERVICE['auth_blob']
            server_ca_file = ASSET_TAG_SERVICE['attestation_server_ca_file']
            # Setup the SSL context for certificate verification

            if  hasattr(ssl,'SSLContext') and server_ca_file:
                LOG.info("Using SSL context HTTPS client connection to attestation server with SSL certificate verification")
                as_context = ssl.SSLContext(ssl.PROTOCOL_TLSv1_2)
                as_context.verify_mode = ssl.CERT_REQUIRED
                as_context.check_hostname = True
                as_context.load_verify_locations(server_ca_file)
                c = httplib.HTTPSConnection(host, port=port, context=as_context)
            else:
                LOG.info("Using socket HTTPS client connection to attestation server with SSL certificate verification")
                c = HTTPSClientAuthConnection(host, port, key_file=None, cert_file=None, ca_file=server_ca_file)
			
            userAndPass = b64encode(auth_blob).decode("ascii")
            headers = { 'Authorization' : 'Basic %s' %  userAndPass , 'Accept': 'application/json'}
            c.request('GET', host_url, headers=headers)
            res = c.getresponse()
            res_data = res.read()
            return json.loads(res_data)['hosts'][0]['id']
        except Exception:
            LOG.error("Exception")
            return ""


    def verify_and_parse_saml(self, saml_data):
        trust = False
        asset_tag = {}
        asset_tag_str = {}

        # Intel(R) Cloud Integrity Technology service responds with a JSON in case the given host name is not found
        # Need to update this after the mt. wilson service is updated to return consistent message formats
        try:
            if json.loads(saml_data):
                return "{'trust': 'false'}"
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
            trust_flag = ""
            asset_flag = ""
            asset_tooltip= ""
    
            for el in elements:
                if el.attrib['Name'].lower() == 'trusted':
                    if el.find(xp_attributevalue).text == 'true':
                        trust_flag = "Trust = true"
                        asset_tag_str["trust"] =  "true"
                        asset_tag_str["tags"] =  {}
                    else:
                        trust_flag = "Trust = Untrusted"
                        asset_tag_str["trust"] =  "false"
                        asset_tag_str["tags"] =  {}
                elif el.attrib['Name'].lower().startswith("tag["):
                    asset_flag = ", Location = true"
                    if(asset_tooltip == ""):
                        asset_tooltip = ", tooltip = "
                    asset_tooltip +=  el.attrib['Name'].lower().split('[')[1].split(']')[0] + ': ' +  el.find(xp_attributevalue).text + ' & '
                    asset_tag_str["tags"][el.attrib['Name'].lower().split('[')[1].split(']')[0]] =   el.find(xp_attributevalue).text

            #return trust_flag + asset_flag + asset_tooltip[:-2]
        except:
            LOG.error("Exception")
            asset_tag_str["trust"] =  "false"
            asset_tag_str["tags"] =  {}
        return json.dumps(asset_tag_str)


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
        self.host = ASSET_TAG_SERVICE['IP']
        self.port = ASSET_TAG_SERVICE['port']
        self.auth_blob = ASSET_TAG_SERVICE['auth_blob']
        self.api_url =  ASSET_TAG_SERVICE['api_url']
        self.key_file = None
        self.cert_file = None
        self.ca_file = ASSET_TAG_SERVICE['attestation_server_ca_file']
        self.request_count = 100

    def _do_request(self, method, action_url, params, headers):
        # Connects to the server and issues a request.
        # :returns: result data
        # :raises: IOError if the request fails

        #action_url = "%s" % (self.api_url)
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


