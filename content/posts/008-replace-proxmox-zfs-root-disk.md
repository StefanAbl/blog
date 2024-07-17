---
title: "Replacing a boot disk in the ZFS pool of your Proxmox installation"
date: 2024-07-15T20:30:03+00:00
# weight: 1
tags: ["Proxmox", "ZFS"]
comments: true 
description: "Expand your storage or replace a failing drive"
showtoc: true
canonicalURL: "https://blog.stabl.one/posts/008-replace-proxmox-zfs-root-disk/"
editPost:
    URL: "https://github.com/stefanabl/blog/tree/main/content"
    Text: "Suggest Changes" # edit text
    appendFilePath: true # to append file path to Edit link
---

When I expanded my homelab I bought two mini PCs.
One Dell DeskMini and a Lenovo ThinkCenter.
While the 16GB of RAM and 512GB NVMe SSD of the Lenovo are enough for many homelab needs, I wanted to expand both to match the Dells 32GB/1TB.
Especially since I have two 16GB sticks of SO-DIMM memory and a 1TB SSD from my old laptop just laying around collecting dust.

Expanding the memory is easy, just open the bottom access hatch of the ThinkCenter take out the old RAM and install the new one.
However, swapping a boot drive is harder, especially since it is also using ZFS.
Luckily, users on the Proxmox Forum have also had this problem.
Thank you to them for documenting the commands [here](https://forum.proxmox.com/threads/moving-boot-disk-to-new-disks.105543/).

## Connecting both drives

Since the mini PC only has one NVMe for SSDs I connected the new 1TB drive via a USB to M.2 enclosure first.

Then the drive has to be identified.
For this I used `lsblk` and `ls -lah /dev/disk/by-id/`.

## Copy the Data

First, I used the command `sgdisk` as described in the forum post to copy the old drives partition layout.
```bash
sgdisk /dev/disk/by-id/existingdrive -R /dev/disk/by-id/newdrive
```
Then, I used the tool again to assign new, random partition IDs to the new drive.
```bash
sgdisk -G /dev/disk/by-id/newdrive
```

Next, the data from the ZFS zpool has to be copied.
The post in the Proxmox forum suggests using `zpool attach` for this, however this turned out to be the wrong command for me.
Instead of replacing the drive, it adds the new drive to the zpool to create a mirror. 
Fortunately, I was easily able to resolve this problem by using `zpool offline` and `zpool detach` on the old drive.

The better command might be:
```bash
zpool replace rpool /dev/disk/by-id/existingdrive-part3 /dev/disk/by-id/newdrive-part3
```

This will start the resilvering of the zpool instantly, meaning the data from the old drive is copied to the new one.
Its progress can be monitored with the `zpool status` command.

## Make the New Drive Bootable

While the resilver is running, I used the time to enable Proxmox to boot from the new drive.
For this I used a command line tool from Proxmox.

When running the commands, make sure to specify the correct drive and the correct **partition** (denoted by the number behind the drive).

```bash
pve-efiboot-tool format /dev/sdX2 (sdX being the new drive)
pve-efiboot-tool init /dev/sdX2 (sdX being the new drive)
pve-efiboot-tool refresh
```

## Finishing up

With the ZFS resilver finished I was almost done.
All that was left was shutting down the node and physically swapping the drives.

Moment of truth: Would the server still boot?

Yes! After some time, it was back online and a quick look in the Web UI confirmed: 32GB RAM and a 1TB SSD.

Now all that was left to do, was to expand the partition ZFS is using to take advantage of the extra 500GB.
For this, the command `growpart` can be used, where 3 is the number of the partition to expand.
Then use the `zpool online` command to make ZFS aware of the additional space available.

```bash
growpart /dev/nvme0n1 3

zpool online -e rpool nvme0n1p3
```

And with that the disk is swapped and we can take advantage of the expanded space!