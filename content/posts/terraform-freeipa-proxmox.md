---
title: "Create a VM on Proxmox enrolled in a FreeIPA domain with Terraform"
date: 2022-06-04T22:30:03+00:00
# weight: 1
# aliases: ["/first"]
tags: ["FreeIPA", "Proxmox", "Terraform"]
author: "Me"
# author: ["Me", "You"] # multiple authors
showToc: true
TocOpen: false
draft: false
hidemeta: false
comments: true
description: "This post explores how to automatically create a VM on Proxmox with Terraform and enroll it in a FreeIPA domain."
canonicalURL: "https://blog.stabl.one/posts/terraform-freeipa-proxmox/"
disableHLJS: false # to disable highlightjs
disableShare: false
hideSummary: false
searchHidden: true
ShowReadingTime: true
ShowBreadCrumbs: true
ShowPostNavLinks: true
cover:
    image: "https://unsplash.com/photos/jHZ70nRk7Ns/download?ixid=MnwxMjA3fDB8MXxhbGx8fHx8fHx8fHwxNjU0MTE2NTAz&force=true&w=640" # image path/url
    alt: "<alt text>" # alt text
    caption: "<text>" # display caption under cover
    relative: true # when using page bundles set this to true
    hidden: false # only hide on current single page
editPost:
    URL: "https://github.com/stefanabl/blog/tree/main/content"
    Text: "Suggest Changes" # edit text
    appendFilePath: true # to append file path to Edit link
