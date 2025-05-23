#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Deprovisioning cluster ..."
if [[ ! -s "${SHARED_DIR}/metadata.json" ]]; then
  echo "Skipping: ${SHARED_DIR}/metadata.json not found."
  exit
fi

function save_logs() {
    echo "Copying the Installer logs and metadata to the artifacts directory..."
    cp /tmp/installer/.openshift_install.log "${ARTIFACT_DIR}"
}

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
trap 'save_logs' EXIT TERM

export ALIBABA_CLOUD_CREDENTIALS_FILE=${SHARED_DIR}/alibabacreds.ini
if [[ -f "${SHARED_DIR}/aws_minimal_permission" ]]; then
  echo "Setting AWS credential with minimal permision for installer"
  export AWS_SHARED_CREDENTIALS_FILE=${SHARED_DIR}/aws_minimal_permission
else
  export AWS_SHARED_CREDENTIALS_FILE=$CLUSTER_PROFILE_DIR/.awscred
fi

export AZURE_AUTH_LOCATION=$CLUSTER_PROFILE_DIR/osServicePrincipal.json
export GOOGLE_CLOUD_KEYFILE_JSON=$CLUSTER_PROFILE_DIR/gce.json
if [ -f "${SHARED_DIR}/gcp_min_permissions.json" ]; then
  echo "$(date -u --rfc-3339=seconds) - Using the IAM service account for the minimum permissions testing on GCP..."
  export GOOGLE_CLOUD_KEYFILE_JSON="${SHARED_DIR}/gcp_min_permissions.json"
elif [ -f "${SHARED_DIR}/user_tags_sa.json" ]; then
  echo "$(date -u --rfc-3339=seconds) - Using the IAM service account for the userTags testing on GCP..."
  export GOOGLE_CLOUD_KEYFILE_JSON="${SHARED_DIR}/user_tags_sa.json"
elif [ -f "${SHARED_DIR}/xpn_min_perm_passthrough.json" ]; then
  echo "$(date -u --rfc-3339=seconds) - Using the IAM service account of minimal permissions for deploying OCP cluster into GCP shared VPC..."
  export GOOGLE_CLOUD_KEYFILE_JSON="${SHARED_DIR}/xpn_min_perm_passthrough.json"
elif [ -f "${SHARED_DIR}/xpn_byo-hosted-zone_min_perm_passthrough.json" ]; then
  echo "$(date -u --rfc-3339=seconds) - Using the IAM service account of minimal permissions for deploying OCP cluster into GCP shared VPC using BYO hosted zone..."
  export GOOGLE_CLOUD_KEYFILE_JSON="${SHARED_DIR}/xpn_byo-hosted-zone_min_perm_passthrough.json"
fi
export OS_CLIENT_CONFIG_FILE=${SHARED_DIR}/clouds.yaml
export OVIRT_CONFIG=${SHARED_DIR}/ovirt-config.yaml

if [[ "${CLUSTER_TYPE}" == "ibmcloud"* ]]; then
  if [ -f "${SHARED_DIR}/ibmcloud-min-permission-api-key" ]; then
    IC_API_KEY="$(< "${SHARED_DIR}/ibmcloud-min-permission-api-key")"
  else
    IC_API_KEY="$(< "${CLUSTER_PROFILE_DIR}/ibmcloud-api-key")"
  fi
  export IC_API_KEY
fi
if [[ "${CLUSTER_TYPE}" == "vsphere"* ]]; then
    cp /var/run/vsphere-ibmcloud-ci/vcenter-certificate /tmp/ca-bundle.pem
    if [ -f "${SHARED_DIR}/additional_ca_cert.pem" ]; then
      echo "additional CA bundle found, appending it to the bundle from vault"
      echo -n $'\n' >> /tmp/ca-bundle.pem
      cat "${SHARED_DIR}/additional_ca_cert.pem" >> /tmp/ca-bundle.pem
    fi
    export SSL_CERT_FILE=/tmp/ca-bundle.pem
fi

