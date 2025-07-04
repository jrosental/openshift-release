#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

################################################################################
# This script uses the following parameters from CI jobs.
#
# CLUSTER_PROFILE_NAME - Specifies the profile name.  "vsphere-elastic" uses VMC
#      to assign configurations.
# MULTI_NIC_IPI - Enables the script to create multiple networks in each failure
#      domain.
# VSPHERE_MULTI_NETWORKS - Configures script to create a unique subnet for each
#      failure domain.
################################################################################

if [[ "${CLUSTER_PROFILE_NAME:-}" != "vsphere-elastic" ]]; then
  echo "using legacy sibling of this step"
  exit 0
fi

function log() {
  echo "$(date -u --rfc-3339=seconds) - " + "$1"
}

# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
  echo "$(date -u --rfc-3339=seconds) - failed to acquire lease"
  exit 1
fi

export GOVC_TLS_CA_CERTS=/var/run/vault/vsphere-ibmcloud-ci/vcenter-certificate

# only used in zonal and vsphere environments with
# multiple datacenters
declare vsphere_url
declare VCENTER_AUTH_PATH
declare PORTGROUP_RETVAL
declare LEASES


declare MULTI_TENANT_CAPABLE_WORKFLOWS
# shellcheck source=/dev/null
source "/var/run/vault/vsphere-ibmcloud-config/multi-capable-workflows.sh"

LEASES=()

DEFAULT_NETWORK_TYPE=${DEFAULT_NETWORK_TYPE:-"single-tenant"}
for workflow in ${MULTI_TENANT_CAPABLE_WORKFLOWS}; do
  if [ "${workflow}" == "${JOB_NAME_SAFE}" ]; then
    log "workflow ${JOB_NAME_SAFE} is multi-tenant capable. will request a multi-tenant network if there is no override in the job yaml."
    DEFAULT_NETWORK_TYPE="multi-tenant"
    break
  fi
done

NETWORK_TYPE=${NETWORK_TYPE:-${DEFAULT_NETWORK_TYPE}}

log "job will run with network type ${NETWORK_TYPE}"

function networkToSubnetsJson() {
  local NETWORK_CACHE_PATH=$1
  local NETWORK_RESOURCE=$2

  TMPSUBNETSJSON="/tmp/subnets-${NETWORK_RESOURCE}.json"

  jq -r '.[.spec.primaryRouterHostname] = .[.spec.vlanId] |
  .[.spec.primaryRouterHostname][.spec.vlanId] = .spec |
  .[.spec.primaryRouterHostname][.spec.vlanId].dnsServer = .spec.gateway |
  .[.spec.primaryRouterHostname][.spec.vlanId].mask = .spec.netmask |
  .[.spec.primaryRouterHostname][.spec.vlanId].StartIPv6Address= .spec.startIPv6Address |
  .[.spec.primaryRouterHostname][.spec.vlanId].CidrIPv6 = .spec.cidrIPv6' "${NETWORK_CACHE_PATH}" > "${TMPSUBNETSJSON}"


  if [ -f "${SHARED_DIR}/subnets.json" ]; then
    if [[ "${VSPHERE_MULTI_NETWORKS:-}" == "true" ]]; then
      jq -s '.[0] * .[1]' "${TMPSUBNETSJSON}" "${SHARED_DIR}/subnets.json" > /tmp/tmpfile && mv /tmp/tmpfile "${SHARED_DIR}/subnets.json"
    else
      jq -s '.[0] * .[1]' "${TMPSUBNETSJSON}" "${SHARED_DIR}/subnets.json"
    fi
  else
    cp "${TMPSUBNETSJSON}" "${SHARED_DIR}/subnets.json"
  fi
}

