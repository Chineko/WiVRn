# Helix HEVC10 + SGSR1 — Release Candidate 2

This host-specific CachyOS/Linux x86-64 candidate assembles the exact tested server,
OpenXR runtime and Quest client. No native rebuild was introduced during cleanup.
Requires installed runtime dependencies, Steam/VRChat, NVIDIA driver, ADB, Python3,
and the tested xrizer at /opt/xrizer. LAN addresses are provided at launch; already
paired headset expected. LAN streaming; ADB only for installation/launch.

Use an absolute path to the extracted launcher (fish-compatible):

    python3 /absolute/path/helix-hevc10-sgsr1-rc2/run-wivrn.py --check
    python3 /absolute/path/helix-hevc10-sgsr1-rc2/run-wivrn.py --install-profile
    python3 /absolute/path/helix-hevc10-sgsr1-rc2/run-wivrn.py --host HOST_LAN_IP --quest QUEST_LAN_IP

--install-profile installs the WiVRn-only NVIDIA P2 workaround and exits. It keeps
unrelated profiles and backs up an existing file before modification. It allows P0
under load, without locking clocks. It is already installed on the tested host.
No existing game/server session may be running. Quest must be awake, Guardian
cleared. Ctrl+C stops the session and checks restoration of runtime registrations.
--encoder vulkan selects the alternate encoder; default is nvenc, HEVC10.

This normal launcher has no image dumps, CUDA/NVENC probe, GPU sampling, recovery
canary injection or capture runner. Normal server console messages remain.
It preserves the client settings: Post-processing offers SGSR1, sharpening0–100%,
and vibrance0–100%. SGSR1 strength75 is not calibrated against VD75. The client
retains its tested development package/name org.meumeu.wivrn.sgsr1; install updates
that comparison app while leaving org.meumeu.wivrn.local untouched.

Server/runtime source:f87cbf84acea3e52370a7c15d4ed63a2d870ce87.
Client source:81debe382c4ec0b96bf500f205c41a801c54c17e.
Release source/checkpoint is the helix-hevc10-sgsr1-rc2 tag in Chineko/WiVRn.
Checksums and exact artifact identities are in seal.json. The runtime template is
resolved into private temporary absolute paths at launch; original assets stay sealed.
This is a tested development RC for the recorded setup, not a universal installer
or store production build. Visual/performance results are workload-specific.

RC2 corrects source formatting/lint/executable modes. Native binaries are identical
to the tested RC1 assembly. Publication requires successful Build, Format and
Locales CI on the exact candidate commit via tools/helix-release-gate.py.
