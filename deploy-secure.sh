#!/bin/bash
set -e

WORKING_DIR="3-tier-deployment"

# clean it up if it already exists
rm -rf "$WORKING_DIR"


# Create the Base and overlay directories for both application
mkdir -p "$WORKING_DIR/base/postgres"
mkdir -p "$WORKING_DIR/base/fact-backend"
mkdir -p "$WORKING_DIR/base/fact-frontend"
mkdir -p "$WORKING_DIR/overlay/backend-env-secure"
mkdir -p "$WORKING_DIR/overlay/frontend-env-secure"

# Create the base deployment files for the application; starting with the pvc, configmap, secrets, services and deployement
cat <<EOF > "$WORKING_DIR/base/postgres/postgres-pvc.yaml"
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-pvc-secure
spec:
  accessModes:
    - ReadWriteOnce
  volumeMode: Filesystem
  resources:
    requests:
      storage: 1Gi
EOF

# Check if the secret already exists in the backend namespace
echo "Checking for existing credentials..."
EXISTING_SECRET=$(kubectl get secret postgres-cred -n backend-secure --ignore-not-found -o jsonpath='{.data.POSTGRES_PASSWORD}' || echo "")

if [ -n "$EXISTING_SECRET" ]; then
    echo "✅ Existing secret found. Reusing credentials to maintain DB connectivity."
    # We decode it so it can be re-encoded correctly by the 'kubectl create secret' command below
    POSTGRES_PASSWORD=$(echo "$EXISTING_SECRET" | base64 --decode)
else
    echo "🔑 No existing secret found. Generating high-entropy random password..."
    POSTGRES_PASSWORD=$(openssl rand -base64 32)
fi



# Create a variable containing a random secret string for the postgres password and user and use it as a file to create the secrets for the application using the imperative command and output it to a yaml file in the base directory for the postgres application
#POSTGRES_PASSWORD=$(openssl rand -base64 32)

# imperative commands to create the configmap, secrets, services and deployment for the application

kubectl create configmap postgres-config --from-literal=POSTGRES_DB=factsdb --from-literal=POSTGRES_HOST=postgres-svc --from-literal=POSTGRES_PORT="5432" --dry-run=client -o yaml > "$WORKING_DIR/base/postgres/postgres-configmap.yaml"

# Create the secrets for the application
kubectl create secret generic postgres-cred --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD" --from-literal=POSTGRES_USER=admin --dry-run=client -o yaml > "$WORKING_DIR/base/postgres/postgres-secrets.yaml"

# Create the service for the application
kubectl create svc clusterip postgres-svc --tcp=5432:5432 --dry-run=client -o yaml > "$WORKING_DIR/base/postgres/postgres-service.yaml"

# Create the deployment for the application
kubectl create deployment postgres --image=postgres:15-alpine --dry-run=client -o yaml > "$WORKING_DIR/base/postgres/postgres-deployment.yaml"

# Create a service account for the backend application
kubectl create serviceaccount fact-backend-sa --dry-run=client -o yaml > "$WORKING_DIR/base/fact-backend/backend-serviceaccount.yaml"

# Imperative command to create the fact application deployment
kubectl create deployment fact-backend-deployment --image=succesc/fact-app-s:v3 --port=5000 --dry-run=client -o yaml > "$WORKING_DIR/base/fact-backend/backend-deployment.yaml"

# Imperative command to create the service for the fact application
kubectl create svc clusterip backend-svc --tcp=5000:5000 --dry-run=client -o yaml > "$WORKING_DIR/base/fact-backend/backend-service.yaml"

# create the configmap for the fact-frontend application containing the index.html file 
kubectl create configmap frontend-html-index --from-file=index.html=./index.html --dry-run=client -o yaml > "$WORKING_DIR/base/fact-frontend/frontend-configmap.yaml"

# create the configmap for the fact-frontend application containing the nginx.conf file
kubectl create configmap frontend-nginx-conf --from-file=nginx.conf=./default.conf --dry-run=client -o yaml > "$WORKING_DIR/base/fact-frontend/frontend-nginx-configmap.yaml"

