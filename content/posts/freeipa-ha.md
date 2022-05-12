---
title: "FreeIPA High-Availability"
date: 2020-09-15T11:30:03+00:00
# weight: 1
# aliases: ["/first"]
tags: ["FreeIPA"]
author: "Me"
# author: ["Me", "You"] # multiple authors
showToc: true
TocOpen: false
draft: false
hidemeta: false
comments: false
description: "Setup High-Availability for FreeIPA using Keepalived"
canonicalURL: "https://blog.stabl.one/posts/freeipa-ha/"
disableHLJS: false # to disable highlightjs
disableShare: false
hideSummary: false
searchHidden: true
ShowReadingTime: true
ShowBreadCrumbs: true
ShowPostNavLinks: true
cover:
    image: "<image path/url>" # image path/url
    alt: "<alt text>" # alt text
    caption: "<text>" # display caption under cover
    relative: false # when using page bundles set this to true
    hidden: true # only hide on current single page
editPost:
    URL: "https://github.com/stefanabl/blog"
    Text: "Suggest Changes" # edit text
    appendFilePath: true # to append file path to Edit link
---
## FreeIPA High-Availbility with Keepalived

FreeIPA is a popular application which can be used for centralized user and host management, DNS and even certificates. While multiple replicas of the FreeIPA server can provide failover, it is not truly highly-available unless the client switches over to the replica server. Therefore we will configure the web interface and the LDAP server to automatically failover and be available under the same address/hostname at all times.

## Goal and Prerequisites

In this guide we will replace a FreeIPA server reachable at ipa.domain with the IP address 192.168.0.100 with two replicas ipa0.domain and ipa1.domain which share a so-called Virtual IP (VIP) address. The goal is that the configuration of all clients, whether they interact with the server via LDAP or HTTP, does not have to be changed. If Linux hosts have be joined to the domain and the hostname of the server has been set manually and not auto-detected these have to be reconfigured or rejoined.

## Ensure the Replication Agreements are Setup Correctly

After you have setup the two new replicas ipa0.domain and ipa1.domain, make sure they can replicate between each other even without the server which should be removed. In the web interface head to IPA Server > Topology > Topology Graph and check if a direct replication agreement exists between the two new servers for CA and domain, if not create it.

## Configure Keepalived

Keepalived is used to create the shared VIP and route traffic from it to one of the FreeIPA servers. It will have to be installed via yum with the following command on both new FreeIPA servers.

```shell
yum install keepalived
```

We will then configure it by adjusting the file `/etc/keepalived/keepalived.conf`. It should adjusted according to the following template. The contents will be slightly different on both servers.

```
vrrp_instance IPA {
  state <BACKUP/MASTER>
  virtual_router_id 55
  interface ens18
  priority 100
  advert_int 1
  unicast_src_ip <local ip>
  unicast_peer {
    10.13.0.109
  }

  authentication {
    auth_type PASS
    auth_pass  <randomString>
  }

  virtual_ipaddress {
    10.13.0.254/24
  }
}
```

* A name is given to the VRRP instance and further configuration is done inside the brackets.
* The state option controls the desired state of the server. If set to MASTER the server will be preferred to handle traffic and the server or servers configured with the option set to BACKUP will only handle traffic while the main server is offline.
* The option virtual_router_id must be a numeric ID of this high-availability group which is unique on this network.
* The option interface should be set to the name of the interface, Keepalived should use.
* The option priority indicates when a server should receive traffic. A server only receives traffic when all servers with a higher priority are offline.
* The option unicast_src_ip should be set to the local IPv4 address of the interface specified in the option interface.
* unicast_peer is a list of IPv4 addresses of the peers, which share the VIP, excluding the local server.
* In the authentication section we instruct Keepalived to use password authentication and configure a password, which has to be the same between all servers. Keep in mind that the password is truncated to eight characters.
* In the section virtual_ipaddress we specify the VIP we want to use. At this point do not set the IP address of the FreeIPA server that should be replaced.

