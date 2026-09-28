# Benchmarks
## Methodology
Each tool fires an event 1000 times a frame for 10 seconds. Each bench is a pool of payloads, fired in turn:
`Booleans` and `Entities` send the same payload every time, and `BooleansRandom` and `EntitiesRandom` send a thousand
different ones a frame, from a pool of 1001 so that no frame repeats the one before it. Roblox compresses a remote's buffers with zstd, so identical events compress to almost nothing
and their bandwidth measures the compressor; the random benches leave it nothing to find.

`Fire ms` is the CPU time a frame's thousand fires took on the client. Studio caps the framerate at 60, so a tool at
60 FPS is bounded by the cap, not by its own cost, and this column still tells such tools apart. Studio compiles
LocalScripts natively, which most clients do not, so every tool looks faster here than on a player's device.

`Bytes/event` is what an event cost on the wire after Roblox's compression: every byte the client sent from the first
fire until its backlog drained, less what it sends idle, over the events fired. `Drain` is how long that backlog took
after the last fire. This replaced a `Kbps` column that sampled `Stats.DataSendKbps` -- kilobytes a second, not
kilobits -- once a second and scaled it by 60 / FPS. That read low for every tool below 60 FPS, since what a slow tool
fired went out after its sample and after the run: on the M1, Packet's EntitiesRandom came to 486 bytes an event, less
than the 600 bytes of random data in it. Tables older than this change still carry the `Kbps` column, and it should be
read with that in mind: no tool encodes Entities in fewer bytes than another (see below).

BlinkBlox's inbound limits are raised in the definition file for this, since a live server's defaults refuse most of
what the benchmark sends -- that is what they are for.

Blink is the original project BlinkBlox forked from, at its last release. `--download` fetches its source
into `tools/upstream`, and its own compiler builds `definitions/Definition.upstream.blink`, the same events without the
inbound limits, which Blink does not have, and without `Tiny`.

## Without Studio

`luneblox run Runtime` in this directory times every tool above on LuneBlox, where Studio cannot: interpreted, as
most players' clients run code, and decoding on the server, which Studio does not time. It loads zap's and Blink's
generated modules, ByteNet, Packet, QuickNet and Warp from the same files Studio runs (after
`luneblox run build --download`) with just enough of Roblox mocked around them, and times a frame's thousand fires,
the flush into packets, and the server decoding those packets and calling its listener. `Bytes/event` is the
encoder's output; `zstd` is that output compressed as Roblox would.

The runs below were made on 2026-09-29 on an Intel Core i7-13700K with 64 GB of memory, Windows 11, LuneBlox 0.10.9
(Luau 0.740), with this repository's compiler (0.42.0). Every run was the only one on the machine, pinned to one
performance core at high priority: the 13700K's efficiency cores run the same code several times slower, and runs
side by side on neighbouring cores moved an allocating decode by about 8%. Each figure is the median of three runs,
and each run's figure is itself a median or 99th percentile over 200 frames, in milliseconds per frame. `native` is
what a Roblox server runs; `interpreted` is what most clients run. Packet declares `--!native` nowhere, so both its
rows are interpreted. `Tiny` is BlinkBlox's alone.

Every row is timed in a process of its own (`Runtime` starts one for each bench, mode and tool), which holds 64 MB
from before the tool loads and runs a full garbage collection (`luau.collect()`, LuneBlox 0.10.9) before it measures.
In one process each tool inherited the heap and the allocator's state the tools before it left, and the first paid for
growing them: BlinkBlox, always first, decoded Booleans natively in 6.5 ms, and in 2.9 when it ran last, where QuickNet
took 3.6 in sixth place and 7.4 in first. The 64 MB stands for a game server's heap, next to which a tool's own
buffers are small: Luau's collector paces itself on the heap's size, and QuickNet keeps about 12 MB alive.

QuickNet and Warp keep their own limits in a game; here they are lifted as Packet's is. QuickNet's rate limit is set
to `math.huge` for every event, as QuickNet's own benchmark does, and Warp's server refuses a packet over 8000 bytes,
so `download.luau` raises that check to `math.huge`. Warp encodes nothing when an event is fired: it queues the value
and serialises the whole queue at its flush, which is why its fire column is near zero and its flush column is not.
It also sends each reliable packet as its XOR against the one before it, which is why its `zstd` column for the
repeated payloads is the lowest or tied here, where each frame is compressed on its own: two identical frames XOR to
zeros. In Studio it is the reverse (see Results below).

