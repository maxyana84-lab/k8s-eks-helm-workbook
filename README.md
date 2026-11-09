# k8s-eks-helm-workbook

Solutions to the **Kubernetes, EKS & Helm Exercises Workbook** (TRTech Solutions, DevOps training).
One folder per workbook section; each folder has the manifests, a README with the commands and the answers,
and is checked in CI.

| Section | Folder | Status |
|---|---|---|
| 1. Core Kubernetes Objects | `01-core-objects/` | done |
| 2. Namespaces & Resource Management | `02-namespaces-resources/` | done |
| 3. Networking & Ingress | `03-networking/` | done |
| 4. Storage | | planned |
| 5. RBAC & Security | | planned |
| 6. Scheduling & Scaling | | planned |
| 7. Amazon EKS | | planned (needs a real AWS account) |
| 8. Helm | | planned |
| 9. Troubleshooting & Debugging | | planned |
| 10. Production Patterns | | planned |

## Rules

- No secrets in Git. Secrets are created with `kubectl create secret` and the values in the workbook are demo values only.
- Image tags are pinned (no `latest`).
- CI validates every manifest with `kubeconform` and runs the exercises of the sections that can run in a local
  [kind](https://kind.sigs.k8s.io/) cluster. Exercises that need AWS (EKS, EFS, Fargate) are validated only,
  and the README of the section says what was and was not run.
