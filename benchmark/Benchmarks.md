# Benchmarks

**No tool ran with a limit that refuses traffic.** The bench fires far faster than an honest client,
so every cap is lifted: BlinkBlox's inbound limits (in its definition files), Packet's 8000-byte cap,
QuickNet's rate limit and packet caps, Warp's 8000-byte cap (all three in `download.luau`), and
Satset's token bucket (in its modes). The checks behind those limits still run and are timed; only
the refusals are gone. `Runtime` and `Rivals` stop if any event fired goes unheard, the Studio tables
report a tool's loss, and both scripts print this line above their tables.

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

The tables measure QuickNet v0.3.5-beta and Warp 1.1.0-pre7. `download.luau` now fetches QuickNet v0.4.0-beta
(`edba9a2`) and Warp 1.1.0-pre8, and lifts QuickNet 0.4.0's new limits, a 50,000-byte packet and a hundred events in
one, as it lifts Packet's. One run of each pair on 2026-10-12, side by side on a 4-vCPU Linux container with
LuneBlox 0.10.17 and no core pinned, so a few percent is noise: QuickNet 0.4.0 fires Entities in 13.7 ms native and
31.1 interpreted, from 18.0 and 40.1, and decodes it in 28.2 and 51.4, from 32.1 and 61.0, with Booleans unchanged;
BlinkBlox fired the same Entities in 4.7 and decoded them in 12.9 there. Warp 1.1.0-pre8 times as pre7 did. It frames
unreliable packets as well now, each with a 2-byte header -- `SelfState` costs it 1,050 bytes a frame to 50 players,
from 950 -- and sends a whole packet once a second, so its `zstd` column on the repeated payloads rises with how many
frames a second it runs: Entities came to 0.07 bytes an event native and 0.20 interpreted, from 0.03.

### Satset

Satset v0.5.0 joined after the tables below were run. One run of `Runtime` and `Rivals` (and `Rivals -- --batch`)
on 2026-10-25, on an Apple M1 MacBook Air with LuneBlox 0.10.18, no core pinned, load average about 2.5, BlinkBlox
1.3.1 from this repository. Its token bucket is lifted in its modes, `Satset.start` taking `math.huge` for both its
size and its refill; its batching is as it ships. It runs `Tiny` too: the bench exists for framing, and framing is
where Satset differs.

|Bench|Tool|Code|Fire median|Fire p99|Flush median|Decode median|Decode p99|Bytes/event|zstd bytes/event|
|---|---|---|---|---|---|---|---|---|---|
|Booleans|BlinkBlox|native|3.023|3.158|0.005|2.864|3.597|128.00|0.02|
||Satset|native|10.341|10.661|0.281|7.943|9.194|127.01|0.03|
||BlinkBlox|interpreted|15.891|16.347|0.005|9.225|9.955|128.00|0.02|
||Satset|interpreted|38.853|39.905|1.733|37.999|39.877|127.01|0.03|
|Entities|BlinkBlox|native|2.452|2.509|0.012|4.546|11.764|602.00|0.67|
||Satset|native|38.431|39.247|0.705|43.040|51.294|602.01|0.68|
||BlinkBlox|interpreted|12.411|12.715|0.013|12.215|20.032|602.00|0.67|
||Satset|interpreted|42.257|43.345|4.571|64.395|73.178|602.01|0.68|
|BooleansRandom|BlinkBlox|native|6.006|6.061|0.006|2.819|4.032|128.00|125.81|
||Satset|native|13.984|14.459|0.431|7.931|10.272|127.01|127.02|
||BlinkBlox|interpreted|17.725|17.851|0.006|9.203|10.570|128.00|125.81|
||Satset|interpreted|33.678|34.473|3.637|47.384|49.622|127.01|127.02|
|EntitiesRandom|BlinkBlox|native|3.036|3.175|0.014|4.533|19.990|602.00|602.02|
||Satset|native|38.771|39.881|0.763|42.825|58.638|602.01|602.03|
||BlinkBlox|interpreted|12.590|12.995|0.015|12.471|27.731|602.00|602.02|
||Satset|interpreted|42.723|44.725|4.658|64.760|80.766|602.01|602.03|
|Tiny|BlinkBlox|native|0.049|0.053|0.000|0.058|0.070|2.00|0.02|
||Satset|native|0.364|0.390|0.113|0.531|0.569|1.01|0.03|
||BlinkBlox|interpreted|0.124|0.137|0.000|0.175|0.186|2.00|0.02|
||Satset|interpreted|0.507|0.526|0.287|0.693|0.718|1.01|0.03|

