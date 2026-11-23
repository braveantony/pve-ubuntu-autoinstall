# One image with everything the scripts run: Packer (with xorriso), OpenTofu,
# the Packer Proxmox plugin and the OpenTofu Proxmox provider. The plugin and
# provider versions come from base/packer/*.pkr.hcl and base/tofu/versions.tf, so those
# files stay the single place where versions are pinned.
#
#   podman build -t ghcr.io/braveantony/pve-ubuntu-autoinstall:dev .

FROM ghcr.io/opentofu/opentofu:1.13.9-minimal AS tofu

FROM docker.io/hashicorp/packer:light-1.16.2

# xorriso builds the autoinstall seed CD; openssh-client is used by the
# bpg/proxmox provider and by Packer provisioners.
RUN apk add --no-cache xorriso openssh-client

COPY --from=tofu /usr/local/bin/tofu /usr/local/bin/tofu

ENV PACKER_PLUGIN_PATH=/opt/packer/plugins \
    CHECKPOINT_DISABLE=1

# Packer plugin: install the version required by the template.
COPY base/packer/ubuntu-2604.pkr.hcl /tmp/pin/packer/
# "packer init" asks the GitHub API for the plugin release. Shared CI runners
# hit the anonymous rate limit, so a token can be passed as a build secret
# (--secret id=github_token,...). It is optional and is not stored in the image.
RUN --mount=type=secret,id=github_token \
    PACKER_GITHUB_API_TOKEN="$(cat /run/secrets/github_token 2>/dev/null || true)" \
    packer init /tmp/pin/packer/ubuntu-2604.pkr.hcl

# OpenTofu provider: mirror the locked version into the image and make tofu
# install from that mirror only, so "tofu init" needs no network access.
COPY base/tofu/versions.tf base/tofu/.terraform.lock.hcl /tmp/pin/tofu/
RUN cd /tmp/pin/tofu \
 && tofu providers mirror /opt/tofu/providers \
 && printf 'provider_installation {\n  filesystem_mirror {\n    path = "/opt/tofu/providers"\n  }\n}\n' > /opt/tofu/tofu.rc \
 && rm -rf /tmp/pin
ENV TF_CLI_CONFIG_FILE=/opt/tofu/tofu.rc

LABEL org.opencontainers.image.source="https://github.com/braveantony/pve-ubuntu-autoinstall" \
      org.opencontainers.image.description="Packer and OpenTofu with the Proxmox plugins used by pve-ubuntu-autoinstall" \
      org.opencontainers.image.licenses="BUSL-1.1 AND MPL-2.0 AND MIT"

WORKDIR /work
ENTRYPOINT []
