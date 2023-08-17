---
title: "Retrospect: Managing a Kubernetes Cluster with Ansible "
date: 2022-08-20T11:30:03+00:00
# weight: 1
# aliases: ["/first"]
tags: ["Ansible", "Kubernetes"]
author: "Me"
# author: ["Me", "You"] # multiple authors
showToc: true
TocOpen: false
draft: false
hidemeta: false
comments: true
description: "In this post I present my experience of using Ansible to manage my first Kubernetes cluster."
canonicalURL: "https://blog.stabl.one/posts/ansible-kubernetes/"
disableHLJS: false # to disable highlightjs
disableShare: false
hideSummary: false
searchHidden: true
ShowReadingTime: true
ShowBreadCrumbs: true
ShowPostNavLinks: true
editPost:
    URL: "https://github.com/stefanabl/blog"
    Text: "Suggest Changes" # edit text
    appendFilePath: true # to append file path to Edit link
---
When I first started using Kubernetes it felt only natural to use the same tool to manage it which I (tried) to use for everything else: Ansible.
And that's how I started using Ansible playbooks to manage Kubernetes by applying manifests directly or installing Helm charts.

In this post I want to elaborate how I used Ansible for this task, what was good about it and what was not and finally, why I switched to a different tool now.

## How

Using the Ansible modules `community.core.k8s` to apply YAML manifests directly is basically just automating the use of `kubectl`.
The module `community.core.helm` allows doing the same for Helm charts.
A few examples:

```yaml
- name: install helm chart
  community.core.helm:
    kubeconfig: /etc/rancher/k3s/k3s.yaml # Path to kubeconfig file
    update_repo_cache: yes # Fetch latest information from the helm repository
    name: loki
    chart_ref: grafana/loki-distributed
    chart_version: 0.38.0
    release_namespace: default
    values_files:
      - /root/loki-distributed-values.yml
    values:
      foo: bar
```

This connects to the remote Kubernetes machine and installs the chart.
We can specify a non standard kubeconfig path, or tell Ansible to run `helm repo update` before installing the chart.
We must also specify a name for the install and a reference to the chart as well a namespace.
The values can be kept in a separate file or if only a few values need to specified they can be included directly in the playbook.

To apply manifests with `kubectl`, we can use the module `k8s`.
Using Jinja2 we can retrieve the data from a yaml file and pass it to the module.
Using `from_yaml_all` and `list` it is also possible to apply multiple manifests which are in the same file but separated with `---`.

```
  - name: Apply Manifests
    community.kubernetes.k8s:
      kubeconfig: /etc/rancher/k3s/k3s.yaml
      state: present
      apply: yes
      definition: "{{ lookup('file', 'complete.yml') | from_yaml_all | list }}"
```

## The Good

So why did I stick with Ansible for so long?

Of course there is the problem that switching to a different solution always requires considerable effort and comes with a steep learning curve.
But there are also some things which Ansible did better than my current solution.

### Commit When Ready

Because all the changes are applied from my local machine to the cluster, I can commit them when satisfied with them.
Using [Flux](https://fluxcd.io/), changes are pulled down from the central Git repository and applied to the cluster.
There are exceptions to that and tools like `kubectl` and Helm can still be used, however for the most part applying changes should be done via the detour of the central Git repository.
This has often left me wondering, why the changes I pushed did not have the desired effect, only to find a small error necessitating another commit cluttering up the history.

### Easy Secret Management

Ansible comes with a tool called [Ansible Vault](https://docs.ansible.com/ansible/latest/user_guide/vault.html), which helps you encrypt your secrets.
The secret data is encrypted at rest, meaning it can be safely committed to Git repository, assuming of course you've chosen a good password.
The secrets can then be used like regular variables in Playbooks and template files.
For example in a Kubernetes secret we could easily use variables from a vault like this:

```
stringData:
  access_key: "{{ litestream.access_key}}"
  secret_key: "{{ litestream.secret_key}}"
```

## The Bad

Of course there were also downsides to my approach of using Ansible to manage Kubernetes.
Both points can be traced down to the fact, that the cluster and the central Git repository may be out of sync.

### Multiple People

The approach of using Ansible from your local machine would fall apart quickly when trying to use it in a team, as it is just a fancy wrapper around `kubectl`.
One cannot be sure if the status in the Git repository is actually what is running in the cluster.
Running a playbook and applying the manifests can be forgotten or changes can be made locally which have not yet been committed.

Additionally, using Ansible vault to manage secrets requires sharing the password to the vault with others which is usually not a good practice.

### Repository and Cluster out of Sync

With tools like Flux or a sophisticated CI/CD pipeline the cluster is kept in sync with the source repository.
With Ansible you are responsible for keeping the two in sync unless you set up a CI/CD pipeline yourself.
Not only does this affect being able to work on a cluster together in a team, but also limits the usefulness of tools such as [Renovate](https://docs.renovatebot.com/).
When Renovate detects an update for a component running in your cluster, it opens a pull request allowing you to quickly update the component.
However when using Ansible from your local machine, you are still responsible for applying these update by running a playbook.
A task which can easily be forgotten.

## Conclusion

As stated earlier I finally made the switch to using Flux to manage my homelab cluster.
It integrates better with tools such as Renovate and forces me to adhere to the Infrastructure-as-Code principle.