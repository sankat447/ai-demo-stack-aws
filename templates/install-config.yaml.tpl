apiVersion: v1
baseDomain: ${base_domain}
metadata:
  name: ${cluster_name}
compute:
- architecture: amd64
  hyperthreading: Enabled
  name: worker
  platform:
    aws:
      type: ${worker_type}
      rootVolume:
        size: 120
        type: gp3
        iops: 3000
  replicas: ${worker_count}
controlPlane:
  architecture: amd64
  hyperthreading: Enabled
  name: master
  platform:
    aws:
      type: ${master_type}
      rootVolume:
        size: 120
        type: gp3
        iops: 3000
  replicas: ${master_count}
networking:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  machineNetwork:
  - cidr: ${machine_cidr}
  networkType: ${network_type}
  serviceNetwork:
  - 172.30.0.0/16
platform:
  aws:
    region: ${aws_region}
    subnets: ${subnet_ids}
credentialsMode: Passthrough
publish: External
fips: ${fips}
pullSecret: '${replace(pull_secret, "'", "''")}'
%{ if ssh_key != "" ~}
sshKey: '${ssh_key}'
%{ endif ~}