The mock players and Instances are userdata, as they are in a game. Before 0.40.0 they were tables, and native code
sends a function whose parameter is annotated `Player` or `Instance` back to the interpreter when a table arrives, so
some native figures in earlier tables were interpreted ones.

#### Booleans

|Tool|Code|Fire median|Fire p99|Flush median|Decode median|Decode p99|Bytes/event|zstd bytes/event|
|---|---|---|---|---|---|---|---|---|
|BlinkBlox|native|1.832|2.070|0.005|6.717|11.268|128.00|0.02|
|Blink|native|3.929|4.773|0.222|10.665|16.037|1003.00|0.10|
|zap|native|11.681|13.934|0.225|11.489|15.692|1003.00|0.10|
|ByteNet|native|24.324|28.019|0.231|50.986|59.555|1003.00|0.10|
|Packet|native|53.553|59.849|0.244|50.948|59.304|1003.00|0.10|
|QuickNet|native|1.799|6.853|0.007|7.477|12.612|128.00|0.03|
|Warp|native|0.182|0.432|4.033|11.467|18.314|128.00|0.02|
|BlinkBlox|interpreted|16.256|22.302|0.007|14.280|18.864|128.00|0.02|
|Blink|interpreted|29.107|33.968|0.231|37.917|44.154|1003.00|0.10|
|zap|interpreted|65.284|72.720|0.238|38.840|46.682|1003.00|0.10|
|ByteNet|interpreted|53.917|58.489|0.237|51.254|61.866|1003.00|0.10|
|Packet|interpreted|53.745|60.656|0.246|51.158|57.952|1003.00|0.10|
|QuickNet|interpreted|16.773|22.177|0.009|17.655|23.528|128.00|0.03|
|Warp|interpreted|0.181|0.418|38.287|43.676|51.098|128.00|0.02|

#### Entities

|Tool|Code|Fire median|Fire p99|Flush median|Decode median|Decode p99|Bytes/event|zstd bytes/event|
|---|---|---|---|---|---|---|---|---|
|BlinkBlox|native|1.942|2.348|0.025|3.577|10.407|602.00|0.67|
|Blink|native|2.449|2.999|0.139|21.826|29.010|603.00|0.67|
|zap|native|6.946|7.685|0.061|21.160|25.971|603.00|0.67|
|ByteNet|native|25.948|30.081|0.066|42.488|48.746|603.00|0.67|
|Packet|native|39.542|45.273|0.083|52.698|68.826|603.00|0.67|
|QuickNet|native|6.437|17.814|0.023|11.372|21.350|603.00|0.67|
|Warp|native|0.153|0.391|18.697|26.907|42.176|602.00|0.03|
|BlinkBlox|interpreted|12.067|13.552|0.026|12.263|16.503|602.00|0.67|
|Blink|interpreted|12.611|15.190|0.134|29.482|35.703|603.00|0.67|
|zap|interpreted|33.332|39.585|0.061|32.852|37.717|603.00|0.67|
|ByteNet|interpreted|42.613|49.880|0.073|43.014|52.684|603.00|0.67|
|Packet|interpreted|39.820|43.340|0.079|52.457|68.629|603.00|0.67|
|QuickNet|interpreted|21.663|30.054|0.031|29.053|40.631|603.00|0.67|
|Warp|interpreted|0.154|0.420|65.568|56.351|71.883|602.00|0.03|

#### BooleansRandom

|Tool|Code|Fire median|Fire p99|Flush median|Decode median|Decode p99|Bytes/event|zstd bytes/event|
|---|---|---|---|---|---|---|---|---|
|BlinkBlox|native|4.575|5.284|0.009|6.833|13.833|128.00|125.81|
|Blink|native|9.262|10.364|0.232|11.301|17.902|1003.00|135.61|
|zap|native|17.130|21.256|0.236|11.844|18.132|1003.00|135.61|
|ByteNet|native|28.032|31.642|0.249|56.351|65.995|1003.00|135.60|
|Packet|native|56.577|62.753|0.264|54.947|62.554|1003.00|135.61|
|QuickNet|native|6.874|13.431|0.010|7.861|15.705|128.00|125.82|
|Warp|native|0.174|0.621|10.546|11.453|20.323|128.00|125.83|
|BlinkBlox|interpreted|16.848|21.184|0.010|14.310|20.891|128.00|125.81|
|Blink|interpreted|30.195|36.447|0.238|38.786|46.646|1003.00|135.61|
|zap|interpreted|68.154|74.394|0.241|39.048|46.685|1003.00|135.61|
|ByteNet|interpreted|57.167|64.624|0.251|55.694|63.213|1003.00|135.60|
|Packet|interpreted|57.064|63.422|0.263|55.371|65.066|1003.00|135.61|
|QuickNet|interpreted|21.704|28.086|0.013|17.772|25.944|128.00|125.82|
|Warp|interpreted|0.177|0.434|39.077|48.642|57.524|128.00|125.83|