function getPortGroup() {
  NETWORK_INDEX=$1
  log "Getting portgroup for networks[${NETWORK_INDEX}]"
  NETWORK_PATH=$(jq -r ".status.topology.networks[$NETWORK_INDEX]" < /tmp/lease.json)

  # We may have more than one network in the lease.  We'll need to find the owner that matches current
  NETWORK_RESOURCES=$(jq -r '.metadata.ownerReferences[] | select(.kind=="Network") | .name' < /tmp/lease.json)
  for RESOURCE in ${NETWORK_RESOURCES}; do
    log "Checking network resource ${RESOURCE}"
    NETWORK_CACHE_PATH="${SHARED_DIR}/NETWORK_${RESOURCE}.json"

    if [ ! -f "$NETWORK_CACHE_PATH" ]; then
      log "Caching network resource ${RESOURCE}"
      oc get networks.vspherecapacitymanager.splat.io -n vsphere-infra-helpers --kubeconfig "${SA_KUBECONFIG}" "${RESOURCE}" -o json > "${NETWORK_CACHE_PATH}"
    fi

    networkToSubnetsJson "${NETWORK_CACHE_PATH}" "${RESOURCE}"
  done

  PORTGROUP_RETVAL=$(echo "$NETWORK_PATH" | cut -d '/' -f 4)
}

log "add jq plugin for converting json to yaml"
# this snippet enables jq to convert json to yaml
cat > ~/.jq <<EOF
def yamlify2:
    (objects | to_entries | (map(.key | length) | max + 2) as \$w |
        .[] | (.value | type) as \$type |
        if \$type == "array" then
            "\(.key):", (.value | yamlify2)
        elif \$type == "object" then
            "\(.key):", "    \(.value | yamlify2)"
        else
            "\(.key):\(" " * (.key | \$w - length))\(.value)"
        end
    )
    // (arrays | select(length > 0)[] | [yamlify2] |
        "  - \(.[0])", "    \(.[1:][])"
    )
    // .
    ;
EOF

function getTypeInHeirarchy() {
  local DATATYPE=$1
  local LEVEL=$2

  FOUND=0
  while [[ $FOUND == 0 ]]; do
    PARENTREF=$(jq --compact-output -r '.[] | select (.Name=="parent").Val' <<< "$LEVEL")
    echo "$PARENTREF"
    if [[ ${PARENTREF} == "null" ]]; then
      log "unable to find ${DATATYPE}"
      return 1
    fi
    TEMPTYPE=$(jq -r .Type <<< "${PARENTREF}")
    log "type ${TEMPTYPE}"
    LEVEL=$(govc object.collect -json "${TEMPTYPE}":"$(jq --compact-output -r .Value <<< "${PARENTREF}")")
    if [[ ${TEMPTYPE} == "${DATATYPE}" ]]; then
      LEVEL_NAME=$(jq -r '.[] | select(.Name == "name") | .Val' <<< "${LEVEL}")
      FOUND=1
    fi
  done

  return 0
}

DVS_PATH="${SHARED_DIR}/dvs.json"
dvsJSON="{}"

# getDVSInfo build a map of JSON data for a specific network path
function getDVSInfo() {
  local NETWORK=$1

  if [[ $(jq -r '.["'"${NETWORK}"'"]' <<< "${dvsJSON}") != "null" ]]; then
    return
  fi
  log "gathering clusters and UUIDs associated with ${NETWORK}"

  dvsJSON=$(jq -r '. += {"'"${NETWORK}"'": {}}' <<< "${dvsJSON}")

  govc ls -json -t DistributedVirtualPortgroup "${NETWORK}" > /tmp/dvs.json
  elements=$(jq length /tmp/dvs.json)
  DVS_idx=0
  while [[ $DVS_idx -lt ${elements} ]]; do
    log "DVS: ${DVS_idx}"

    parentDVS=$(jq --compact-output -r .elements[${DVS_idx}].Object.Config.DistributedVirtualSwitch /tmp/dvs.json)
    UUID_FORMATTED=$(govc object.collect -json "$(jq -r .Type <<< "${parentDVS}")":"$(jq -r .Value <<< "${parentDVS}")" | jq -r '.[] | select(.Name=="uuid") | .Val')

    # determine the cluster where this dvs instance resides
    HOSTS=$(jq -r '.elements['${DVS_idx}'].Object.Host | .[].Value' /tmp/dvs.json)
    for HOST in ${HOSTS}; do
      _HOST=$(govc object.collect -json HostSystem:"${HOST}")

      getTypeInHeirarchy "ClusterComputeResource" "${_HOST}"
      # shellcheck disable=SC2181
      if [ "$?" -ne 0 ];then
        log "could not determine the compute cluster resource for ${NETWORK}"
        exit 1
      fi
      local CLUSTER=${LEVEL_NAME}

      getTypeInHeirarchy "Datacenter" "${_HOST}"
      # shellcheck disable=SC2181
      if [ "$?" -ne 0 ];then
        log "could not determine the datacenter resource for ${NETWORK}"
        exit 1
      fi

      log "found in cluster ${CLUSTER} with UUID ${UUID_FORMATTED}"
      dvsJSON2=$(jq -r '.["'"${NETWORK}"'"] += {"datacenter":"'"${LEVEL_NAME}"'","cluster":{"'"${CLUSTER}"'": "'"${UUID_FORMATTED}"'"}}' <<< "${dvsJSON}")
      dvsJSON=$(echo "${dvsJSON} ${dvsJSON2}" | jq -s '.[0] * .[1]')
    done
    DVS_idx=$((DVS_idx + 1))
   done

  echo "$dvsJSON" > "${DVS_PATH}"
}

