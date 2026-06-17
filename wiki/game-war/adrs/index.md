# ADRs

**Status:** active

## Overview
Architecture decision records — the durable choices that shape War: determinism parity, optimistic reconciliation, the hard wall, the validator wire contract, and the shared editor tooling.

## Contents
- [Byte-for-byte determinism parity between the GDScript engine and the TS validator](decision-record:mqifgwzc-00ct-x8e9w5)
- [Optimistic client updates with authoritative validator reconciliation](decision-record:mqifh0mi-00cv-pvy4d3)
- [Hard wall between deterministic logic and presentation](decision-record:mqifh449-00cx-tn4lh5)
- [Pure rules logic as static class_name utilities, not autoloads](decision-record:mqifh7of-00cz-pldvws)
- [Golden-vector parity testing from the canonical TS logic dist](decision-record:mqifhb5b-00d1-oqryvr)
- [Protobuf as the validator wire contract; game state rides as canonical-JSON strings](decision-record:mqifhfql-00d3-c3pj7t)
- [gRPC over Snapser Hermes as the validator transport](decision-record:mqifhmrl-00d5-7cwf39)
- [Adopt Snapser as the online backend](decision-record:mqifhrgx-00d7-388jut)
- [Authenticate BYOSnap requests by trusting the gateway-stamped User-Id](decision-record:mqifhv43-00d9-blkcws)
- [Design the game to be driven and verified by an LLM](decision-record:mqifi0cz-00db-nfnqri)
- [Adopt the shared editor_tool_kit framework (vendored-but-sourced)](decision-record:mqifi3v6-00dd-je8rh8)
- [Cards dealt face-down: the flip moment is the Special-Card decision point](decision-record:mqifi7a5-00df-h8vd1s)
