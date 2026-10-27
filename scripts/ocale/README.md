# OCALE generated-codec experiment

This experiment runs the real generated `DatatypesServer.luau` codec in LuneBlox and in Roblox Open
Cloud Luau Execution (OCALE), then compares the results. It checks exact serialized bytes, buffer
lengths, decoded datatype fields, repeated writes after a shorter payload, and truncated-input
rejection. The `World` export covers `PhysicalProperties?`, `NumberSequence`, `Rect`, `Region3`, and
`Ray`.

`build.luau` inserts the committed generated module into `conformance.luau`; the resulting single
script is written to the ignored `build/ocale/` directory. Locally, the generated module takes its
normal edit-mode path and returns standalone serializers before remote initialization. In Roblox it
loads as a running server module. No handwritten replacement serializer is involved.

Run the local half and verify the comparator:

```sh
luneblox run scripts/ocale/build
luneblox run build/ocale/conformance | tee build/ocale/local.log
luneblox run scripts/ocale/compare build/ocale/local.log build/ocale/local.log
```

The `OCALE codec conformance` workflow runs the cloud half manually or weekly. It is intentionally
not a pull-request workflow: Roblox credentials must not be exposed to untrusted code. Configure
`ROBLOX_API_KEY`, `OCALE_UNIVERSE_ID`, and `OCALE_PLACE_ID` as repository secrets. The API key needs
permission to execute Luau in that universe. The command uses `--load.version 0`, so it executes in
the last saved place version without uploading or saving a new version.

A successful comparison means the same generated codec produced the same observable serialization
behavior in both VMs. A mismatch fails the workflow and uploads both logs.