---
[Terraform](https://www.terraform.io/) is a widely used tool for Infrastructure as Code (IaC).
It can be used to define and provision all kinds of resources, from VMs to databases and DNS records.
In collaboration with [Proxmox](https://proxmox.com/en/proxmox-ve) it can be used to create VMs and LXC containers.
However one thing I struggled with for a long time was automatically enrolling a newly created VM in a FreeIPA domain.

To do this three steps are needed.
First the host is created in FreeIPA, which will return a One-Time Password (OTP) that can be used for enrollment of the host.
Afterwards, the VM has to be created on the Proxmox host and finally, it has to be enrolled in the FreeIPA domain.
I will go through the necessary steps in the Terraform file, but for the impatient here is the complete file.

{{< details "Complete Terraform file" >}}
{{< highlight hcl>}}
terraform {
  required_providers {
    proxmox = {
      source  = "telmate/proxmox"
      version = "2.9.10"
    }
    freeipa = {
      source  = "camptocamp/freeipa"
      version = "0.7.0"
    }
  }
}
provider "freeipa" {
  host     = "ipa.${var.domain}" # or set $FREEIPA_HOST
  username = var.user          # or set $FREEIPA_USERNAME
  password = var.pass          # or set $FREEIPA_PASSWORD
  insecure = true
}
provider "proxmox" {
  pm_api_url      = "https://proxmox0.${var.domain}:8006/api2/json"
  pm_user         = "${var.user}@${var.domain}"
  pm_password     = var.pass
  pm_tls_insecure = "true"
}

variable "user" {
  type      = string
  sensitive = true
}
variable "pass" {
  type      = string
  sensitive = true
}
variable "ip" {
  type = string
}
variable "hostname" {
  type = string
}
variable "domain" {
  type = string
}

resource "tls_private_key" "temporary" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "freeipa_host" "hostname" {
  fqdn        = "${var.hostname}.${var.domain}"
  description = "This is a test host"
  force       = true
  random      = true
}

resource "proxmox_vm_qemu" "proxmox_vm" {
  count                     = 1
  name                      = var.hostname
  target_node               = "proxmox0"
  clone                     = "ubuntu-20.04"
  os_type                   = "cloud-init"
  agent                     = 1
  cores                     = 4
  cpu                       = "host"
  memory                    = 4096
  scsihw                    = "virtio-scsi-pci"
  guest_agent_ready_timeout = 120
  define_connection_info    = false

  disk {
    slot    = 0
    size    = "8G"
    type    = "virtio"
    storage = "NVMe"
    backup  = 1
  }
  network {
    model  = "virtio"
    bridge = "vmbr0"
    tag    = 2
  }
  lifecycle {
    ignore_changes = [
      network,
    ]
  }
  # Cloud Init Settings
  ipconfig0    = "ip=${var.ip}/24,gw=10.13.2.1"
  nameserver   = "10.13.2.100"
  searchdomain = var.domain
  # disable_password_authentication = false
  ciuser     = "ubuntu"
  cipassword = "ubuntu"
  sshkeys    = <<EOF
  ${tls_private_key.temporary.public_key_openssh}
  EOF

  provisioner "remote-exec" {
    inline = [
      "sleep 30 && DEBIAN_FRONTEND=noninteractive sudo apt-get -o DPkg::Lock::Timeout=240 update -y && DEBIAN_FRONTEND=noninteractive sudo apt-get -o DPkg::Lock::Timeout=240 upgrade -y && DEBIAN_FRONTEND=noninteractive sudo apt-get -o DPkg::Lock::Timeout=240 install -q -y freeipa-client qemu-guest-agent",
      "if hostname | grep ${var.domain} ; then   echo \"Hostname already correct\" ; else   sudo hostnamectl set-hostname $(hostname).${var.domain}; fi",
      "sudo ipa-client-install --unattended --enable-dns-updates --mkhomedir --password \"${freeipa_host.hostname.randompassword}\" && sudo sh -c \"userdel -rf ubuntu && shutdown -r +0\""
    ]
  }

  connection {
    type        = "ssh"
    user        = "ubuntu"
    password    = ""
    private_key = tls_private_key.temporary.private_key_pem
    host        = var.ip
  }

}
{{< /highlight >}}
{{< /details>}}


First two providers are needed `telmate/proxmox` to create resources on a Proxmox host and the provider `camptocamp/freeipa` to interface with FreeIPA.
Then the providers need to be configured.
The provider for FreeIPA expects the host to be without `https` or a subpath, while the one for Proxmox needs the full path to the API endpoint.
You probably also don't want to validate the SSL certificates of the servers when using self-signed certs.
Since I configured LDAP authentication in Proxmox I can use the same user and password for both providers.
However Proxmox needs the `@domain` part to know which authentication provider this user should be authenticated against.

```hcl
provider "freeipa" {
  host     = "ipa.${var.domain}" # or set $FREEIPA_HOST
  username = var.user          # or set $FREEIPA_USERNAME
  password = var.pass          # or set $FREEIPA_PASSWORD
  insecure = true
}
provider "proxmox" {
  pm_api_url      = "https://proxmox0.${var.domain}:8006/api2/json"
  pm_user         = "${var.user}@${var.domain}"
  pm_password     = var.pass
  pm_tls_insecure = "true"
}
```

A pair of temporary SSH private/public keys is also created which will be used later to provision the VM via SSH.
```hcl
resource "tls_private_key" "temporary" {
  algorithm = "RSA"
  rsa_bits  = 4096
}
```

The entry for the host in FreeIPA is created by the following snippet.
The hostname of the newly created machine is stored in a variable named `hostname` and you can also set a description.
The force option will ignore some checks such as an IP address being required to create the host.
The IP address will be set later when running the enrollment command on the VM.
Then a correct DNS record for the host will also be created.
Finally the option `random` has to be set as this will created the random password we will later use to enroll the VM.
It can be accessed as `${freeipa_host.hostname.randompassword}`.

```hcl
resource "freeipa_host" "hostname" {
  fqdn        = "${var.hostname}.${var.domain}"
  description = "This is a test host"
  force       = true
  random      = true
}
```

Finally the VM can be created on Proxmox.
Since the configuration for this resource is fairly extensive, I'll split it into multiple parts.
First the name for the nw VM is set, here the hostname of the machine is used.
Also the `target_node` on which to create the VM is set and the template from which to `clone` the VM.
Setting the `os_type` to `cloud-init` tells Terraform how to provision the VM.
Of course, basic settings like the number of cores and RAM are also set.
Finally a timeout for attempting a connection to the [guest-agent](https://pve.proxmox.com/wiki/Qemu-guest-agent) is set and we also disable the automatic setting up of the connection info for provisioning as we want to define it ourselves.

```hcl
resource "proxmox_vm_qemu" "proxmox_vm" {
  name                      = var.hostname
  target_node               = "proxmox0"
  clone                     = "ubuntu-20.04"
  os_type                   = "cloud-init"
  agent                     = 1
  cores                     = 4
  memory                    = 4096
  guest_agent_ready_timeout = 120
  define_connection_info    = false
```

For the disk which the VM is assigned size, type and the storage on which it should be created need to be set.
Similarly, for the network adapter the model, interface to bridge to and a VLAN tag are set.
Terraform is also instructed to ignore changes to the network adapters of the VM, since details like the MAC address will change.

```hcl
  disk {
    size    = "8G"
    type    = "virtio"
    storage = "NVMe"
  }
  network {
    model  = "virtio"
    bridge = "vmbr0"
    tag    = 2
  }
  lifecycle {
    ignore_changes = [
      network,
    ]
  }
```

Cloud-Init is used to configure details of the VMs operating system such as the IP address and an initial user.
The string `ipconfig0` configures the first network interface.
You can add more in case there are multiple network adapters.
The configuration has to follow the specific syntax seen below.
The `nameserver` is set to the FreeIPA server with which the VM should be enrolled.

Finally we set details for the initial user, which will be deleted later.
Here, we use the temporary SSH key created earlier.

```hcl
  # Cloud Init Settings
  ipconfig0    = "ip=${var.ip}/24,gw=10.13.2.1"
  nameserver   = "10.13.2.100"
  searchdomain = var.domain
  ciuser     = "ubuntu"
  cipassword = "ubuntu"
  sshkeys    = <<EOF
  ${tls_private_key.temporary.public_key_openssh}
  EOF

```
The final part is the provisioning of the newly created VM.
First we'll have to tell Terraform how to connect to it.
We'll connect via SSH and use a variable to set the IP of the VM.
As authentication the the user `ubuntu` we created using Cloud-Init is used together with the temporary SSH private key.

Now we can run commands on the machine.
First we'll run an `apt update` and `apt upgrade`, then install the package FreeIPA client.
The second command makes sure the hostname of the machine is a FQDN as otherwise the install comand will fail.
Finally, in one large command the FreeIPA client is installed.
The OTP we created earlier is used to authenticate the machine.
If the install is successful the temporary user is deleted and the VM is rebooted.
For these final two steps a new shell process is spawned as we are deleting the same user we are logged in as.
Also the command `shutdown -r +0` is used instead of the well-know `reboot` since the latter caused problems.
```hcl
  connection {
    type        = "ssh"
    host        = var.ip
    user        = "ubuntu"
    password    = ""
    private_key = tls_private_key.temporary.private_key_pem
  }

  provisioner "remote-exec" {
    inline = [
      "sleep 30 && DEBIAN_FRONTEND=noninteractive sudo apt-get -o DPkg::Lock::Timeout=240 update -y && DEBIAN_FRONTEND=noninteractive sudo apt-get -o DPkg::Lock::Timeout=240 upgrade -y && DEBIAN_FRONTEND=noninteractive sudo apt-get -o DPkg::Lock::Timeout=240 install -q -y freeipa-client qemu-guest-agent",
      "if hostname | grep ${var.domain} ; then   echo \"Hostname already correct\" ; else   sudo hostnamectl set-hostname $(hostname).${var.domain}; fi",
      "sudo ipa-client-install --unattended --enable-dns-updates --mkhomedir --password \"${freeipa_host.hostname.randompassword}\" && sudo sh -c \"userdel -rf ubuntu && shutdown -r +0\""
    ]
  }
}
```