---
title: "Deploying the UniFi SDN Controller on Kubernetes"
date: 2023-08-27T07:30:03+00:00
# weight: 1
tags: ["Kubernetes", "UniFi"]
comments: true 
description: "Run the UniFi SDN controller on Kubernetes using Ingress Nginx"
canonicalURL: "https://blog.stabl.one/posts/006-unifi-controller-kubernetes/"
editPost:
    URL: "https://github.com/stefanabl/blog/tree/main/content"
    Text: "Suggest Changes" # edit text
    appendFilePath: true # to append file path to Edit link
---
The Ubiquity UniFi line of network devices has long been a top choice among small businesses and networking enthusiasts for their WiFi access points, switches, and more.
One of the key aspects of managing these devices is the requirement for a controller, which can be installed on a separate device or self-hosted.
In this blog post, I'll guide you through the process of hosting your Ubiquiti UniFi controller in a Kubernetes cluster while utilizing Ingress Nginx to make it accessible over the internet.

First we create the Kubernetes Stateful Set which runs the application and then take a closer look at how traffic reaches it.
In my case I needed to also migrate the data from my old controller instance and update the inform URL.

## Running the Application

The application is deployed as a Kubernetes Stateful Set which is centred around the awesome [Docker image](https://github.com/jacobalberty/unifi-docker#environment-variables) created by Jacob Alberty.
To improve security, various options are set such as running the container as a non-root user.
The image uses the user with the ID 999 and an init-container is used to make sure that the storage is accessible to this user.
A PVC takes care of the storage needed by the UniFi Controller application, in my case the storage is provided by [Longhorn](https://longhorn.io/).
The UniFi SDN Controller relies on [MongoDB](https://www.mongodb.com/) for data storage.
The great news is that the Docker image we're using comes with an integrated MongoDB instance. This means there's no need for a separate MongoDB deployment, simplifying our deployment.
The configuration of the Docker image is done via environment variables, however there is not much to configure.
It is recommended to set a timezone via the variable `TZ` and the application is also configured to log to stdout (also known as the console) in addition to a log file.
This is especially helpful when using a centralized logging Platform such as ElasticSearch or Grafana Loki.
Finally, the most important ports are defined.
These are `8443` for the Web UI via HTTPS, `8080` which can be used to connect UniFi devices via HTTP and `3478` for the STUN traffic which is used for example for the interactive console in the Web UI. 

Overall pretty standard for an application in Kubernetes.

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: unifi
spec:
  selector:
    matchLabels:
      app: unifi
  serviceName: unifi
  replicas: 1
  template:
    metadata:
      labels:
        app: unifi
      annotations:
        container.apparmor.security.beta.kubernetes.io/unifi: runtime/default
        seccomp.security.alpha.kubernetes.io/pod: runtime/default
    spec:
      securityContext:
        runAsUser: 999
        runAsGroup: 999
      initContainers:
      - name: fix-permissions
        image: busybox
        command: ["sh", "-c", "chown -R 999:999 /unifi"]
        securityContext:
          runAsUser: 0
          runAsNonRoot: false
        volumeMounts:
          - name: unifi
            mountPath: /unifi
      containers:
        - name: unifi
          image: jacobalberty/unifi:v7.4.162
          env:
            - name: TZ
              value: EUROPE/BERLIN
            - name: UNIFI_STDOUT
              value: "true"
          ports:
            - containerPort: 8080
              name: inform
            - containerPort: 8443
              name: ui
            - containerPort: 3478
              name: stun
              protocol: UDP
          volumeMounts:
            - name: unifi
              mountPath: /unifi
            - name: tmp
              mountPath: /tmp
          resources:
            requests:
              memory: 1Gi
              cpu: 250m
            limits:
              memory: 2Gi
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
            privileged: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
      volumes:
        - name: tmp
          emptyDir: {}
        - name: unifi
          persistentVolumeClaim:
            claimName: unifi
      automountServiceAccountToken: false
```

## Get Traffic to the Application 

Making the UniFi Controller accessible from the internet involves a few intricacies, setting it apart from many other web applications.
This is because a Kubernetes Ingress can only serve HTTP(S) traffic.
Consequently, traffic on port `8080` and especially the UDP traffic for the STUN protocol would necessitate a service of the [type](https://kubernetes.io/docs/concepts/services-networking/service/#publishing-services-service-types) LoadBalance to be reachable from outside the cluster.
However, the [Ingress Nginx](https://github.com/kubernetes/ingress-nginx) allows for a workaround, allowing us to configure and expose ports other than the standard 80/443 for HTTP(S).


Nonetheless, an internal service has to be created which makes the application reachable inside the cluster.
Of course it needs to be configured with all three ports, but don't forget the field `name` and also set the field `protocol` for the traffic over the port `3478`, like so:

```yaml
ports:
- port: 3478
  targetPort: 3478
  protocol: UDP
  name: stun
```
An Ingress Object is needed to access the Web UI of the UniFi Controller.
For the Ingress to function properly, some additional configuration is needed which is specific to the Nginx Controller used for Ingress.
This is done by setting some annotations.

The first annotation is necessary because the UniFi controller application does not expose the Web UI via HTTP but rather secured by TLS via HTTPS.
If the annotation is not set, you will get the error "Bad Request This combination of host and port requires TLS."

The second annotation is necessary if you plan to restore the application from a backup file.
In the default configuration the maximum body size of POST requests is restricted.
Setting the body size to 0 with this annotation effectively allows for an "unlimited" body size.

Finally, I also had to add some additional configuration snippets to the Nginx Ingress.
This is because in my specific setup there is an additional reverse proxy between the client and the Kubernetes Ingress.
Without the settings for the headers Origin and Referer, the Web UI of the UniFi SDN controller would not work properly.

With the manifest below, the Web UI will be reachable from outside the cluster.
However, it's worth noting that additional ports will also need to be exposed, which we'll explore in the upcoming section.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: unifi
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: HTTPS
    nginx.ingress.kubernetes.io/proxy-body-size: "0"
    nginx.ingress.kubernetes.io/configuration-snippet: |
      proxy_set_header Origin '';
      proxy_set_header Referer '';
spec:
  ingressClassName: nginx
  tls:
  - hosts: [ "unifi.${DOMAIN}" ]
    secretName: unifi-cert
  rules:
  - host: unifi.${DOMAIN}
    http:
      paths:
        - path: "/"
          pathType: Prefix
          backend:
            service:
              name: unifi
              port:
                number: 8443

```

Although a Kubernetes Ingress object can only forward HTTP(S) traffic, it is possible to [expose TCP and UDP services](https://github.com/kubernetes/ingress-nginx/blob/main/docs/user-guide/exposing-tcp-udp-services.md) via the Ingress Nginx controller.
If it is installed via a Helm Chart this is even more straightforward.
Simply add a mapping between the exposed ports and the service which should be exposed within the Helm Chart's values.
This can be done by adding entries to the respective `udp` or `tcp` sections.

```yaml
udp:
  "3478": "default/unifi:3478"
tcp:
  "8080": "default/unifi:8080"
```

Now all the necessary ports for the UniFi SDN controller are exposed via the Ingress Nginx.

## Migration and Final Steps

Finally, existing data can be migrated from the old controller according to the documentation offered by [Ubiquity](https://help.ui.com/hc/en-us/articles/360008976393-UniFi-Backups-and-Migration).

If the hostname or IP address of your controller has changed, you might need to update the configuration on some of your devices.
Therefore, SSH into the device using the credentials provided under Settings > Site > Device Authentication.
Then, use the command `set-inform http(s)://<url>/inform` to update the IP or hostname of the controller.

If you read this post, liked it, found it helpful or if you have some criticism, please leave a comment below.
