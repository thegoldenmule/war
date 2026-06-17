# `net/proto/` — godobuf-generated GDScript protobuf bindings

This directory holds the **generated** GDScript protobuf bindings (`*_pb.gd`)
that the War client uses to frame messages on the wire. **Do not hand-edit
these files** — they are produced from the `.proto` sources and overwritten on
every regeneration.

## Where they come from

The source-of-truth protos live in the validator repo:

```
validator/protos/
├── war/validator/v1/        # ValidatorService { InitMatch, ValidateAction, CompleteMatch }
└── hermes/hermes_envelope.proto   # ClientMessage / ServerMessage (snap-api-proxy)
```

They are compiled to GDScript with [**godobuf**](https://github.com/oniksan/godobuf),
a pure-GDScript protobuf code generator, driven by:

```
tools/gen-protos.sh
```

That script invokes the godobuf generator (headless Godot) over the protos
above and writes the results here as, e.g.:

```
net/proto/hermes_envelope_pb.gd        # HermesEnvelopePb.ClientMessage / .ServerMessage
net/proto/war_validator_v1_pb.gd       # request/response messages for the 3 RPCs
```

## When to regenerate

Regenerate **whenever the `.proto` files change** (new RPC, new field, renamed
message). From the repo root:

```sh
./tools/gen-protos.sh
```

Then commit the regenerated `*_pb.gd` alongside the proto change so client and
validator stay in lockstep.

## How the transport uses them

`net/hermes_client.gd` (`WarHermesClient`) frames every request as a Hermes
`ClientMessage` and decodes every reply as a `ServerMessage`. Today those
encode/decode paths are stubbed behind `# TODO(skeleton)` and frame a JSON
mirror of the proto fields so the connection lifecycle is exercisable before
the bindings exist. Wiring godobuf is a drop-in replacement at those two
markers (`_encode_client_message` / `_decode_server_message`).

## The determinism boundary (important)

Game **state** and **actions** are **never** modeled as proto messages. They
travel as **canonical-JSON STRINGS** inside proto `string` fields — that JSON
string *is* the hash domain shared with the validator. The protos only carry
envelope metadata (request id, RPC routing) plus those opaque JSON strings.
Re-modeling state as protobuf would break byte-for-byte hash parity with the
TypeScript validator, so don't.