#### EntitiesRandom

|Tool|Code|Fire median|Fire p99|Flush median|Decode median|Decode p99|Bytes/event|zstd bytes/event|
|---|---|---|---|---|---|---|---|---|
|BlinkBlox|native|2.256|3.172|0.030|3.594|18.365|602.00|602.02|
|Blink|native|2.615|3.203|0.068|20.927|34.601|603.00|603.02|
|zap|native|7.376|8.710|0.067|21.305|36.069|603.00|603.02|
|ByteNet|native|26.755|31.558|0.090|42.383|51.102|603.00|603.02|
|Packet|native|41.175|47.726|0.115|53.088|71.740|603.00|603.02|
|QuickNet|native|7.133|14.676|0.036|11.567|20.940|603.00|603.02|
|Warp|native|0.222|0.521|19.808|27.054|46.447|602.00|602.02|
|BlinkBlox|interpreted|12.778|14.585|0.034|12.390|26.651|602.00|602.02|
|Blink|interpreted|13.118|16.291|0.088|29.066|41.672|603.00|603.02|
|zap|interpreted|34.305|38.534|0.072|31.951|44.909|603.00|603.02|
|ByteNet|interpreted|42.961|47.886|0.092|42.416|51.251|603.00|603.02|
|Packet|interpreted|41.177|47.583|0.120|53.331|71.332|603.00|603.02|
|QuickNet|interpreted|22.698|28.487|0.043|29.497|39.954|603.00|603.02|
|Warp|interpreted|0.240|0.545|67.425|56.683|75.631|602.00|602.02|

#### Tiny

|Tool|Code|Fire median|Fire p99|Flush median|Decode median|Decode p99|Bytes/event|zstd bytes/event|
|---|---|---|---|---|---|---|---|---|
|BlinkBlox|native|0.025|0.029|0.000|0.047|0.066|2.00|0.02|
|BlinkBlox|interpreted|0.117|0.131|0.001|0.169|0.270|2.00|0.02|

### BlinkBlox across releases

`luneblox run Runtime -- --tools blink --sources <dir>` times the modules in a directory instead of generating them.
Here each release compiled `definitions/Definition.blink` with `option ManualReplication = true` -- 0.40.0 and 0.41.2
with their release executables, 0.34.0 with its source at the commit that released it, 0.42.0 with this checkout --
and the four were run in turn, five runs each, on the same core. Each figure is the median of the five.

0.34.0:

|Tool|Code|Fire median|Fire p99|Flush median|Decode median|Decode p99|Bytes/event|zstd bytes/event|
|---|---|---|---|---|---|---|---|---|
|BlinkBlox|native|3.790|5.789|0.042|10.845|15.770|128.00|0.02|
|BlinkBlox|interpreted|34.610|40.972|0.044|41.998|49.061|128.00|0.02|

0.40.0:

|Tool|Code|Fire median|Fire p99|Flush median|Decode median|Decode p99|Bytes/event|zstd bytes/event|
|---|---|---|---|---|---|---|---|---|
|BlinkBlox|native|1.826|2.097|0.042|6.737|11.186|128.00|0.02|
|BlinkBlox|interpreted|16.033|19.495|0.046|20.246|25.880|128.00|0.02|

0.41.2:

|Tool|Code|Fire median|Fire p99|Flush median|Decode median|Decode p99|Bytes/event|zstd bytes/event|
|---|---|---|---|---|---|---|---|---|
|BlinkBlox|native|1.829|2.384|0.043|6.814|11.378|128.00|0.02|
|BlinkBlox|interpreted|16.047|19.450|0.045|20.220|26.911|128.00|0.02|

0.42.0:

|Tool|Code|Fire median|Fire p99|Flush median|Decode median|Decode p99|Bytes/event|zstd bytes/event|
|---|---|---|---|---|---|---|---|---|
|BlinkBlox|native|1.833|2.227|0.005|6.748|11.368|128.00|0.02|
|BlinkBlox|interpreted|16.102|18.960|0.007|14.154|19.076|128.00|0.02|

## Sending to a crowd, unreliable events and Instances

