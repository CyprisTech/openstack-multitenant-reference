#!/usr/bin/env python3
"""Prints the address under which this bootstrap instance reaches the API floating IP: its own
floating IP, read from Neutron with the cluster credential (/opt/platform/clouds.yaml, entry
"openstack"). The API load balancer admits it only while the bootstrap instance manages the
cluster."""

import json
import os
import socket
import ssl
import urllib.parse
import urllib.request

import yaml

CA = "/opt/platform/cacert.pem"


def fqdn(url):
    """The URL without the root dot of the host name: Python checks certificates against it."""
    u = urllib.parse.urlsplit(url)
    return u._replace(netloc=u.netloc.replace(u.hostname, u.hostname.rstrip("."), 1)).geturl().rstrip("/")


cloud = yaml.safe_load(open("/opt/platform/clouds.yaml"))["clouds"]["openstack"]
auth = cloud["auth"]
context = ssl.create_default_context(cafile=CA if os.path.exists(CA) else None)
body = {"auth": {"identity": {"methods": ["application_credential"], "application_credential": {
    "id": auth["application_credential_id"], "secret": auth["application_credential_secret"]}}}}
request = urllib.request.Request(fqdn(auth["auth_url"]) + "/auth/tokens", json.dumps(body).encode(),
                                 {"Content-Type": "application/json"})
with urllib.request.urlopen(request, context=context) as response:
    token, catalog = response.headers["X-Subject-Token"], json.load(response)["token"]["catalog"]
neutron = next(e["url"] for s in catalog if s["type"] == "network" for e in s["endpoints"]
               if e["interface"] == cloud.get("interface", "public")
               and e.get("region_id", e.get("region")) == cloud.get("region_name", "RegionOne"))

# The address of this instance on the cluster network: the source of a route to any address.
probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
probe.connect(("192.0.2.1", 9))
address = probe.getsockname()[0]

request = urllib.request.Request(fqdn(neutron) + "/v2.0/floatingips?fixed_ip_address=" + address,
                                 headers={"X-Auth-Token": token})
with urllib.request.urlopen(request, context=context) as response:
    print(json.load(response)["floatingips"][0]["floating_ip_address"] + "/32")