# Create the deployment for the fact-frontend application using a nginx:alpine image and mount the configmaps for the index.html and nginx.conf files
kubectl create deployment fact-frontend-deployment --image=nginx:alpine --port=8080 --dry-run=client -o yaml > "$WORKING_DIR/base/fact-frontend/frontend-deployment.yaml"

# Create the service for the fact-frontend application
kubectl create svc nodeport frontend-svc --tcp=80:8080 --dry-run=client -o yaml > "$WORKING_DIR/base/fact-frontend/frontend-service.yaml"


# create overlay for the backend namespace
mkdir -p "$WORKING_DIR/overlay/backend-env-secure"

# create the namespace for the backend (db and fact backend) application and add the necessary labels for the pod security policies
cat <<EOF > "$WORKING_DIR/overlay/backend-env-secure/namespace.yaml"
apiVersion: v1
kind: Namespace
metadata:
    name: backend-secure
    labels:
        pod-security.kubernetes.io/enforce: restricted
EOF


#create the kustomization.yaml file for the base postgres application and the fact application
cat <<EOF > "$WORKING_DIR/base/postgres/kustomization.yaml"
resources:
- postgres-pvc.yaml
- postgres-configmap.yaml
- postgres-secrets.yaml
- postgres-service.yaml
- postgres-deployment.yaml

namespace: backend-secure

labels:
- pairs:
    app: postgres-app
  includeSelectors: true
  includeTemplates: true
CommonAnnotations:
  Pager: This was deployed by Su's CKAD Lab
EOF


# Create the kustomization.yaml file for the base fact backend application
cat <<EOF > "$WORKING_DIR/base/fact-backend/kustomization.yaml"
resources:
- backend-deployment.yaml
- backend-service.yaml
- backend-serviceaccount.yaml

namespace: backend-secure

labels:
- pairs:
    app: fact-backend
  includeSelectors: true
  includeTemplates: true
CommonAnnotations:
  Pager: This was deployed by Su's CKAD Lab
EOF



# create one overlay for the frontend namespace
mkdir -p "$WORKING_DIR/overlay/frontend-env-secure"


# create the namespace for the frontend application and add the necessary labels for the pod security policies
cat <<EOF > "$WORKING_DIR/overlay/frontend-env-secure/namespace.yaml"
apiVersion: v1
kind: Namespace
metadata:
    name: frontend-secure
    labels:
        pod-security.kubernetes.io/enforce: restricted
EOF


# Create the kustomization.yaml file for the base fact-frontend application
cat <<EOF > "$WORKING_DIR/base/fact-frontend/kustomization.yaml"
resources:
- frontend-configmap.yaml
- frontend-nginx-configmap.yaml
- frontend-deployment.yaml
- frontend-service.yaml

namespace: frontend-secure

labels:
- pairs:
    app: fact-frontend
  includeSelectors: true
  includeTemplates: true
CommonAnnotations:
  Pager: This was deployed by Su's CKAD Lab
EOF


# Imperative command to create the resouce quota for the namespace and add the necessary limits for the cpu and memory resources
kubectl create resourcequota backend-app-rq --namespace=backend-secure --hard=cpu=2,memory=4Gi --dry-run=client -o yaml > "$WORKING_DIR/overlay/backend-env-secure/resource-quota.yaml"

# Create a Limit Range for the namespace to set default resource limits for the containers
cat <<EOF > "$WORKING_DIR/overlay/backend-env-secure/limit-range.yaml"
apiVersion: v1
kind: LimitRange
metadata:
  name: test-app-limit
  namespace: backend-secure
spec:
  limits:
  - default:
      cpu: 400m
      memory: 512Mi
    defaultRequest:
      cpu: 100m
      memory: 128Mi
    type: Container
EOF


# imperative command to create the resouce quota for the namespace and add the necessary limits for the cpu and memory resources
kubectl create resourcequota frontend-app-rq --namespace=frontend-secure --hard=cpu=2,memory=4Gi --dry-run=client -o yaml > "$WORKING_DIR/overlay/frontend-env-secure/resource-quota.yaml"