SA_KUBECONFIG=${SA_KUBECONFIG:-/var/run/vault/vsphere-ibmcloud-ci/vsphere-capacity-manager-kubeconfig}

if [[ ${JOB_NAME_SAFE} =~ "-upi" ]]; then
   IPI=0
   log "determined this is a UPI job"
else
   IPI=1
   log "determined this is an IPI job"
fi

# It seems we have some private jobs that are not using this flag.  We'll have to see how to sync up with those tests
# to try to use the MULTI_NIC_IPI flag for doing multiple nics.
if [[ -n "${MULTI_NIC_IPI}" ]]; then
  echo "multi-nic is enabled, an additional NIC will be attached to nodes"
fi

# Generate labels for reference back to job
PROW_JOB_TYPE="$(echo ${JOB_SPEC} | jq -r '.type')"
PROW_JOB="$(echo ${JOB_SPEC} | jq -r '.job')"
PROW_BUILD_ID="$(echo ${JOB_SPEC} | jq -r '.buildid')"
PROW_GS_BUCKET="$(echo ${JOB_SPEC} | jq -r '.decoration_config.gcs_configuration.bucket')"
JOB_URL_PREFIX="$(echo ${JOB_SPEC} | jq -r '.decoration_config.gcs_configuration.job_url_prefix // empty')"
if [[ "${JOB_URL_PREFIX}" == "" ]]; then
  JOB_URL_PREFIX="https://prow.ci.openshift.org/view/"
fi

# The following will only be present for presubmits
GIT_ORG="$(echo ${JOB_SPEC} | jq -r '.refs.org')"
GIT_REPO="$(echo ${JOB_SPEC} | jq -r '.refs.repo')"
GIT_PR="$(echo ${JOB_SPEC} | jq -r '.refs.pulls[0].number')"

LEASE_ANNOTATIONS="prow-job-type: \"${PROW_JOB_TYPE}\"
    prow-job-name: \"${PROW_JOB}\"
    prow-build-id: \"${PROW_BUILD_ID}\"
    prow-gs-bucket: \"${PROW_GS_BUCKET}\"
    prow-url-prefix: \"${JOB_URL_PREFIX}\""
if [[ "${PROW_JOB_TYPE}" == "presubmit" ]]; then
  LEASE_ANNOTATIONS="${LEASE_ANNOTATIONS}
    git-org: \"${GIT_ORG}\"
    git-repo: \"${GIT_REPO}\"
    git-pr: \"${GIT_PR}\""
fi

if [[ -n "${VSPHERE_BASTION_LEASED_RESOURCE:-}" ]]; then
  log "creating bastion lease resource ${VSPHERE_BASTION_LEASED_RESOURCE}"

  # shellcheck disable=SC1078
  LEASES+=("$(echo "apiVersion: vspherecapacitymanager.splat.io/v1
kind: Lease
metadata:
  generateName: \"${LEASED_RESOURCE}-\"
  namespace: \"vsphere-infra-helpers\"
  annotations:
    ${LEASE_ANNOTATIONS}
  labels:
    vsphere-capacity-manager.splat-team.io/lease-namespace: \"${NAMESPACE}\"
    boskos-lease-id: \"${LEASED_RESOURCE}\"
    boskos-lease-group: \"${LEASED_RESOURCE}\"
    job-name: \"${JOB_NAME_SAFE}\"
    VSPHERE_BASTION_LEASED_RESOURCE: \"${VSPHERE_BASTION_LEASED_RESOURCE}\"
spec:
  vcpus: 0
  memory: 0
  network-type: \"${NETWORK_TYPE}\"
  requiresPool: \"${VSPHERE_BASTION_LEASED_RESOURCE}\"
  networks: 1" | oc create --kubeconfig "${SA_KUBECONFIG}" -o json -f - | jq -r '.metadata.name')")