`luneblox run Rivals` runs the paths the benchmark above never does, on every tool, all loaded the same way so each pays for
the same mocks, each flushing on its own Heartbeat. The events are in `definitions/Scenarios.blink`, declared for each tool
in `definitions/Scenarios.zap`, `definitions/Scenarios.upstream.blink` and `runtime/rivals/modes`. Times are
milliseconds a frame; `Remote calls/frame` and `Bytes/frame` are summed over every player a frame reached. Each figure
is the median of five runs, on the machine and runtime above.

- `Broadcast`: the server fires 100 reliable structs a frame to 50 players with `FireAll`.
- `UnreliableInput`: a client fires 8 small unreliable inputs a frame.
- `Instances`: a client fires 100 reliable events a frame, each carrying a part.
- `WorldState`: the server sends 16 units a frame to 50 players, unreliable, to everyone at once.
- `SelfState`: the server sends each of 50 players their own unit a frame, unreliable.

Packet has no unreliable channel, so it runs only the reliable scenarios. ByteNet's release prints its instance list
on every Instance it writes; the harness sends `print` nowhere, so the terminal is not what is timed. QuickNet and Warp
each send to everyone with their own call, and batch a frame per player: a send to 50 players is 50 remote calls.

#### Broadcast

|Tool|Code|Fire median|Flush median|Decode median|Remote calls/frame|Bytes/frame|
|---|---|---|---|---|---|---|
|BlinkBlox|native|0.019|0.001|0.012|1.0|85000.0|
|Blink|native|0.693|0.018|0.026|50.0|90000.0|
|zap|native|0.716|0.018|0.025|50.0|85000.0|
|ByteNet|native|0.042|0.002|0.109|1.0|90000.0|
|Packet|native|0.082|0.002|0.170|1.0|90000.0|
|QuickNet|native|0.297|0.009|0.034|50.0|90100.0|
|Warp|native|1.043|1.307|0.113|50.0|90050.0|
|BlinkBlox|interpreted|0.039|0.001|0.027|1.0|85000.0|
|Blink|interpreted|1.758|0.024|0.051|50.0|90000.0|
|zap|interpreted|1.712|0.024|0.043|50.0|85000.0|
|ByteNet|interpreted|0.078|0.003|0.120|1.0|90000.0|
|Packet|interpreted|0.082|0.002|0.170|1.0|90000.0|
|QuickNet|interpreted|0.769|0.018|0.088|50.0|90100.0|
|Warp|interpreted|1.049|4.747|0.166|50.0|90050.0|

#### UnreliableInput

|Tool|Code|Fire median|Flush median|Decode median|Remote calls/frame|Bytes/frame|
|---|---|---|---|---|---|---|
|BlinkBlox|native|0.002|0.000|0.003|8.0|40.0|
|Blink|native|0.002|0.000|0.003|8.0|48.0|
|zap|native|0.003|0.000|0.002|8.0|32.0|
|ByteNet|native|0.003|0.000|0.008|1.0|48.0|
|QuickNet|native|0.002|0.000|0.003|1.0|50.0|
|Warp|native|0.002|0.002|0.009|1.0|49.0|
|BlinkBlox|interpreted|0.005|0.000|0.007|8.0|40.0|
|Blink|interpreted|0.005|0.000|0.005|8.0|48.0|
|zap|interpreted|0.005|0.000|0.003|8.0|32.0|
|ByteNet|interpreted|0.005|0.000|0.009|1.0|48.0|
|QuickNet|interpreted|0.005|0.001|0.007|1.0|50.0|
|Warp|interpreted|0.002|0.005|0.011|1.0|49.0|

#### Instances

|Tool|Code|Fire median|Flush median|Decode median|Remote calls/frame|Bytes/frame|
|---|---|---|---|---|---|---|
|BlinkBlox|native|0.004|0.001|0.011|1.0|200.0|
|Blink|native|0.004|0.001|0.013|1.0|200.0|
|zap|native|0.005|0.001|0.009|1.0|200.0|
|ByteNet|native|0.030|0.001|0.093|1.0|300.0|
|Packet|native|0.037|0.001|0.126|1.0|200.0|
|QuickNet|native|0.013|0.001|0.027|1.0|202.0|
|Warp|native|0.018|0.013|0.091|1.0|301.0|
|BlinkBlox|interpreted|0.017|0.001|0.020|1.0|200.0|
|Blink|interpreted|0.013|0.001|0.017|1.0|200.0|
|zap|interpreted|0.015|0.001|0.021|1.0|200.0|
|ByteNet|interpreted|0.048|0.001|0.105|1.0|300.0|
|Packet|interpreted|0.037|0.001|0.127|1.0|200.0|
|QuickNet|interpreted|0.032|0.001|0.062|1.0|202.0|
|Warp|interpreted|0.018|0.041|0.118|1.0|301.0|