# Create a Limit Range for the frontend namespace to set default resource limits for the containers
cat <<EOF > "$WORKING_DIR/overlay/frontend-env-secure/limit-range.yaml"
apiVersion: v1
kind: LimitRange
metadata:
  name: test-app-limit
  namespace: frontend-secure
spec:
  limits:
  - default:
      cpu: 300m
      memory: 512Mi
    defaultRequest:
      cpu: 100m
      memory: 128Mi
    type: Container
EOF


# Creat the patch file for the postgres deployment containing the env variable, mount path and volumes
cat <<'EOF' > "$WORKING_DIR/overlay/backend-env-secure/postgres-deployment-patch.yaml"
- op: add
  path: /spec/template/spec/automountServiceAccountToken
  value: false

- op: add
  path: /spec/template/spec/containers/0/env
  value:
  - name: PGDATA
    value: "/var/lib/postgresql/data/pgdata"
  - name: POSTGRES_INITDB_ARGS
    value: "--locale=C.UTF-8"
  - name: POSTGRES_DB
    valueFrom:
      configMapKeyRef:
        name: postgres-config
        key: POSTGRES_DB
  - name: POSTGRES_USER
    valueFrom:
      secretKeyRef:
        name: postgres-cred
        key: POSTGRES_USER
  - name: POSTGRES_PASSWORD
    valueFrom:
      secretKeyRef:
        name: postgres-cred
        key: POSTGRES_PASSWORD

- op: add
  path: /spec/template/spec/volumes
  value:
  - name: pvc-volume
    persistentVolumeClaim:
      claimName: postgres-pvc-secure
  - name: tmp-volume
    emptyDir: {}

- op: add
  path: /spec/template/spec/containers/0/volumeMounts
  value:
  - name: pvc-volume
    mountPath: /var/lib/postgresql/data
  - name: tmp-volume
    mountPath: /var/run/postgresql

- op: add
  path: /spec/template/spec/securityContext
  value:
    fsGroup: 70

- op: add
  path: /spec/template/spec/containers/0/securityContext
  value:
    runAsUser: 70
    runAsGroup: 70
    allowPrivilegeEscalation: false
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
    capabilities:
      drop: ["ALL"]
EOF

# Create the Default Network Policy for the backend namespace to deny all ingress and egress traffic by default
cat <<EOF > "$WORKING_DIR/overlay/backend-env-secure/default-deny.yaml"
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
EOF

# Create the allow Dns ingress and Egress for all pods
cat <<EOF > "$WORKING_DIR/overlay/backend-env-secure/allow-dns.yaml"
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
spec:
  podSelector: {}
  policyTypes:
  - Egress
  egress:
    - to:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: kube-system
      ports:
      - protocol: UDP
        port: 53
      - protocol: TCP
        port: 53
EOF


# Create the allow Frontend to Backend Ingress Network Policy for the backend namespace
cat <<EOF > "$WORKING_DIR/overlay/backend-env-secure/allow-frontend-to-backend.yaml"
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
    name: allow-frontend-to-backend
spec:
    podSelector:
        matchLabels:
            app: fact-backend
    policyTypes:
    - Ingress
    ingress:
    - from:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: frontend-secure
      - podSelector:
          matchLabels:
            app: fact-frontend
      ports:
      - protocol: TCP
        port: 5000

EOF

# Create the Allow backend to Postgres Ingress Network Policy for the backend namespace
cat <<EOF > "$WORKING_DIR/overlay/backend-env-secure/backend-to-postgres.yaml"
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
    name: allow-backend-to-postgres-ingress
spec:
    podSelector:
      matchLabels:
        app: postgres-app
    policyTypes:
    - Ingress
    ingress:
    - from:
      - podSelector:
          matchLabels:
            app: fact-backend
      ports:
      - protocol: TCP
        port: 5432

---

apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
    name: allow-backend-to-postgres-egress
spec:
    podSelector:
      matchLabels:
        app: fact-backend
    policyTypes:
    - Egress
    egress:
    - to:
      - podSelector:
          matchLabels:
            app: postgres-app
      ports:
      - protocol: TCP
        port: 5432
EOF

# Create the allow egress from frontend to backend Network Policy for the frontend namespace
cat <<EOF > "$WORKING_DIR/overlay/frontend-env-secure/allow-frontend-to-backend.yaml"
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
    name: allow-frontend-to-backend
