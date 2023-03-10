---
title: "Enrolling an Unprivileged Proxmox Container in a FreeIPA Domain"
date: 2022-11-20T11:30:03+00:00
# weight: 1
tags: ["FreeIPA", "Proxmox"]
description: "Adopt an unprivileged LXC container into a FreeIPA domain for easy management."
canonicalURL: "https://blog.stabl.one/posts/freeipa-unpriviledged-container/"
editPost:
    URL: "https://github.com/stefanabl/blog"
    Text: "Suggest Changes" # edit text
    appendFilePath: true # to append file path to Edit link
---
LXC containers provide an easy way to run applications on Proxmox with very little overhead compared to virtual machines.
Unprivileged containers provide greater security compared to privileged containers.
Usage of privileged containers is highly discouraged in the [Proxmox documentation](https://pve.proxmox.com/pve-docs/chapter-pct.html#pct_general).
However if you want to enroll LXC containers in a domain managed with FreeIPA, this will not work with unprivileged containers out of the box.

## Why Enrolling an Unprivileged Container is not Possible

An unprivileged LXC container cannot be enrolled, due to the very high UID and GUID numbers used by FreeIPA.
These numbers are used to identify users and groups on Linux systems.
Usually the root user is assigned the UID 0 and the first user created is typically assigned 1000, with everything in between being used for system users.
However, by default FreeIPA uses a range of UID starting at 1850800000.

<!--(Explain mapping)-->

In an unprivileged container the UIDs of the container are mapped to higher UIDs on the host, so that they do not have the privileges of the corresponding user on the host.
 For example the first user created on a Linux system typically has the UID 1000.
 Outside the container however the process might have the UID 90000.
 The following screenshot shows an example for this.
 In the top half we can see the nginx process from the Proxmox hosts point of view where it is running with the UID 100033.
 However inside the container it is running as the user `www-data` which has the UID 33.

![Screenshot to illustrate UIDs](../../posts/freeipa-unpriviledged-container/htop.jpg)

These mappings are defined with a start and end range.
By default it is possible to use UIDs from 0 to 65536 which are offset by 100000, as seen in the screenshot.

## Steps to Enroll an Unprivileged Container in a FreeIPA Domain

Not many changes are needed to to be able to use the higher UIDs created by FreeIPA in an unprivileged LXC container on Proxmox.
First open the configuration file of your container in an editor.
The file is `/etc/pve/lxc/1xx.conf` where `1xx` is the ID of your LXC container.
Add the following to the file:

```
lxc.idmap = u 1850800000 1850800000 200000 
lxc.idmap = g 1850800000 1850800000 200000 
lxc.idmap = u 0 100000 65536 
lxc.idmap = g 0 100000 65536
```
The entries have the following format:
- The `u` or `g` indicates wether the mapping is for user IDs or for group IDs. We need both.
- The first number is the start of the range inside the container
- The second number is the start of the range outside the container. This is not an offset.
- The third number represents the size of range

The FreeIPA UIDs are not mapped to any other ID but stay the same.

Additionally we need to add the range to the files `/etc/subuid` and `/etc/subgid` by appending the following line.

```
root:1850800000:200000
```

Then we can proceed with the enrollment of the container just like with a VM or physical host.

## Conclusion

Making an unprivileged LXC container compatible with the FreeIPA client is not complicated and can be completed in a few simple steps.
Keep in mind that processes started by a FreeIPA user in the container now run with the same UID outside the container which may reduce security slightly.
However there are many other security measures which should prevent escape from a LXC container.

Sources: [Forum entry](https://forum.proxmox.com/threads/can-i-ask-an-uid-range-not-to-be-mapped-in-an-unprivileged-container.49544/), [Proxmox Documentation](https://pve.proxmox.com/wiki/Unprivileged_LXC_containers)