echo ${SHARED_DIR}/metadata.json
if [[ -f "${SHARED_DIR}/azure_minimal_permission" ]]; then
    echo "Setting AZURE credential with minimal permissions for installer"
    export AZURE_AUTH_LOCATION=${SHARED_DIR}/azure_minimal_permission
elif [[ -f "${SHARED_DIR}/azure-sp-contributor.json" ]]; then
    echo "Setting AZURE credential with Contributor role only for installer"
    export AZURE_AUTH_LOCATION=${SHARED_DIR}/azure-sp-contributor.json
fi

if [[ "${CLUSTER_TYPE}" == "azurestack" ]]; then
  export AZURE_AUTH_LOCATION=$SHARED_DIR/osServicePrincipal.json
  if [[ -f "${CLUSTER_PROFILE_DIR}/ca.pem" ]]; then
    export SSL_CERT_FILE="${CLUSTER_PROFILE_DIR}/ca.pem"
  fi
fi

echo "Copying the installation artifacts to the Installer's asset directory..."
cp -ar "${SHARED_DIR}" /tmp/installer

export INSTALLER_BINARY="openshift-install"
if [[ -n "${CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE:-}" ]]; then
        echo "Extracting installer from ${CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
        oc adm release extract -a "${CLUSTER_PROFILE_DIR}/pull-secret" "${CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" --command=openshift-install --to="/tmp" || exit 1
        export INSTALLER_BINARY="/tmp/openshift-install"
fi
echo "=============== openshift-install version =============="
${INSTALLER_BINARY} version

if [[ "${CLUSTER_TYPE}" =~ ^aws-s?c2s$ ]]; then
  # C2S/SC2S regions do not support destory
  #   replace ${AWS_REGION} with source_region(us-east-1) in metadata.json as a workaround"

  # downloading jq
  curl -L https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 -o /tmp/jq && chmod +x /tmp/jq

  source_region=$(/tmp/jq -r ".\"${LEASED_RESOURCE}\".source_region" "${CLUSTER_PROFILE_DIR}/shift_project_setting.json")
  sed -i "s/${LEASED_RESOURCE}/${source_region}/" "/tmp/installer/metadata.json"
fi

# TODO: remove once BZ#1926093 is done and backported
if [[ "${CLUSTER_TYPE}" == "ovirt" ]]; then
  echo "Destroy bootstrap ..."
  set +e
  ${INSTALLER_BINARY} --dir /tmp/installer destroy bootstrap
  set -e
fi

# Check if proxy is set
if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  if [[ "${CLUSTER_TYPE}" =~ ^aws-s?c2s$ ]]; then
    echo "proxy-conf.sh detected, but not reqquired by C2S/SC2S while destroying cluster, skip proxy setting"
  elif [[ "${CLUSTER_TYPE}" = "azure4" ]]; then
    # when bastion host is provisioned in cluster resource group, once the bastion is destroyed in the destroy process,
    # the running destroy process would be interrupted and failed. E.g: azure-ipi-public-to-private jobs.
    echo "proxy-conf.sh detected, but not required by azure4 clusters while destroying cluster, skip proxy setting"
  else
    echo "Private cluster setting proxy"
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
  fi
fi

if [[ "${CLUSTER_TYPE}" == "nutanix" ]]; then
  if [[ -f "${CLUSTER_PROFILE_DIR}/prismcentral.pem" ]]; then
    export SSL_CERT_FILE="${CLUSTER_PROFILE_DIR}/prismcentral.pem"
  fi
fi

echo "Running the Installer's 'destroy cluster' command..."
OPENSHIFT_INSTALL_REPORT_QUOTA_FOOTPRINT="true"; export OPENSHIFT_INSTALL_REPORT_QUOTA_FOOTPRINT
${INSTALLER_BINARY} --dir /tmp/installer destroy cluster &

set +e
wait "$!"
ret="$?"
set -e

if [[ -s /tmp/installer/quota.json ]]; then
        cp /tmp/installer/quota.json "${ARTIFACT_DIR}"
fi

exit "$ret"
