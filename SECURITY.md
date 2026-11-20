<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# Security

The radio listens for a PC's mouse and keyboard over UDP on your home network and has no login, so run it on a network you trust and do not expose its port to the internet. The network input drops every key that would transmit.

If you find a problem that could be misused (for example a way to make the radio transmit, or a malformed packet that crashes the firmware), please use GitHub's private vulnerability reporting on the Security tab of this repository instead of opening a public issue. This is a hobby project, so I cannot promise a fix time, but I will read every report.
