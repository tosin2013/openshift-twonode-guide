# Deployment Records

Each time this guide has been used for an end-to-end cluster deployment, a record is created here capturing the environment, steps taken, issues encountered, and final cluster status. These records serve as reproducibility evidence and a log of real-world deviations from the documented procedure.

## Records

| Date | Environment | OCP Version | Status | Record |
|---|---|---|---|---|
| 2026-06-03 | IBM Cloud — KVM on bare metal | 4.22.0-rc.5 | Successful | [tnf-kvm-ibmcloud-2026-06-03](tnf-kvm-ibmcloud-2026-06-03.md) |

## What Each Record Contains

- **Prerequisites** — host specs, software versions, and DNS configuration
- **Deployment steps** — ordered list of commands run, including any deviations from the guide
- **Issues encountered** — problems hit during the deployment and how they were resolved
- **Validation output** — cluster operator status, node readiness, Pacemaker state
- **Rollback procedure** — how to tear down and redeploy if needed
