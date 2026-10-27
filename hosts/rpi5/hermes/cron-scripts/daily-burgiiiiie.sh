#!/usr/bin/env bash
# Self-sending (a photo, which stdout cannot carry). Immich is reached through
# Agent Vault — HTTP_PROXY is inherited from the gateway.
exec @bin@/hermes-burgie-photo
