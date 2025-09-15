# aws quotas

AWS Increase Quotas for spoke cluster installs.

Pick the correct region based on where hub is installing spokes to e.g. us-east-2

- https://us-east-2.console.aws.amazon.com/servicequotas/home/dashboard

- https://us-east-2.console.aws.amazon.com/servicequotas/home/requests

Per Roadshow Spoke Cluster (n)

```bash
EC2: EC2-VPC Elastic IPs => (default: 5) need x3 per cluster           = n x 3
VPC: VPCs per Region     => (default: 5) each cluster has its own vpc  = n
```
