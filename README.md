# 🔒 3-Tier K8s Hardening: Phase 2 (Zer0-Trust)

**Author**: Su (CKAD, Sec+ Candidate)

**Goal**: Hardening a functional 3-tier application from `Privileged` to `Restricted` Pod Security Standards.

## The Security Pivot: From Phase 1 to Phase 2

Phase 1 focused on functionality.

## Phase 1 - The Insecure Defaults (Before)

### 1. Pod runs as root

![alt text](image.png)

> why it's bad: Any container breakout gives the threat-actor host-level root privileges.

A Container is not a lighteight VM. it is a normal linux process running on the host-OS
it uses two linux kernel features to create the illusion of isolation (namespaces and C-groups) A container is just a process sharing the host kernel, so the permission of the user running the process is critical. by default many public container images (nginx) run their entry point process as root. the uid inside the container is exactly the same as the uid on the host. 

### 2. Writable root fileSystem

![alt text](image-1.png)

> Threat-Actor can plant binaries, modify application code, which can persist across restarts. **filesystem is mutable**


### 3. Default Service account token mounted 

![alt text](image-2.png)

> Most of the time your application might never make use of that token. and if the pod is compromised, the threat-actor can obtain the pod's identity which often has a wide-level state permissions.

(if an attacker achieves remote code execution, they can check for this secrets directory, and attach this token for use.)

### 4. Excess Linux Capabilities

![alt text](image-8.png)

The default state is too permissive, even an un-privliege user still have all these linux capabilities given to it.
default capabilities include `CAP_CHOWN`, `CAP_DAC_OVERRIDE`, `CAP_NET_RAW` which are all unnecessary for a web app. 

Most microservices dont need them. 


### 5. Privilege Escalation Allowed

![alt text](image-3.png)

A process inside the container can gain more privileges (e.g., via setuid binary)
a child process can acquire more privilege than it parent process. with `NoNewPrivs = 0`


### 6. Pod Security Admission = Privileged

![alt text](image-4.png)

the default is `privileged` which means allow everything with the highest level of permission.

### 7. No Network Policies - flat, Open Communications

![alt text](image-5.png)

Any pod can talk to any other.

![alt text](image-6.png)

Kubernetes has a flat unrouted network space, and its network implementation is handled by the CNi-Plugin (calico, cillium etc.) and the model strictly dictates that
> Every Pod must be able to communicate with every other pod across all namespaces without any network address translation.

so a pod in `namespace-1` which does not have any business or application communication needs with a highly secured database in a different namespace say `namespace-2` can automatically communicate with it by default. 


### 8. Secrets in Environment variable 

![alt text](image-7.png)





## 🔒 Phase 2 - The Hardenening State (After)

## The Security Pivot: From Phase 1 to Phase 2

**Phase-1** focused on functionality. **Phase-2** focuses on defense-in-depth. 
> I have transitioned the architecture to follow the **NSA/CISA** Kubernetes Hardening Guidance.


### 1. Pod Security Admission = restricted

- **The Default (Phase 1)**: `privileged` (Allows everything, including host-level access).

- **The Hardened State**: `restricted`.

Every pod now must pass strict validation before the API server accepts it. This prevents "Shadow IT" or insecure manifests from being deployed.

![alt text](<Screenshot 2026-04-13 230537.png>)


### 2.  Multi-Namespace Isolation & Network Segmentation Design
- **Frontend namespace** (`frontend-secure`): Nginx only, public traffic.
- **Backend namespace** (`backend-secure`): Flask API + PostgreSQL, no external ingress.
- **Network Policies** :
    - default deny All: All ingress/egress is blocked by default.
    - explicit allow rules: Only `frontend` -> `backend` (Port 5000) and `backend` -> `database` (Port 5432) are permitted.

![alt text](<Screenshot 2026-04-13 230705.png>)

### 3. Security contexts (non‑root, read‑only root, dropped caps)
The **Principle of Least Privilege** was applied to the container runtime.
- Immutable Root Filesystem: `readOnlyRootFilesystem: true` prevents attackers from planting malware or modifying application code.

- Non-Root Execution: Containers run as specific UIDs (`70` for `Postgres`, `101` for `Nginx`, `1000` for `Backend`). This prevents a container breakout from granting host-root access.

![alt text](<Screenshot 2026-04-13 230751.png>)

- Capability Dropping: All Linux capabilities (`CAP_SYS_ADMIN`, etc.) are dropped, reducing the kernel attack surface.

![alt text](<Screenshot 2026-04-13 231051.png>)

- Privilege Escalation: Explicitly set `allowPrivilegeEscalation: false` to block setuid binary exploits.

![alt text](<Screenshot 2026-04-13 232525.png>)

Screenshot of `touch /testing` failing, `touch /tmp/testing` succeeding.

### 4. Service account tokens disabled
- `automountServiceAccountToken: false` for all deployments.

![alt text](<Screenshot 2026-04-13 230918.png>)
This will prevent an attacker from stealing the pod's identity to query the K8s API.


### 5. Resource quotas & limit ranges

![alt text](<Screenshot 2026-04-13 231334.png>)


### 6. Randomly generated secrets (idempotent)
- **Entropy-Driven Credentials**: I replaced hardcoded password with a 32-character base64 string generated via `openssl rand`+ local file check to avoid password change on rerun.


## Comparison Summary (Phase 1 vs Phase 2)

| Control | Phase 1 (Insecure) | Phase 2 (Hardened) |
|---------|-------------------|-------------------|
| Pod user | root | Non‑root (UID `1000`/`101`/`70`) |
| Root filesystem | writable | read‑only (with `/tmp` emptyDir) |
| Service account token | mounted | disabled |
| Linux capabilities | default (many) | all dropped |
| Privilege escalation | allowed | disabled |
| PSA label | `privileged` | `restricted` |
| Network policies | none | default deny + explicit allow |
| Secrets | hardcoded | random per environment |
| Resource limits | none | quotas + limit ranges |

### Lesson Learned
**Trade-off: Privileged Ports vs. Non-Root**

Challenge: Transitioning to runAsUser: 101 (non-root) prevented Nginx from binding to port 80.
Changed the container application to use port 8080 internally, while the Kubernetes Service handles the translation from port 80. This satisfied the `restricted` PSA without compromising accessibility.

## How to Reproduce

## 🛠️ Prerequisites

- **Kubernetes cluster** (Minikube, Kind, KillerCoda, or any conformant cluster)
- **kubectl** (v1.24+)
- **kustomize** (built into `kubectl 1.14+`)
- **Docker** (only if you need to build the backend image – otherwise use the pre‑built `succesc/fact-app-s:v3`)

> The script uses `kubectl create --dry-run` to generate YAMLs, so no manual editing is required.


1. **Clone the repository**

   `git clone https://github.com/susu10-10/k8s-3tier-automation.git`
   `cd k8s-3tier-automation/`

2. Place the required files in the same directory as deploy.sh:
    > `index.html` (provided above) and `default.conf` (provided above)

3. Make the script executable
`chmod +x deploy-secure.sh`

4. Run the script
`./deploy-secure.sh`

    > it will display the kustomized manifest when prompted, type `y` to apply to your cluster. 

5. Verify Deployment
`kubectl get all -n backend-secure`
`kubectl get all -n frontend-secure`

    > (All pods should be `Running` within 30-60 seconds)

6. Access the frontend

`kubectl port-forward -n frontend-secuer svc/frontend-svc 8080:80`

      http://localhost:8080 in your browser.
      Add a fact -> it appears. Click "Random Fact" -> a random fact is shown.