|Scenario|Tool|Code|Fire median|Flush median|Decode median|Remote calls/frame|Bytes/frame|
|---|---|---|---|---|---|---|---|
|Broadcast|BlinkBlox|native|0.021|0.001|0.031|1.0|85000.0|
||Satset|native|0.081|0.009|0.084|1.0|85250.0|
|UnreliableInput|BlinkBlox|native|0.005|0.000|0.004|8.0|40.0|
||BlinkBlox `--batch`|native|0.004|0.001|0.001|1.0|40.0|
||Satset|native|0.005|0.001|0.006|1.0|52.0|
|WorldState|BlinkBlox|native|0.002|0.000|0.003|1.0|12900.0|
||Satset|native|0.018|0.026|0.009|50.0|14050.0|
|SelfState|BlinkBlox|native|0.014|0.000|0.001|50.0|850.0|
||Satset|native|0.042|0.025|0.001|50.0|1100.0|

Satset encodes each field through a function its schema holds, so it is slower to fire and decode everywhere, and
its flush scans the frame's batch a second time to merge runs: consecutive events of one id go under one 3-byte
header (5 past 255 events), with no index or length each. That is the one place it is smaller, by the byte of
index BlinkBlox writes before every event: 1.01 bytes a `Tiny` to 2.00. zstd takes the repeated index bytes back on
these pools, but Roblox's compression did not in Studio (Results below), where `BooleansRandom` cost Satset 127.03
bytes an event to BlinkBlox's 128.14. It batches unreliable events by default, one call for `UnreliableInput`
where BlinkBlox makes eight unless built with `BatchUnreliable`; an unreliable `FireAll` it copies to each player,
50 calls for `WorldState`. It has no Instance type and sits out `Instances`.

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

The Studio run below was made on 2026-10-25 on an Apple M1 MacBook Air with BlinkBlox 1.3.1's
modules, one run, no core pinned, with nothing else running but the desktop. Since 1.2.1 only the
server module asks to be compiled natively, so BlinkBlox's client is interpreted in Studio, as
Packet's is, while Blink's and zap's modules, QuickNet's functions (each marked `@native`) and the
busiest files of ByteNet, Warp and Satset are native: its `Fire ms` here is an interpreted figure
against native ones. Interpreted against interpreted, as most players' clients
run, `luneblox run Runtime` has it the fastest to fire both `Booleans` benches and tied with Blink on
both `Entities` ones (Warp aside, which encodes at its flush).
`Bytes/event` moves by about a byte an event from run to run, as BlinkBlox and QuickNet traded places
on `EntitiesRandom` between this run and the last; only a gap wider than that is a difference.

Warp's `Fire ms` is left out: its Fire only queues the value, and
it encodes the queue later in the frame on a signal of its own that the bench cannot time, so the
figure read 0.1 ms while its frame rate fell to 32. `luneblox run Runtime` times its fire and flush
together.