spec:
    podSelector:
        matchLabels:
            app: fact-frontend
    policyTypes:
    - Egress
    egress:
    - to:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: backend-secure
      - podSelector:
          matchLabels:
            app: fact-backend
      ports:
      - protocol: TCP
        port: 5000
EOF

# Create the Default Network Policy for the frontend namespace to deny all ingress and egress traffic by default
cat <<EOF > "$WORKING_DIR/overlay/frontend-env-secure/default-deny.yaml"
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
EOF

# Create the allow Dns Egress for all pods
cat <<EOF > "$WORKING_DIR/overlay/frontend-env-secure/allow-dns.yaml"
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
spec:
  podSelector: {}
  policyTypes:
  - Egress
  egress:
    - to:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: kube-system
      ports:
      - protocol: UDP
        port: 53
      - protocol: TCP
        port: 53
EOF

# Create the overlay kustomization.yaml file for the overlay directory
cat <<EOF > "$WORKING_DIR/overlay/backend-env-secure/kustomization.yaml"
resources:
- ../../base/postgres
- ../../base/fact-backend
- namespace.yaml
- resource-quota.yaml
- limit-range.yaml
- default-deny.yaml
- allow-dns.yaml
- allow-frontend-to-backend.yaml
- backend-to-postgres.yaml

namespace: backend-secure

patches:
- target:
    kind: Deployment
    name: postgres
  path: postgres-deployment-patch.yaml

- target:
    kind: Deployment
    name: fact-backend-deployment
  path: fact-backend-deployment-patch.yaml
EOF



# Create the overlay kustomization.yaml file for the frontend overlay directory
cat <<EOF > "$WORKING_DIR/overlay/frontend-env-secure/kustomization.yaml"
resources:
- ../../base/fact-frontend
- namespace.yaml
- resource-quota.yaml
- limit-range.yaml  
- default-deny.yaml
- allow-dns.yaml
- allow-frontend-to-backend.yaml

namespace: frontend-secure

patches:
- target:
    kind: Deployment
    name: fact-frontend-deployment
  path: fact-frontend-deployment-patch.yaml
EOF


# Create the overlay patch file for the fact application deployment containing the env variable, mount path and volumes
cat <<'EOF' > "$WORKING_DIR/overlay/backend-env-secure/fact-backend-deployment-patch.yaml"
- op: add
  path: /spec/template/spec/serviceAccountName
  value: fact-backend-sa

- op: add
  path: /spec/template/spec/automountServiceAccountToken
  value: false

- op: add
  path: /spec/template/spec/volumes
  value:
  - name: temp-volume
    emptyDir: {}

- op: add
  path: /spec/template/spec/securityContext
  value:
    fsGroup: 2000
    runAsGroup: 3000
    runAsUser: 1000
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault

- op: add
  path: /spec/template/spec/containers/0/securityContext
  value:
    allowPrivilegeEscalation: false
    capabilities:
      drop: ["ALL"]
    readOnlyRootFilesystem: true

- op: add
  path: /spec/template/spec/containers/0/env
  value:
  - name: POSTGRES_USER
    valueFrom:
      secretKeyRef:
        name: postgres-cred
        key: POSTGRES_USER
  - name: POSTGRES_PASSWORD
    valueFrom:
      secretKeyRef:
        name: postgres-cred
        key: POSTGRES_PASSWORD
  - name: POSTGRES_DB
    valueFrom:
      configMapKeyRef:
        name: postgres-config
        key: POSTGRES_DB
  - name: POSTGRES_HOST
    valueFrom:
      configMapKeyRef:
        name: postgres-config
        key: POSTGRES_HOST
  - name: POSTGRES_PORT
    valueFrom:
      configMapKeyRef:
        name: postgres-config
        key: POSTGRES_PORT
  - name: DATABASE_URL
    value: "postgresql://$(POSTGRES_USER):$(POSTGRES_PASSWORD)@$(POSTGRES_HOST):$(POSTGRES_PORT)/$(POSTGRES_DB)"

