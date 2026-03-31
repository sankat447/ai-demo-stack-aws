apiVersion: machine.openshift.io/v1beta1
kind: MachineSet
metadata:
  name: ${infrastructure_id}-${role}-${az}
  namespace: openshift-machine-api
  labels:
    machine.openshift.io/cluster-api-cluster: ${infrastructure_id}
spec:
  replicas: ${replicas}
  selector:
    matchLabels:
      machine.openshift.io/cluster-api-cluster: ${infrastructure_id}
      machine.openshift.io/cluster-api-machineset: ${infrastructure_id}-${role}-${az}
  template:
    metadata:
      labels:
        machine.openshift.io/cluster-api-cluster: ${infrastructure_id}
        machine.openshift.io/cluster-api-machine-role: ${role}
        machine.openshift.io/cluster-api-machine-type: ${role}
        machine.openshift.io/cluster-api-machineset: ${infrastructure_id}-${role}-${az}
    spec:
      metadata:
        labels:
          ${labels}
      providerSpec:
        value:
          apiVersion: machine.openshift.io/v1beta1
          kind: AWSMachineProviderConfig
          credentialsSecret:
            name: aws-cloud-credentials
          instanceType: ${instance_type}
          iamInstanceProfile:
            id: ${infrastructure_id}-worker-profile
          placement:
            availabilityZone: ${az}
            region: ${substr(az, 0, length(az) - 1)}
%{ if ami_id != "" }
          ami:
            id: ${ami_id}
%{ endif }
          subnet:
            filters:
            - name: tag:Name
              values:
              - ${subnet_filter}
          securityGroups:
          - filters:
            - name: tag:Name
              values:
              - ${sg_filter}
          blockDevices:
          - ebs:
              volumeSize: 120
              volumeType: gp3
              iops: 3000
              encrypted: true
          tags:
          - name: kubernetes.io/cluster/${cluster_name}
            value: owned
