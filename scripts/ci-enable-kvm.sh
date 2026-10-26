#!/usr/bin/env bash
# GitHub's x64 runners have /dev/kvm, but only root can open it; this grants the runner user
# access. Runners without /dev/kvm run the tests under TCG emulation.
set -euo pipefail
if [[ -e /dev/kvm ]]; then
  echo 'KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"' | sudo tee /etc/udev/rules.d/99-kvm4all.rules >/dev/null
  sudo udevadm control --reload-rules
  sudo udevadm trigger --name-match=kvm
  echo "KVM enabled"
else
  echo "::notice::no /dev/kvm on $(uname -m) runner; acceptance tests run under TCG emulation"
fi
