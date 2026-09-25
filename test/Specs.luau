--!strict
--- Every spec file of the suite, in the order they run. Test.luau requires this once its own specs
--- have run; each file below runs its specs as it loads.
---
--- New specs go in a file of their own, added here, rather than on the end of Test.luau. The order
--- matters where noted: some specs leave state the next one in its file relies on, and the CLI specs
--- remove what the others read.
require("./Ranges")
require("./Numbers")
require("./NumberLimits")
require("./Buffers")
require("./Listeners")
require("./SizeAnalysis")
require("./Guards")
require("./Refusals")
require("./Predict")
require("./InboundBudget")
require("./PacketDrops")
require("./ListenerErrors")
require("./TrafficStats")
require("./ModuleNames")
require("./Invocations")
require("./Concurrency")
require("./Signature")
require("./Profiles")
require("./Channels")
require("./SchemaDrift")
require("./TypePacks")
require("./ClientDecoding")
require("./SyncValidation")
require("./Highlighting")
require("./Completion")
require("./EditorAnalysis")
require("./WireFormat")
require("./Ordering")
require("./Encodings")
require("./Properties")
require("./HalfFloats")
require("./Floats24")
require("./EventIndices")
require("./Composition")
require("./Locals")
require("./SharedModules")
require("./Decoding")
require("./BufferIntegrity")
require("./Lifecycle")
require("./DocExamples")

--> LAST, and deliberately so: the CLI specs delete ../Network to prove the compiler recreates a
--> missing output directory, and then recompile only Test.blink. Everything generated from the other
--> schemas is gone afterwards, so any spec that reads a generated FILE has to have run already.
require("./CommandLine")
--> After it only because it is a CLI spec too; it compiles its own schema into test/Network/Verify.
require("./Verify")

return {}