fi

POOLS=${POOLS:-}
IFS=" " read -r -a pools <<< "${POOLS}"

OPENSHIFT_REQUIRED_CORES=${OPENSHIFT_REQUIRED_CORES:-24}
OPENSHIFT_REQUIRED_MEMORY=${OPENSHIFT_REQUIRED_MEMORY:-96}

if [[ ${#pools[@]} -eq 0 ]]; then
  pools[0]="unspecified"
else
  # if we have multiple pools, attempt to spread the load evenly between the pools
  OPENSHIFT_REQUIRED_CORES=$((OPENSHIFT_REQUIRED_CORES / ${#pools[@]}))
  OPENSHIFT_REQUIRED_MEMORY=$((OPENSHIFT_REQUIRED_MEMORY / ${#pools[@]}))
fi

cluster_name=${NAMESPACE}-${UNIQUE_HASH}

# create a lease for each pool
POOL_INDEX=0
for POOL in "${pools[@]}"; do
  log "creating lease for pool ${POOL}"
  requiredPool=""
  if [ "$POOL" != "unspecified" ]; then
    requiredPool="required-pool: $POOL"
    log "setting required pool ${requiredPool}"
  fi

  networks_number=1
  # Base vs private ci jobs use different flags to represent multi nic.  If either is set, increase number to 2 networks.
  # Future change will change this to be an integer and allow jobs to pass in the number of networks to acquire.
  if [[ "${MULTI_NIC_IPI:-}" == "true" ]]; then
    networks_number=2
  fi

  # For this flag, we need to make sure each FD has a unique name so it gets a unique subnet.
  unique_name=""
  if [[ "${VSPHERE_MULTI_NETWORKS:-}" == "true" ]]; then
    unique_name="-${POOL_INDEX}"
    POOL_INDEX=$((POOL_INDEX + 1))
  fi

  # shellcheck disable=SC1078
  LEASES+=("$(echo "apiVersion: vspherecapacitymanager.splat.io/v1
kind: Lease
metadata:
  generateName: \"${LEASED_RESOURCE}-\"
  namespace: \"vsphere-infra-helpers\"
  annotations:
    ${LEASE_ANNOTATIONS}
  labels:
    cluster-id: \"${cluster_name}\"
    vsphere-capacity-manager.splat-team.io/lease-namespace: \"${NAMESPACE}\"
    boskos-lease-id: \"${LEASED_RESOURCE}${unique_name}\"
    boskos-lease-group: \"${LEASED_RESOURCE}\"
    job-name: \"${JOB_NAME_SAFE}\"
spec:
  vcpus: ${OPENSHIFT_REQUIRED_CORES}
  memory: ${OPENSHIFT_REQUIRED_MEMORY}
  network-type: \"${NETWORK_TYPE}\"
  ${requiredPool}
  networks: $networks_number" | oc create --kubeconfig "${SA_KUBECONFIG}" -o json -f - | jq -r '.metadata.name')")
done

log "waiting for lease $(printf '%s ' "${LEASES[@]}") to be fulfilled..."
n=0
until [ "$n" -ge 5 ]
do
  if [ "${#LEASES[@]}" -eq "1" ]; then
    # shellcheck disable=SC2046
    if oc get leases.vspherecapacitymanager.splat.io --kubeconfig "${SA_KUBECONFIG}" -n vsphere-infra-helpers $(printf '%s ' "${LEASES[@]}") -o json | jq -e '.status?'; then
      break
    fi
  else
    # shellcheck disable=SC2046
    if oc get leases.vspherecapacitymanager.splat.io --kubeconfig "${SA_KUBECONFIG}" -n vsphere-infra-helpers $(printf '%s ' "${LEASES[@]}") -o json | jq -e '.items[].status?'; then
      break
    fi
  fi

  n=$((n+1))
  sleep 15
done

if [ "$n" -ge 5 ]; then
  log "status was never available for lease, exit 1"
  # shellcheck disable=SC2046
  oc get leases.vspherecapacitymanager.splat.io --kubeconfig "${SA_KUBECONFIG}" -n vsphere-infra-helpers $(printf '%s ' "${LEASES[@]}") -o yaml
  exit 1
fi

# shellcheck disable=SC2046
oc wait leases.vspherecapacitymanager.splat.io --kubeconfig "${SA_KUBECONFIG}" --timeout=120m --for=jsonpath='{.status.phase}'=Fulfilled -n vsphere-infra-helpers $(printf '%s ' "${LEASES[@]}")

declare -A vcenter_portgroups

# reconcile leases
log "Extracting portgroups from leases..."
for LEASE in "${LEASES[@]}"; do
  log "getting lease ${LEASE}"
  oc get leases.vspherecapacitymanager.splat.io -n vsphere-infra-helpers --kubeconfig "${SA_KUBECONFIG}" "${LEASE}" -o json > /tmp/lease.json
  VCENTER=$(jq -r '.status.name' < /tmp/lease.json )

  log "got lease ${LEASE}"

  # We need to iterate through each network
  networkCount=$(jq '.status.topology.networks | length' < /tmp/lease.json)
  log "Network count: ${networkCount}"

  bastion_leased_resource=$(jq .metadata.labels.VSPHERE_BASTION_LEASED_RESOURCE < /tmp/lease.json)

  if [ "${bastion_leased_resource}" != "null" ]; then
    getPortGroup 0
    portgroup_name=${PORTGROUP_RETVAL}
    log "setting bastion portgroup ${portgroup_name} in vsphere_context.sh"

    cat >>"${SHARED_DIR}/vsphere_context.sh" <<EOF
export vsphere_bastion_portgroup="${portgroup_name}"
EOF

  else
    for ((i = 0; i < ${networkCount}; i++)); do
      getPortGroup $i
      portgroup_name=${PORTGROUP_RETVAL}

      previousValue=""
      if [[ -n "${vcenter_portgroups[$VCENTER]:-}" ]]; then
        previousValue="${vcenter_portgroups[$VCENTER]},"
      fi
      vcenter_portgroups[$VCENTER]="${previousValue}${portgroup_name}"
    done
  fi

  cp /tmp/lease.json "${SHARED_DIR}/LEASE_$LEASE.json"
done

# debug, confirm correct subnets.json
cat "${SHARED_DIR}/subnets.json"

declare -A pool_usernames
declare -A pool_passwords

# shellcheck disable=SC2089
platformSpec='{"vcenters": [],"failureDomains": []}'

log "building local variables and failure domains"

# Iterate through each lease and generate the failure domain and vcenters information
for _leaseJSON in "${SHARED_DIR}"/LEASE*; do
  RESOURCE_POOL=$(jq -r .status.name < "${_leaseJSON}")
  PRIMARY_LEASED_CPUS=$(jq -r .spec.vcpus < "${_leaseJSON}")

  if [[ ${PRIMARY_LEASED_CPUS} != "null" ]]; then
    log "storing primary lease as LEASE_single"
    cp "${_leaseJSON}" "${SHARED_DIR}"/LEASE_single.json
  fi

  log "building local variables and platform spec for pool ${RESOURCE_POOL}"
  oc get pools.vspherecapacitymanager.splat.io --kubeconfig "${SA_KUBECONFIG}" -n vsphere-infra-helpers "${RESOURCE_POOL}" -o json > /tmp/pool.json
  VCENTER_AUTH_PATH=$(jq -r '.metadata.annotations["ci-auth-path"]' < /tmp/pool.json)

  declare vcenter_usernames
  declare vcenter_passwords

  # shellcheck source=/dev/null
  source "${VCENTER_AUTH_PATH}"
  account_loc=$((RANDOM % 4))
  VCENTER=$(jq -r '.spec.server' < /tmp/pool.json)
  vsphere_user="${vcenter_usernames[$account_loc]}"
  vsphere_password="${vcenter_passwords[$account_loc]}"
  pool_usernames[$VCENTER]=${vsphere_user}
  pool_passwords[$VCENTER]=${vsphere_password}

  shortName=$(jq -r '.spec.shortName' < /tmp/pool.json)
  server=$(jq -r '.spec.server' < /tmp/pool.json)
  region=$(jq -r '.spec.region' < /tmp/pool.json)
  zone=$(jq -r '.spec.zone' < /tmp/pool.json)
  cluster=$(jq -r '.spec.topology.computeCluster' < /tmp/pool.json)
  datacenter=$(jq -r '.spec.topology.datacenter' < /tmp/pool.json)
  datastore=$(jq -r '.spec.topology.datastore' < /tmp/pool.json)

  # Populate network from our map.  Add quotes around the comma for json creation below
  network="${vcenter_portgroups[$RESOURCE_POOL]/,/\",\"}"
  if [ $IPI -eq 0 ]; then
    resource_pool=${cluster}/Resources/${NAMESPACE}-${UNIQUE_HASH}
  else
    resource_pool=${cluster}/Resources/ipi-ci-clusters
  fi

  # prevent duplicate failure domains if in the event we have a network-only lease in addition to the primary lease
  add_failure_domain=0
  failure_domain_count=$(echo "${platformSpec}" | jq '.failureDomains | length')
  if [[ $failure_domain_count == 0 ]]; then
    add_failure_domain=1
  elif [ -z "$(echo "${platformSpec}" | jq -e --arg NAME "$shortName" '.failureDomains[] | select(.name == $NAME) | length == 0')" ]; then
    add_failure_domain=1
  fi

  if [[ $add_failure_domain == 1 ]] ; then
    platformSpec=$(echo "${platformSpec}" | jq -r '.failureDomains += [{"server": "'"${server}"'", "name": "'"${shortName}"'", "zone": "'"${zone}"'", "region": "'"${region}"'", "server": "'"${server}"'", "topology": {"resourcePool": "'"${resource_pool}"'", "computeCluster": "'"${cluster}"'", "datacenter": "'"${datacenter}"'", "datastore": "'"${datastore}"'", "networks": ["'"${network}"'"]}}]')
  fi

  # Add / Update vCenter list
  if echo "${platformSpec}" | jq -e --arg VCENTER "$VCENTER" '.vcenters[] | select(.server == $VCENTER) | length > 0' ; then
    # Check and make sure the datacenter doesn't already exist in the vcenter definition
    if ! echo "${platformSpec}" | jq -e --arg VCENTER "$VCENTER" --arg DC "$datacenter" '.vcenters[] | select(.server == $VCENTER) | any(.datacenters[]; . == $DC)' ; then
      log "Adding additional datacenter to vcenter ${VCENTER}"
      platformSpec=$(echo "${platformSpec}" | jq -r --arg VCENTER "$VCENTER" --arg DC "$datacenter" '(.vcenters[] | select(.server == $VCENTER)) |= (.datacenters[.datacenters | length] |= .+ $DC)')
    fi
  else
    log "Adding vcenter ${VCENTER} to config"
    platformSpec=$(echo "${platformSpec}" | jq -r '.vcenters += [{"server": "'"${VCENTER}"'", "user": "'"${pool_usernames[$VCENTER]}"'", "password": "'"${pool_passwords[$VCENTER]}"'", "datacenters": ["'"${datacenter}"'"]}]')
  fi

  cp /tmp/pool.json "${SHARED_DIR}"/POOL_"${RESOURCE_POOL}".json
done

# For legacy spec, the below will merge the following json to the existing json.
if [ -n "${POPULATE_LEGACY_SPEC}" ]; then
  platformSpec='{"vcenter": "'"${server}"'", "username": "'"${vsphere_user}"'", "password": "'"${vsphere_password}"'", "defaultDatastore": "'"$(basename "${datastore}")"'" ,"network": "'"$(basename "${network}")"'" , "cluster": "'"$(basename "${cluster}")"'", "datacenter": "'"$(basename "${datacenter}")"'"}'
fi

# For most CI jobs, a single lease and single pool will be used. We'll initialize govc.sh and
# vsphere_context.sh with the first lease we find. multi-zone and multi-vcenter will need to
# parse topology, credentials, etc from $SHARED_DIR.

IFS=' ' read -ra NETWORK_RESOURCE <<< "$(jq -r '.metadata.ownerReferences[] | select(.kind=="Network") | .name' < "${SHARED_DIR}"/LEASE_single.json)"
cp "${SHARED_DIR}/NETWORK_${NETWORK_RESOURCE[0]}.json" "${SHARED_DIR}"/NETWORK_single.json

jq -r '.status.envVars' "${SHARED_DIR}"/LEASE_single.json > /tmp/envvars

# shellcheck source=/dev/null
source /tmp/envvars


if [[ -z "${GOVC_URL}" ]]; then
  echo "$(date -u --rfc-3339=seconds) - vcm failed to provide environment variables, exiting"
  exit 1
fi

log "Creating govc.sh file..."
cat >>"${SHARED_DIR}/govc.sh" <<EOF
$(cat /tmp/envvars)
export LEASE_PATH=${SHARED_DIR}/LEASE_single.json
export NETWORK_PATH=${SHARED_DIR}/NETWORK_single.json
export GOVC_INSECURE=1
export vsphere_resource_pool=${resource_pool}
export GOVC_RESOURCE_POOL=${resource_pool}
export cloud_where_run=IBM
export GOVC_USERNAME="${pool_usernames[${GOVC_URL}]}"
export GOVC_PASSWORD="${pool_passwords[${GOVC_URL}]}"
export GOVC_TLS_CA_CERTS=/var/run/vault/vsphere-ibmcloud-ci/vcenter-certificate
export SSL_CERT_FILE=/var/run/vault/vsphere-ibmcloud-ci/vcenter-certificate
EOF

log "Creating vsphere_context.sh file..."
cp "${SHARED_DIR}/govc.sh" "${SHARED_DIR}/vsphere_context.sh"

# 1. Get the OpaqueNetwork (NSX-T port group) which is listed in LEASED_RESOURCE.
# 2. Select the virtual machines attached to network
# 3. list the path to the virtual machine via the managed object reference
# 4. skip the templates with ova
# 5. Power off and delete the virtual machine

# disable error checking in this section
# randomly delete may fail, this shouldn't cause an immediate issue
# but should eventually be cleaned up.

set +e
for LEASE in "${LEASES[@]}"; do
  jq -r '.status.envVars' > /tmp/envvars < "$SHARED_DIR/LEASE_$LEASE.json"

  declare vsphere_portgroup
  declare vsphere_datacenter

  # shellcheck source=/dev/null
  source /tmp/envvars

  export GOVC_USERNAME="${pool_usernames[$vsphere_url]}"
  export GOVC_PASSWORD="${pool_passwords[$vsphere_url]}"
  export GOVC_TLS_CA_CERTS=/var/run/vault/vsphere-ibmcloud-ci/vcenter-certificate

  echo "$(date -u --rfc-3339=seconds) - Find virtual machines attached to ${vsphere_portgroup} in DC ${vsphere_datacenter} and destroy"
  govc ls -json "${vsphere_portgroup}" |
  jq '.elements[]?.Object.Vm[]?.Value' |
  xargs -I {} --no-run-if-empty govc ls -json -L VirtualMachine:{} |
  jq '.elements[].Path | select((contains("ova") or test("\\bci-segment-[0-9]?[0-9]?[0-9]-bastion\\b")) | not)' |
  xargs -I {} --no-run-if-empty govc vm.destroy {}
done
set -e

for LEASE in "${SHARED_DIR}"/LEASE*; do
  if [[ $LEASE =~ "single" ]]; then
    continue
  fi

  jq -r .status.envVars "${LEASE}" > /tmp/envvars

  # shellcheck source=/dev/null
  source /tmp/envvars

  log "checking ${LEASE} and ${GOVC_NETWORK} for DVS UUID"

  export GOVC_USERNAME="${pool_usernames[$vsphere_url]}"
  export GOVC_PASSWORD="${pool_passwords[$vsphere_url]}"

  getDVSInfo "/${GOVC_DATACENTER}/network/${GOVC_NETWORK}"
done

log "writing the platform spec"
echo "$platformSpec" > "${SHARED_DIR}"/platform.json
echo "$platformSpec" | jq -r yamlify2 | sed --expression='s/^/    /g' > "${SHARED_DIR}"/platform.yaml