`P[NUMBER]` = [NUMBER] Percentile  
*The tables below were automatically generated by this [script](https://github.com/XopoIII/BlinkBlox/blob/main/benchmark/generate.luau).*
## Last Updated 2026-10-25 02:11:41 UTC
## Tool Versions
BlinkBlox: v1.3.1, compiled from this repository  
Blink: v0.18.9  
zap: v0.6.29  
ByteNet: v0.4.3  
Packet: 1.7.0  
QuickNet: v0.4.0-beta (edba9a2)  
Warp: 1.1.0-pre8  
Satset: v0.5.0  
## Computer Specs
Processor: `Apple M1`  
Memory: `16GB`  
## [Booleans](https://github.com/XopoIII/BlinkBlox/blob/main/benchmark/src/shared/benches/Booleans.luau)
|Tool (FPS)|Median|P0|P80|P90|P95|P100|Loss (%)|
|---|---|---|---|---|---|---|---|
|Roblox remotes|25.00|25.00|24.00|24.00|24.00|24.00|0%|
|BlinkBlox|60.00|60.00|60.00|60.00|60.00|60.00|0%|
|Blink|60.00|60.00|60.00|60.00|60.00|60.00|0%|
|zap|55.00|56.00|55.00|54.00|54.00|53.00|0%|
|ByteNet|26.00|27.00|26.00|26.00|26.00|26.00|0%|
|Packet|23.00|24.00|22.00|22.00|22.00|22.00|0%|
|QuickNet|60.00|61.00|60.00|59.00|59.00|59.00|0%|
|Warp|60.00|60.00|60.00|60.00|60.00|60.00|0%|
|Satset|60.00|61.00|60.00|59.00|59.00|58.00|0%|

|Tool (Fire ms)|Median|P0|P80|P90|P95|P100|Loss (%)|
|---|---|---|---|---|---|---|---|
|Roblox remotes|18.34|17.84|18.74|19.15|19.52|47.06|0%|
|BlinkBlox|8.91|7.96|9.09|9.36|9.75|19.57|0%|
|Blink|5.70|4.62|5.94|6.40|6.57|20.29|0%|
|zap|16.97|16.55|17.10|17.18|17.28|50.93|0%|
|ByteNet|26.66|26.33|26.81|26.92|27.20|52.73|0%|
|Packet|42.69|42.46|42.83|42.98|43.65|46.57|0%|
|QuickNet|4.60|3.94|4.66|4.74|4.80|9.58|0%|
|Warp|-|-|-|-|-|-|0%|
|Satset|11.25|10.62|11.40|11.49|11.55|30.56|0%|

|Tool|Bytes/event|Drain (s)|Loss (%)|
|---|---|---|---|
|Roblox remotes|4153.65|5.6|0%|
|BlinkBlox|0.04|2.2|0%|
|Blink|0.13|3.6|0%|
|zap|0.13|3.2|0%|
|ByteNet|0.13|3.2|0%|
|Packet|0.12|3.1|0%|
|QuickNet|0.04|2.4|0%|
|Warp|0.04|2.5|0%|
|Satset|0.15|2.0|0%|
## [Entities](https://github.com/XopoIII/BlinkBlox/blob/main/benchmark/src/shared/benches/Entities.luau)
|Tool (FPS)|Median|P0|P80|P90|P95|P100|Loss (%)|
|---|---|---|---|---|---|---|---|
|Roblox remotes|15.00|16.00|15.00|15.00|15.00|15.00|0%|
|BlinkBlox|60.00|60.00|60.00|60.00|60.00|60.00|0%|
|Blink|33.00|34.00|33.00|33.00|33.00|33.00|0%|
|zap|34.00|34.00|33.00|33.00|33.00|32.00|0%|
|ByteNet|27.00|28.00|26.00|26.00|26.00|26.00|0%|
|Packet|22.00|23.00|22.00|22.00|22.00|21.00|0%|
|QuickNet|46.00|47.00|46.00|46.00|46.00|46.00|0%|
|Warp|22.00|23.00|22.00|22.00|22.00|21.00|0%|
|Satset|20.00|22.00|19.00|19.00|19.00|18.00|0%|

|Tool (Fire ms)|Median|P0|P80|P90|P95|P100|Loss (%)|
|---|---|---|---|---|---|---|---|
|Roblox remotes|69.47|67.22|70.70|71.92|73.91|102.90|0%|
|BlinkBlox|7.12|6.63|7.49|7.64|7.80|12.29|0%|
|Blink|2.23|1.85|2.30|2.36|2.55|5.45|0%|
|zap|13.55|12.71|13.73|13.90|14.03|30.59|0%|
|ByteNet|23.86|23.53|24.30|24.44|24.49|29.01|0%|
|Packet|31.51|31.25|32.22|32.50|33.05|58.85|0%|
|QuickNet|8.89|8.74|8.99|9.07|9.11|21.67|0%|
|Warp|-|-|-|-|-|-|0%|
|Satset|34.64|34.05|35.34|35.79|37.38|70.48|0%|

|Tool|Bytes/event|Drain (s)|Loss (%)|
|---|---|---|---|
|Roblox remotes|30265.12|7.3|0%|
|BlinkBlox|0.69|5.1|0%|
|Blink|0.69|4.9|0%|
|zap|0.69|4.9|0%|
|ByteNet|0.69|4.9|0%|
|Packet|0.69|4.6|0%|
|QuickNet|0.69|4.9|0%|
|Warp|0.08|2.9|0%|
|Satset|2.97|2.7|0%|
## [BooleansRandom](https://github.com/XopoIII/BlinkBlox/blob/main/benchmark/src/shared/benches/BooleansRandom.luau)
|Tool (FPS)|Median|P0|P80|P90|P95|P100|Loss (%)|
|---|---|---|---|---|---|---|---|
|Roblox remotes|22.00|23.00|22.00|22.00|22.00|22.00|0%|
|BlinkBlox|60.00|60.00|60.00|60.00|60.00|60.00|0%|
|Blink|60.00|60.00|59.00|59.00|59.00|58.00|0%|
|zap|38.00|39.00|38.00|38.00|38.00|38.00|0%|
|ByteNet|21.00|22.00|21.00|21.00|21.00|21.00|0%|
|Packet|19.00|20.00|19.00|19.00|19.00|18.00|0%|
|QuickNet|60.00|60.00|60.00|60.00|60.00|60.00|0%|
|Warp|56.00|56.00|55.00|55.00|55.00|55.00|0%|
|Satset|60.00|60.00|60.00|60.00|60.00|58.00|0%|

|Tool (Fire ms)|Median|P0|P80|P90|P95|P100|Loss (%)|
|---|---|---|---|---|---|---|---|
|Roblox remotes|18.27|17.51|18.62|19.06|19.65|46.46|0%|
|BlinkBlox|12.63|12.29|12.72|12.76|12.79|27.50|0%|
|Blink|12.68|11.56|13.58|14.06|14.46|26.40|0%|
|zap|22.55|22.08|22.70|22.79|22.93|47.73|0%|
|ByteNet|28.68|28.22|28.84|28.99|29.39|57.43|0%|
|Packet|49.35|49.09|49.50|49.69|50.40|83.37|0%|
|QuickNet|10.81|9.92|10.94|10.99|11.03|20.53|0%|
|Warp|-|-|-|-|-|-|0%|
|Satset|14.38|14.06|14.49|14.60|14.76|33.25|0%|

|Tool|Bytes/event|Drain (s)|Loss (%)|
|---|---|---|---|
|Roblox remotes|3807.10|5.4|0%|
|BlinkBlox|128.14|9.5|0%|
|Blink|193.87|9.9|0%|
|zap|193.49|10.0|0%|
|ByteNet|194.04|9.7|0%|
|Packet|193.28|9.2|0%|
|QuickNet|127.96|9.2|0%|
|Warp|127.97|9.4|0%|
|Satset|127.03|9.3|0%|
## [EntitiesRandom](https://github.com/XopoIII/BlinkBlox/blob/main/benchmark/src/shared/benches/EntitiesRandom.luau)
|Tool (FPS)|Median|P0|P80|P90|P95|P100|Loss (%)|
|---|---|---|---|---|---|---|---|
|Roblox remotes|15.00|16.00|15.00|15.00|15.00|15.00|0%|
|BlinkBlox|60.00|60.00|60.00|60.00|60.00|60.00|0%|
|Blink|32.00|33.00|32.00|32.00|32.00|32.00|0%|
|zap|34.00|35.00|33.00|33.00|33.00|33.00|0%|
|ByteNet|27.00|27.00|26.00|26.00|26.00|26.00|0%|
|Packet|23.00|23.00|22.00|22.00|22.00|22.00|0%|
|QuickNet|45.00|45.00|44.00|44.00|44.00|44.00|0%|
|Warp|21.00|22.00|21.00|20.00|20.00|20.00|0%|
|Satset|20.00|21.00|20.00|20.00|20.00|20.00|0%|

|Tool (Fire ms)|Median|P0|P80|P90|P95|P100|Loss (%)|
|---|---|---|---|---|---|---|---|
|Roblox remotes|69.93|68.14|71.07|71.49|72.23|107.08|0%|
|BlinkBlox|7.43|6.89|7.64|7.73|7.81|17.99|0%|
|Blink|2.93|2.51|3.17|3.31|3.38|5.19|0%|
|zap|13.47|13.07|13.63|13.72|13.83|32.04|0%|
|ByteNet|24.48|24.05|24.66|24.82|25.02|52.21|0%|
|Packet|31.69|31.39|32.07|32.31|32.47|61.86|0%|
|QuickNet|9.39|9.08|9.55|9.63|9.71|21.26|0%|
|Warp|-|-|-|-|-|-|0%|
|Satset|34.44|34.17|34.64|35.18|35.26|65.99|0%|

|Tool|Bytes/event|Drain (s)|Loss (%)|
|---|---|---|---|
|Roblox remotes|27765.93|6.9|0%|
|BlinkBlox|602.95|10.4|0%|
|Blink|601.67|10.7|0%|
|zap|603.12|10.3|0%|
|ByteNet|603.10|10.8|0%|
|Packet|602.00|10.3|0%|
|QuickNet|601.39|10.5|0%|
|Warp|600.80|11.0|0%|
|Satset|602.60|11.4|0%|