#### WorldState

|Tool|Code|Fire median|Flush median|Decode median|Remote calls/frame|Bytes/frame|
|---|---|---|---|---|---|---|
|BlinkBlox|native|0.002|0.000|0.001|1.0|12900.0|
|Blink|native|0.002|0.000|0.004|1.0|13700.0|
|zap|native|0.003|0.000|0.004|1.0|12850.0|
|ByteNet|native|0.006|0.002|0.009|1.0|13750.0|
|QuickNet|native|0.006|0.008|0.003|50.0|13850.0|
|Warp|native|0.010|0.188|0.006|50.0|13750.0|
|BlinkBlox|interpreted|0.004|0.000|0.003|1.0|12900.0|
|Blink|interpreted|0.004|0.000|0.006|1.0|13700.0|
|zap|interpreted|0.008|0.000|0.006|1.0|12850.0|
|ByteNet|interpreted|0.009|0.003|0.009|1.0|13750.0|
|QuickNet|interpreted|0.016|0.017|0.009|50.0|13850.0|
|Warp|interpreted|0.010|0.619|0.012|50.0|13750.0|

#### SelfState

|Tool|Code|Fire median|Flush median|Decode median|Remote calls/frame|Bytes/frame|
|---|---|---|---|---|---|---|
|BlinkBlox|native|0.012|0.000|0.000|50.0|850.0|
|Blink|native|0.013|0.000|0.001|50.0|900.0|
|zap|native|0.016|0.000|0.001|50.0|800.0|
|ByteNet|native|0.023|0.010|0.002|50.0|900.0|
|QuickNet|native|0.017|0.008|0.001|50.0|1000.0|
|Warp|native|0.012|0.034|0.002|50.0|950.0|
|BlinkBlox|interpreted|0.025|0.000|0.001|50.0|850.0|
|Blink|interpreted|0.025|0.000|0.001|50.0|900.0|
|zap|interpreted|0.035|0.000|0.001|50.0|800.0|
|ByteNet|interpreted|0.041|0.016|0.002|50.0|900.0|
|QuickNet|interpreted|0.042|0.017|0.001|50.0|1000.0|
|Warp|interpreted|0.012|0.071|0.002|50.0|950.0|

BlinkBlox with `option BatchUnreliable`, which gathers a frame's unreliable events into as few packets as fit:

#### Broadcast

|Tool|Code|Fire median|Flush median|Decode median|Remote calls/frame|Bytes/frame|
|---|---|---|---|---|---|---|
|BlinkBlox|native|0.019|0.001|0.012|1.0|85000.0|
|BlinkBlox|interpreted|0.044|0.001|0.032|1.0|85000.0|

#### UnreliableInput

|Tool|Code|Fire median|Flush median|Decode median|Remote calls/frame|Bytes/frame|
|---|---|---|---|---|---|---|
|BlinkBlox|native|0.002|0.000|0.001|1.0|40.0|
|BlinkBlox|interpreted|0.004|0.001|0.003|1.0|40.0|

#### Instances

|Tool|Code|Fire median|Flush median|Decode median|Remote calls/frame|Bytes/frame|
|---|---|---|---|---|---|---|
|BlinkBlox|native|0.004|0.001|0.011|1.0|200.0|
|BlinkBlox|interpreted|0.017|0.001|0.020|1.0|200.0|

#### WorldState

|Tool|Code|Fire median|Flush median|Decode median|Remote calls/frame|Bytes/frame|
|---|---|---|---|---|---|---|
|BlinkBlox|native|0.001|0.001|0.001|1.0|12900.0|
|BlinkBlox|interpreted|0.003|0.001|0.003|1.0|12900.0|

#### SelfState

|Tool|Code|Fire median|Flush median|Decode median|Remote calls/frame|Bytes/frame|
|---|---|---|---|---|---|---|
|BlinkBlox|native|0.006|0.007|0.000|50.0|850.0|
|BlinkBlox|interpreted|0.020|0.013|0.001|50.0|850.0|

## Streams

`luneblox run Scenarios` runs the same paths for BlinkBlox alone, with streams in place of the unreliable events: a stream
of 16 units to 50 players (`StreamWorld`), and one held per player (`StreamPerPlayer`). The streams to everyone due in
a frame share one `FireAllClients`. `ManyEvents` is described below. Medians of five runs:

|Scenario|Code|Fire median|Flush median|Decode median|Remote calls/frame|Bytes/frame|
|---|---|---|---|---|---|---|
|ManyEvents|native|0.023|0.001|0.008|1.0|200.0|
|Broadcast|native|0.019|0.001|0.012|1.0|85000.0|
|UnreliableInput|native|0.003|0.000|0.002|8.0|40.0|
|Instances|native|0.004|0.000|0.012|1.0|200.0|
|StreamWorld|native|0.001|0.006|0.001|1.0|13050.0|
|StreamPerPlayer|native|0.004|0.036|0.000|50.0|1000.0|
|ManyEvents|interpreted|0.034|0.001|0.020|1.0|200.0|
|Broadcast|interpreted|0.044|0.001|0.033|1.0|85000.0|
|UnreliableInput|interpreted|0.004|0.000|0.006|8.0|40.0|
|Instances|interpreted|0.016|0.001|0.021|1.0|200.0|
|StreamWorld|interpreted|0.001|0.013|0.003|1.0|13050.0|
|StreamPerPlayer|interpreted|0.008|0.079|0.001|50.0|1000.0|

With `--batch`:

|Scenario|Code|Fire median|Flush median|Decode median|Remote calls/frame|Bytes/frame|
|---|---|---|---|---|---|---|
|ManyEvents|native|0.024|0.001|0.008|1.0|200.0|
|Broadcast|native|0.019|0.001|0.012|1.0|85000.0|
|UnreliableInput|native|0.001|0.000|0.001|1.0|40.0|
|Instances|native|0.004|0.000|0.012|1.0|200.0|
|StreamWorld|native|0.001|0.006|0.001|1.0|13050.0|
|StreamPerPlayer|native|0.004|0.038|0.000|50.0|1000.0|
|ManyEvents|interpreted|0.035|0.001|0.020|1.0|200.0|
|Broadcast|interpreted|0.044|0.001|0.033|1.0|85000.0|
|UnreliableInput|interpreted|0.004|0.000|0.002|1.0|40.0|
|Instances|interpreted|0.016|0.001|0.021|1.0|200.0|
|StreamWorld|interpreted|0.001|0.013|0.003|1.0|13050.0|
|StreamPerPlayer|interpreted|0.008|0.087|0.001|50.0|1000.0|

## Many events

`luneblox run Scenarios -- ManyEvents` sends 100 reliable events a frame spread over the 128 `Many` declarations of
`definitions/Scenarios.blink`, and times the client decoding them. The table below compared 0.40.0 with 0.41.0 on
2026-09-28 on an Apple M1 with Lune 0.10.5, interpreted, medians of three runs taken alternately with both versions'
modules loaded from files:

|Scenario|0.40.0 decode|0.41.0 decode|
|---|---|---|
|ManyEvents|0.086|**0.053**|
|Broadcast, index 0 of the same channel|**0.090**|0.093|

Both native rows there equal the interpreted ones: Lune 0.10.5's Luau leaves a whole module interpreted once one
function is too large, and a module's top-level function grows with every declaration -- about 70 events on the
server, 85 on the client. Luau 0.740 leaves only that function interpreted, and on the i7 above the same decode takes
0.008 ms natively and 0.020 ms interpreted in 0.42.0 (the `ManyEvents` rows under Streams).

## Results

The Studio run below was made with BlinkBlox 0.41.2's modules; 0.42.0 changed how they decode and
flush, which the tables above time. Warp's `Fire ms` is left out: its Fire only queues the value, and
it encodes the queue later in the frame on a signal of its own that the bench cannot time, so the
figure read 0.1 ms while its frame rate fell to 32. `luneblox run Runtime` times its fire and flush
together.

