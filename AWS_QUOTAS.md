# aws quotas

AWS Increase Quotas for spoke cluster installs.

Pick the correct region based on where hub is installing spokes to e.g. us-east-2

- https://us-east-2.console.aws.amazon.com/servicequotas/home/dashboard

- https://us-east-2.console.aws.amazon.com/servicequotas/home/requests

Per Roadshow Spoke Cluster (n)

```bash
-- https://us-east-1.console.aws.amazon.com/servicequotas/home/services/ec2/quotas/L-DB2E81BA
EC2: Running On-Demand G and VT instances => (default: 64) - depends in instance type = n x vCPU

-- https://us-east-2.console.aws.amazon.com/servicequotas/home/services/ec2/quotas/L-0263D0A3
EC2: EC2-VPC Elastic IPs => (default: 5) need x3 per cluster           = n x 3

-- https://us-east-2.console.aws.amazon.com/servicequotas/home/services/vpc/quotas/L-F678F1CE
VPC: VPCs per Region     => (default: 5) each cluster has its own vpc  = n

-- https://us-east-2.console.aws.amazon.com/servicequotas/home/services/vpc/quotas/L-FE5A380F
VPC: NAT gateways per Availability Zone => (default: 5) need x3 per cluster           = n x 3
```

Example: set using CLI

```bash
export AWS_PROFILE=sno-test
aws service-quotas get-service-quota --service-code ec2 --quota-code L-DB2E81BA
aws service-quotas request-service-quota-increase --service-code ec2 --quota-code L-DB2E81BA --desired-value 256
```