- op: add
  path: /spec/template/spec/containers/0/volumeMounts
  value:
  - name: temp-volume
    mountPath: /tmp
- op: add
  path: /spec/template/spec/containers/0/livenessProbe
  value:
    httpGet:
      path: /health
      port: 5000
    initialDelaySeconds: 30
    periodSeconds: 10

- op: add
  path: /spec/template/spec/containers/0/readinessProbe
  value:
    httpGet:
      path: /health
      port: 5000
    initialDelaySeconds: 15
    periodSeconds: 5

- op: add
  path: /spec/template/spec/initContainers
  value:
  - name: wait-for-db
    image: busybox:1.36
    command: ['sh', '-c', 'until nc -z $(POSTGRES_HOST) $(POSTGRES_PORT); do echo "Waiting for database..."; sleep 5; done;']
    env:
    - name: POSTGRES_HOST
      valueFrom:
        configMapKeyRef:
          name: postgres-config
          key: POSTGRES_HOST
    - name: POSTGRES_PORT
      valueFrom:
        configMapKeyRef:
          name: postgres-config
          key: POSTGRES_PORT
- op: add
  path: /spec/template/spec/initContainers/0/securityContext
  value:
    runAsUser: 1000
    runAsNonRoot: true
    allowPrivilegeEscalation: false
    seccompProfile:
      type: RuntimeDefault
    capabilities:
      drop: ["ALL"]
    readOnlyRootFilesystem: true

- op: add
  path: /spec/template/spec/initContainers/0/volumeMounts
  value:
  - name: temp-volume
    mountPath: /tmp
EOF


# Create the overlay patch file for the fact-frontend application deployment containing the, mount path and volumes
cat <<'EOF' > "$WORKING_DIR/overlay/frontend-env-secure/fact-frontend-deployment-patch.yaml"
- op: add
  path: /spec/template/spec/automountServiceAccountToken
  value: false

- op: add
  path: /spec/template/spec/containers/0/securityContext
  value:
    runAsUser: 101
    runAsNonRoot: true
    allowPrivilegeEscalation: false
    seccompProfile:
      type: RuntimeDefault
    capabilities:
      drop: ["ALL"]
    readOnlyRootFilesystem: true

- op: add
  path: /spec/template/spec/volumes
  value:
  - name: html-index-volume
    configMap:
      name: frontend-html-index
  - name: nginx-conf-volume
    configMap:
      name: frontend-nginx-conf
  - name: tempvolume-cache
    emptyDir: {}
  - name: tempvolume
    emptyDir: {}
    
- op: add
  path: /spec/template/spec/containers/0/volumeMounts
  value:
  - name: html-index-volume
    mountPath: /usr/share/nginx/html/index.html
    subPath: index.html
    readOnly: true
  - name: nginx-conf-volume
    mountPath: /etc/nginx/conf.d/default.conf
    subPath: nginx.conf
    readOnly: true
  - name: tempvolume-cache
    mountPath: /var/cache/nginx
  - name: tempvolume
    mountPath: /var/run
  - name: tempvolume
    mountPath: /tmp
EOF

#run kustomize to view the final manifest for the overlay directory
echo "------------- Backend Application Manifest -------------"
kubectl kustomize "$WORKING_DIR/overlay/backend-env-secure"


# sleep for 10 seconds to allow the user to view the final manifest before applying it to the cluster or deleting the working directory
#sleep 120

#confirm with the user if they want to apply the manifest to the cluster
read -p "Do you want to apply the manifest to the cluster? (y/n) " REPLY
if [[ "$REPLY" == "y" ]]; then
    kubectl apply -k "$WORKING_DIR/overlay/backend-env-secure"
fi

# run kustomize to view the final manifest for the frontend overlay directory
echo "------------- Frontend Application Manifest -------------"
kubectl kustomize "$WORKING_DIR/overlay/frontend-env-secure"

# confirm with the user if they want to apply the manifest to the cluster
read -p "Do you want to apply the manifest for the frontend application to the cluster? (y/n) " REPLY
if [[ "$REPLY" == "y" ]]; then
    kubectl apply -k "$WORKING_DIR/overlay/frontend-env-secure"
fi




