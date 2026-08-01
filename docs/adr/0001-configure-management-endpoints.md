# 0001: Configure management endpoints at creation time

## Status

Accepted

## Context

The VM's Redfish service and serial console are fixed to host-local endpoints. External
test controllers need both endpoints, but changing the safe defaults would expose control
surfaces unexpectedly. Endpoint choices also affect generated TLS identity, libvirt domain
shape, connection metadata, and rerun validation.

## Decision

Treat Redfish and serial endpoints as create-time configuration. Environment variables feed
one validation path, rendered configuration, TLS generation, ownership metadata, and
connection metadata. Redfish defaults to `127.0.0.1:8000`; serial defaults to the existing
libvirt PTY. Operators may opt into a raw TCP serial listener with an explicit IP address and
port. TCP listeners use libvirt server mode and do not add authentication or encryption.

Existing domains must match the configured serial transport and endpoint. Existing TLS state
must contain the configured Redfish IP address; incompatible state fails with a remediation
message instead of silently keeping an invalid certificate.

## Consequences

Safe behavior is unchanged without configuration. Off-host use requires deliberate network
and firewall choices, and the generated connection file becomes the discovery contract for
both endpoints. A concrete IP address is required so certificate verification has a usable
identity. TCP serial traffic remains appropriate only for isolated test networks.

## Considered & rejected

- Bind Redfish and serial to all interfaces by default: rejected because it silently widens
  access to unauthenticated serial data and a management API capable of fetching media URLs.
- Add a proxy or new authenticated serial service: rejected because the issue asks for a test
  transport and libvirt already supplies raw TCP serial; a new service adds dependencies and
  a second lifecycle.
- Patch generated files after creation: rejected because reruns could not reliably validate
  the live contract and certificates would drift from the advertised endpoint.