Sources:  [keepalived docs](https://keepalived.readthedocs.io/en/latest/introduction.html) and [tutorial](https://www.youtube.com/watch?v=hPfk0qd4xEY)

## Remove the Old FreeIPA Host

Before the new FreeIPA servers can take over, the old host, ipa.domain, will have to be removed. The procedure is detailed in the [Red Hat documentation](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/8/html/installing_identity_management/uninstalling-an-ipa-server_installing-identity-management). All commands should be run on any IPA server as root.

First make sure that there is more than one IPA server acting as DNS, CA and KRA server. Of course only if you use these features of FreeIPA. Run the following commands:

```shell
ipa server-role-find --role 'DNS server'
ipa server-role-find --role 'CA server'
ipa server-role-find --role 'KRA server'
```

The output should be similar to the following.

```shell
----------------------
3 server roles matched
----------------------
  Server name: ipa0.domain
  Role name: DNS server
  Role status: enabled
[...]
----------------------------
Number of entries returned 3
----------------------------
```

Make sure that the server you are removing is not the Ca renewal server:

```shell
ipa config-show | grep 'CA renewal'
```

If it is change it with the following commands:

```shell
ipa config-mod --ca-renewal-master-server ipa0.domain | grep 'CA renewal'
```

Make sure that the server you are removing is not the current certificate revocation list (CRL) publisher, by running the following command on the server ipa.domain

```shell
[root@ipa ~]# ipa-crlgen-manage status
CRL generation: disabled
```

If it is disable it on the server with the command `ipa-crlgen-manage disable`, then enable it on another server with the command `ipa-crlgen-manage enable`.

Only then can the FreeIPA server ipa.domain be disabled from another server:

```shell
kinit admin
ipa server-del ipa.domain
```

Finish the un-installation by running the command `ipa-server-install --uninstall` on the server you are un-installing. The virtual machine running it can then shutdown.

## Change the Keepalived VIP

Change the VIP of Keepalived configured in a previous step to the old IP address of the FreeIPA server that you just deleted.

## Make the Certificates of New Hosts Also Valid for the Hostname of the Old Host

Add a host entry for the old host and add services for HTTP and LDAP to it.

```bash
ipa host-add ipa.domain --ip-address=192.168.2.10 --force
ipa service-add HTTP/ipa.domain
ipa service-add ldap/ipa.domain
```

Then we need to make the certificates for the new servers ipa0.domain and ipa1.domain also valid for ipa.domain. For this, first, the request ID of the certificates currently used for the web server and LDAP server has to be found. This is done by running `sudo getcert list | less`. Then, search for HTTP by entering `/HTTP` and also search for ldap. Once the request IDs for the certificates are obtained, the certificate requests can be modified. The certificates requested are then also valid for ipa.domain next to ipa0.domain or ipa1.domain. And automatically installed in the same place as the old ones.

```
sudo getcert resubmit -i "20220131213857" -D ipa0.domain -D ipa.domain -K HTTP/ipa0.domain
```

Sources: [here](https://lists.fedorahosted.org/archives/list/freeipa-users@lists.fedorahosted.org/thread/6FISBEB4UCE5IGW2XMVVYRR6Q2WOZG46/) and [here](https://lists.fedorahosted.org/archives/list/freeipa-users@lists.fedorahosted.org/thread/BVJEMTQTFBU2XGVZCQDSVXS5ZJNXIZCK/)

## Configure Webserver to not redirect requests for ipa.domain

In order to be able to access the FreeIPA web interface and API via the domain ipa.domain, the configuration of the webserver has to be altered. Apache is used as the webserver for FreeIPA and so called Rewrite Rules handle the behavior of redirecting requests made to the webserver to the fully qualified hostname of the FreeIPA server.

I modified the rewrite rules so that requests to `https://ipa.domain/ipa` are not redirected, which allows other applications to interact with the API via this URL. However if you enter `ipa.domain` in your browsers address bar you will still be redirected. If you do not want this, replace `ipa0.domain` or `ipa1.domain` in the Rewrite Rules with `ipa.domain`. 

To disable the redirection of requests made to the hostname ipa.domain the following modifications have to be made to the file `/etc/httpd/conf.d/ipa-rewrite.conf`.

```
# VERSION 7 - DO NOT REMOVE THIS LINE

RewriteEngine on

# By default forward all requests to /ipa. If you don't want IPA
# to be the default on your web server comment this line out.
RewriteRule ^/$ https://ipa0.domain/ipa/ui [L,NC,R=301]

# BEGIN: INSERTED BLOCK
# Also allow hostname ipa.domain
RewriteCond %{HTTP_HOST}    ^ipa.domain$ [NC]
RewriteCond %{SERVER_PORT}  ^443$
RewriteRule ^/ipa/ui/js/freeipa/plugins.js$    /ipa/wsgi/plugins.py [PT]

# Also rewrite the plugin index, when the alternative hostname is used
RewriteCond %{HTTP_HOST}    ^ipa.domain$ [NC]
RewriteCond %{SERVER_PORT}  ^443$
RewriteRule ^/ipa/(.*)      - [L]
# END: INSERTED BLOCK
```

Insert the block after the first RewriteRule directive. The first RewriteRule and conditions added instructs Apache to rewrite requests made to the host ipa.domain on port 443 for the file plugin.js to a Python script. The second RewriteRule directive and associated conditions instructs Apache to not alter any requests to `https://ipa.domain/ipa` and skip any following RewriteRules.

However for some requests the FreeIPA checks whether the HTTP referer header matches the hostname of the server. To be able to access the server via the hostname ipa.domain, next to the server real hostname, this check needs to be disabled. Therefore the file `/usr/lib/python3.6/site-packages/ipaserver/rpcserver.py` needs to be edited. Locate the following block of code by searching for `HTTP_REFERER` and replace the commented out return statement with a pass directive. Since this is Python watch the indentation level.

```python
 if 'HTTP_REFERER' not in environ:
            return self.marshal(result, RefererError(referer='missing'), _id)
        if not environ['HTTP_REFERER'].startswith('https://%s/ipa' % self.api.env.host) and not self.env.in_tree:
            pass # return self.marshal(result, RefererError(referer=environ['HTTP_REFERER']), _id)
        if self.api.env.debug:
            time_start = time.perf_counter_ns()
```

Also don't forget to make these modifications to both systems.

## Monitor FreeIPA with Keepalived

With the current configuration Keepalived will only fail over to the backup host, if the first host is shutdown. However if the host is up but the FreeIPA server is down, such as during an update or an error of the software, requests are still routed to the first server. That is why a basic health-check is introduced, to monitor the health of the FreeIPA server and fail over, when it is no longer reachable. The check is a simple HTTPS request to the web interface of FreeIPA. This is not a complete check of the FreeIPA system but better than before. To add the check add the following block into the Keepalived configuration file `/etc/keepalived/keepalived.conf`. It is important that this block is added before the block configuring the VRRP instance.

```
vrrp_script freeipa {
    script "/usr/bin/curl https://ipa0.domain/ipa/ui/"
    interval 5
    timeout 1
}
```

Additionally, the following block has to be added into the VRRP instance, to use the script.

```
track_script {
    freeipa
  }
```

Do not forget to adjust the hostname in the script to match the local hostname of the machine. You should be able to observe the requests issued by Keepalived in the Apache logs.

## Done

Now you should have a highly-available FreeIPA setup which you can easily connect to via HTTP or LDAP. This allows clients which cannot be configured to fail over themselves to continue working, even if one of the FreeIPA servers is down.
