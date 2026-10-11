#!/usr/bin/env bash
set -euo pipefail

sudo apt update
sudo apt install -y golang-go

go version