`P[NUMBER]` = [NUMBER] Percentile  
*The tables below were automatically generated by this [script](https://github.com/XopoIII/BlinkBlox/blob/main/benchmark/generate.luau).*
## Last Updated 2026-09-28 10:28:37 UTC
## Tool Versions
BlinkBlox: v0.41.2, compiled from this repository  
Blink: v0.18.9  
zap: v0.6.29  
ByteNet: v0.4.3  
Packet: 1.7.0  
QuickNet: v0.3.5-beta (f7cfdf5)  
Warp: 1.1.0-pre7  
## Computer Specs
Processor: `13th Gen Intel(R) Core(TM) i7-13700K`  
Memory: `64GB`  
## [Booleans](https://github.com/XopoIII/BlinkBlox/blob/main/benchmark/src/shared/benches/Booleans.luau)
|Tool (FPS)|Median|P0|P80|P90|P95|P100|Loss (%)|
|---|---|---|---|---|---|---|---|
|Roblox remotes|15.00|16.00|15.00|15.00|15.00|15.00|0%|
|BlinkBlox|60.00|60.00|60.00|60.00|60.00|60.00|0%|
|Blink|60.00|60.00|60.00|60.00|60.00|60.00|0%|
|zap|60.00|60.00|60.00|60.00|60.00|60.00|0%|
|ByteNet|30.00|32.00|29.00|29.00|29.00|29.00|0%|
|Packet|35.00|36.00|34.00|34.00|34.00|34.00|0%|
|QuickNet|60.00|61.00|60.00|60.00|60.00|59.00|0%|
|Warp|60.00|60.00|60.00|60.00|60.00|60.00|0%|

|Tool (Fire ms)|Median|P0|P80|P90|P95|P100|Loss (%)|
|---|---|---|---|---|---|---|---|
|Roblox remotes|26.00|24.51|26.56|26.82|27.10|27.32|0%|
|BlinkBlox|1.92|1.84|2.03|2.14|2.31|2.80|0%|
|Blink|4.52|3.91|4.75|4.84|4.97|5.64|0%|
|zap|12.15|11.33|12.61|13.04|13.75|15.51|0%|
|ByteNet|17.45|16.55|18.01|18.35|18.65|19.44|0%|
|Packet|27.31|25.92|27.79|28.00|28.14|31.41|0%|
|QuickNet|1.89|1.77|2.06|2.21|2.28|2.53|0%|
|Warp|-|-|-|-|-|-|0%|

|Tool|Bytes/event|Drain (s)|Loss (%)|
|---|---|---|---|
|Roblox remotes|7101.43|6.0|0%|
|BlinkBlox|0.04|2.2|0%|
|Blink|0.13|3.3|0%|
|zap|0.13|3.3|0%|
|ByteNet|0.13|2.9|0%|
|Packet|0.13|3.4|0%|
|QuickNet|0.04|2.3|0%|
|Warp|0.15|1.9|0%|
## [Entities](https://github.com/XopoIII/BlinkBlox/blob/main/benchmark/src/shared/benches/Entities.luau)
|Tool (FPS)|Median|P0|P80|P90|P95|P100|Loss (%)|
|---|---|---|---|---|---|---|---|
|Roblox remotes|15.00|16.00|15.00|15.00|15.00|15.00|0%|
|BlinkBlox|60.00|60.00|60.00|60.00|60.00|60.00|0%|
|Blink|44.00|45.00|43.00|43.00|43.00|43.00|0%|
|zap|45.00|47.00|45.00|45.00|45.00|45.00|0%|
|ByteNet|35.00|36.00|34.00|34.00|34.00|34.00|0%|
|Packet|27.00|29.00|27.00|27.00|27.00|26.00|0%|
|QuickNet|58.00|59.00|57.00|57.00|57.00|57.00|0%|
|Warp|33.00|35.00|32.00|32.00|32.00|32.00|0%|

|Tool (Fire ms)|Median|P0|P80|P90|P95|P100|Loss (%)|
|---|---|---|---|---|---|---|---|
|Roblox remotes|72.70|69.50|74.25|75.29|75.72|78.97|0%|
|BlinkBlox|1.98|1.89|2.01|2.04|2.07|4.63|0%|
|Blink|2.81|2.33|3.08|3.35|4.87|5.84|0%|
|zap|7.35|6.82|7.67|7.92|9.36|11.45|0%|
|ByteNet|15.79|14.82|16.18|16.45|16.64|17.77|0%|
|Packet|19.24|18.05|19.70|19.92|20.12|20.71|0%|
|QuickNet|6.21|5.98|6.36|6.46|6.55|10.60|0%|
|Warp|-|-|-|-|-|-|0%|

|Tool|Bytes/event|Drain (s)|Loss (%)|
|---|---|---|---|
|Roblox remotes|33620.49|7.2|0%|
|BlinkBlox|0.69|4.5|0%|
|Blink|0.70|4.9|0%|
|zap|0.69|4.8|0%|
|ByteNet|0.69|5.0|0%|
|Packet|0.69|4.4|0%|
|QuickNet|0.69|4.8|0%|
|Warp|1.33|2.4|0%|
## [BooleansRandom](https://github.com/XopoIII/BlinkBlox/blob/main/benchmark/src/shared/benches/BooleansRandom.luau)
|Tool (FPS)|Median|P0|P80|P90|P95|P100|Loss (%)|
|---|---|---|---|---|---|---|---|
|Roblox remotes|15.00|16.00|15.00|15.00|15.00|15.00|0%|
|BlinkBlox|60.00|60.00|60.00|60.00|60.00|60.00|0%|
|Blink|60.00|60.00|60.00|60.00|60.00|60.00|0%|
|zap|46.00|47.00|45.00|45.00|45.00|44.00|0%|
|ByteNet|23.00|26.00|23.00|23.00|23.00|23.00|0%|
|Packet|28.00|30.00|28.00|27.00|27.00|27.00|0%|
|QuickNet|60.00|60.00|60.00|60.00|60.00|60.00|0%|
|Warp|55.00|56.00|54.00|54.00|54.00|53.00|0%|

|Tool (Fire ms)|Median|P0|P80|P90|P95|P100|Loss (%)|
|---|---|---|---|---|---|---|---|
|Roblox remotes|29.05|27.16|29.62|29.82|30.21|43.26|0%|
|BlinkBlox|4.81|4.60|5.04|5.21|5.29|5.55|0%|
|Blink|9.89|9.19|10.19|10.30|10.43|11.64|0%|
|zap|18.08|16.70|19.14|19.61|20.05|37.71|0%|
|ByteNet|21.40|20.32|22.00|22.29|22.65|23.05|0%|
|Packet|31.79|29.84|32.42|32.69|32.89|33.49|0%|
|QuickNet|7.12|6.91|7.33|7.47|7.60|7.99|0%|
|Warp|-|-|-|-|-|-|0%|

|Tool|Bytes/event|Drain (s)|Loss (%)|
|---|---|---|---|
|Roblox remotes|7324.32|5.7|0%|
|BlinkBlox|128.41|9.4|0%|
|Blink|193.89|9.8|0%|
|zap|193.83|9.4|0%|
|ByteNet|193.33|9.2|0%|
|Packet|194.16|10.0|0%|
|QuickNet|128.13|9.4|0%|
|Warp|128.60|9.1|0%|
## [EntitiesRandom](https://github.com/XopoIII/BlinkBlox/blob/main/benchmark/src/shared/benches/EntitiesRandom.luau)
|Tool (FPS)|Median|P0|P80|P90|P95|P100|Loss (%)|
|---|---|---|---|---|---|---|---|
|Roblox remotes|15.00|16.00|15.00|15.00|15.00|15.00|0%|
|BlinkBlox|60.00|61.00|60.00|60.00|60.00|60.00|0%|
|Blink|45.00|45.00|44.00|44.00|44.00|44.00|0%|
|zap|44.00|46.00|43.00|43.00|43.00|43.00|0%|
|ByteNet|34.00|37.00|33.00|33.00|33.00|33.00|0%|
|Packet|27.00|29.00|26.00|26.00|26.00|26.00|0%|
|QuickNet|57.00|58.00|57.00|56.00|56.00|54.00|0%|
|Warp|32.00|34.00|32.00|32.00|32.00|32.00|0%|

|Tool (Fire ms)|Median|P0|P80|P90|P95|P100|Loss (%)|
|---|---|---|---|---|---|---|---|
|Roblox remotes|74.49|71.88|75.82|77.06|77.22|99.97|0%|
|BlinkBlox|2.38|2.24|2.52|2.70|2.87|5.84|0%|
|Blink|3.16|2.61|3.63|3.95|4.39|5.62|0%|
|zap|7.77|6.94|8.15|8.40|9.49|16.04|0%|
|ByteNet|16.55|15.43|17.15|17.54|17.79|18.52|0%|
|Packet|19.93|18.60|20.47|20.78|21.10|22.20|0%|
|QuickNet|6.74|6.31|7.01|7.23|7.35|7.75|0%|
|Warp|-|-|-|-|-|-|0%|

|Tool|Bytes/event|Drain (s)|Loss (%)|
|---|---|---|---|
|Roblox remotes|37321.42|7.0|0%|
|BlinkBlox|603.69|11.1|0%|
|Blink|604.10|10.9|0%|
|zap|603.37|10.5|0%|
|ByteNet|605.19|11.0|0%|
|Packet|602.89|10.7|0%|
|QuickNet|604.16|10.5|0%|
|Warp|603.44|10.5|0%|