# Security Policy

## Supported Versions
This is an **educational hardening lab**, not a versioned software product.  
Only the latest commit on the `main` branch is actively maintained.

Tagged releases (if any) are snapshots of the lab at a point in time and are **not** independently supported.
Always reproduce any suspected issue on the tip of `main` before reporting.

## Reporting a Vulnerability
**Do not open a public issue.**  
Instead, report vulnerabilities privately so I can address them before they could mislead or harm users.

Use **GitHub’s private reporting**:
1. Go to the **Security** tab of this repository.
2. Click **Advisories** → **Report a vulnerability**.
3. Provide:
   - A clear description of the issue
   - Steps to reproduce, including which manifests (e.g., `deploy-secure.sh`, specific namespace) are affected
   - Potential impact – for example:
     - Re‑introduction of an insecure default (running as root, writable rootfs, excess capabilities)
     - A network policy loophole that breaks Zero‑Trust segmentation
     - Hardcoded credentials or secrets that bypass the random‑generation mechanism
     - Out‑of‑date container images with known vulnerabilities

Alternatively, you can email [successchukwu20@gmail.com].

### What to expect
- **Acknowledgement:** within 5 working days.
- **Resolution goal:** I aim to fix confirmed issues within 30 days, depending on complexity.
- **Disclosure:** Once fixed, I will publish a GitHub Security Advisory and credit you (unless you prefer anonymity).
- **Declined reports:** If the issue does not pose a practical security risk to lab users, I’ll explain why. General usage questions or feature requests should use regular Issues.

## Scope
This policy applies to any security weakness that could **weaken the hardening guarantees demonstrated in this lab**, including:

- Misconfigurations that roll back the security improvements from Phase 1 to Phase 2 (root users, writable rootfs, privileged containers, etc.)
- Network policies that accidentally allow unsegmented communication (defeating the Zero‑Trust model)
- Hardcoded secrets, leaked keys, or predictable random‑seed values in credential generation
- Vulnerable base images, Helm charts, or Terraform modules used by the lab
- Service account token mounting, privilege escalation, or capability assignments that deviate from the “restricted” PSA guidance

**Out of scope:** Typos in documentation, cosmetic issues, or lab‑inherent limitations that do not impact the security posture (e.g., ephemeral cluster caveats already mentioned in the README).

## This Lab’s Security Commitments
This repository follows the principles it teaches:
- No hardcoded secrets in plaintext
- No privileged containers by default
- Network segmentation enforced by default‑deny policies
- All deployments adhere to the Kubernetes **restricted** Pod Security Standard

I take the same care with the lab’s own code as I do with the hardened manifests it showcases.
