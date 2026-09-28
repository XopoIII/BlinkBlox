# Benchmarks
## Methodology
Each tool fires an event 1000 times a frame for 10 seconds. Each bench is a pool of payloads, fired in turn:
`Booleans` and `Entities` send the same payload every time, and `BooleansRandom` and `EntitiesRandom` send a thousand
different ones a frame. Roblox compresses a remote's buffers with zstd, so identical events compress to almost nothing
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

`luneblox run Runtime` in this directory times every tool above on Lune, where Studio cannot: interpreted, as most
players' clients run code, and decoding on the server, which Studio does not time. It loads zap's and Blink's
generated modules, ByteNet and Packet from the same files Studio runs (after `luneblox run build --download`) with just
enough of Roblox mocked around them, and times a frame's thousand fires, the flush into packets, and the server decoding those packets
and calling its listener. `Bytes/event` is the encoder's output; `zstd` is that output compressed as Roblox would.

The runs below were made on 2026-09-27 on an Apple M1 with 16 GB of memory, Lune 0.10.5, with this repository's
compiler (0.40.0). Each figure is the median of three runs, and each run's figure is itself a median or 99th percentile over
200 frames, in milliseconds per frame. `native` is what a Roblox server runs; `interpreted` is what most clients run.
Packet declares `--!native` nowhere, so both its rows are interpreted. `Tiny` is BlinkBlox's alone, and runs after the
other tools in the same process, so its interpreted row reads higher here than when BlinkBlox runs alone.

The mock players and Instances are userdata, as they are in a game. Before 0.40.0 they were tables, and native code
sends a function whose parameter is annotated `Player` or `Instance` back to the interpreter when a table arrives, so
some native figures in earlier tables were interpreted ones.

#### Booleans

|Tool|Code|Fire median|Fire p99|Flush median|Decode median|Decode p99|Bytes/event|zstd bytes/event|
|---|---|---|---|---|---|---|---|---|
|BlinkBlox|native|3.558|4.021|0.008|4.166|4.708|128.00|0.02|
|Blink|native|6.620|10.189|0.050|11.887|18.335|1003.00|0.10|
|zap|native|34.745|39.460|0.055|13.346|15.384|1003.00|0.10|
|ByteNet|native|53.436|74.573|0.051|122.417|146.657|1003.00|0.10|
|Packet|native|124.123|148.786|0.070|116.672|135.316|1003.00|0.10|
|BlinkBlox|interpreted|37.696|42.720|0.013|45.127|49.471|128.00|0.02|
|Blink|interpreted|68.794|77.950|0.056|83.351|92.631|1003.00|0.10|
|zap|interpreted|173.968|196.971|0.068|106.564|119.743|1003.00|0.10|
|ByteNet|interpreted|126.579|201.131|0.058|122.590|158.512|1003.00|0.10|
|Packet|interpreted|124.271|167.957|0.071|116.165|200.369|1003.00|0.10|

#### Entities

|Tool|Code|Fire median|Fire p99|Flush median|Decode median|Decode p99|Bytes/event|zstd bytes/event|
|---|---|---|---|---|---|---|---|---|
|BlinkBlox|native|3.229|4.209|0.025|12.224|16.376|602.00|0.67|
|Blink|native|3.185|4.807|0.035|73.173|91.495|603.00|0.67|
|zap|native|20.878|32.865|0.036|74.100|104.082|603.00|0.67|
|ByteNet|native|65.691|124.152|0.041|110.577|151.041|603.00|0.67|
|Packet|native|100.602|141.483|0.049|162.540|254.092|603.00|0.67|
|BlinkBlox|interpreted|33.450|39.278|0.029|48.810|64.699|602.00|0.67|
|Blink|interpreted|33.455|53.714|0.037|105.289|160.694|603.00|0.67|
|zap|interpreted|83.890|131.810|0.039|116.861|187.896|603.00|0.67|
|ByteNet|interpreted|109.107|158.808|0.045|109.690|154.120|603.00|0.67|
|Packet|interpreted|100.554|148.502|0.049|162.515|237.073|603.00|0.67|

#### BooleansRandom

|Tool|Code|Fire median|Fire p99|Flush median|Decode median|Decode p99|Bytes/event|zstd bytes/event|
|---|---|---|---|---|---|---|---|---|
|BlinkBlox|native|8.481|9.559|0.013|4.497|6.309|128.00|125.82|
|Blink|native|17.576|20.070|0.053|11.757|15.180|1003.00|135.63|
|zap|native|43.955|60.062|0.053|13.127|19.927|1003.00|135.63|
|ByteNet|native|56.454|105.225|0.054|129.176|179.562|1003.00|135.63|
|Packet|native|132.177|137.990|0.068|125.168|138.998|1003.00|135.63|
|BlinkBlox|interpreted|40.426|52.608|0.015|45.283|51.050|128.00|125.82|
|Blink|interpreted|73.634|85.004|0.057|90.711|104.875|1003.00|135.63|
|zap|interpreted|171.818|244.678|0.060|106.388|170.900|1003.00|135.63|
|ByteNet|interpreted|134.535|208.345|0.056|129.693|211.734|1003.00|135.63|
|Packet|interpreted|132.342|237.232|0.071|125.336|173.295|1003.00|135.63|

#### EntitiesRandom

|Tool|Code|Fire median|Fire p99|Flush median|Decode median|Decode p99|Bytes/event|zstd bytes/event|
|---|---|---|---|---|---|---|---|---|
|BlinkBlox|native|3.710|8.043|0.026|11.384|32.439|602.00|602.02|
|Blink|native|3.670|6.469|0.033|73.739|119.722|603.00|603.02|
|zap|native|21.228|28.344|0.034|74.379|98.161|603.00|603.02|
|ByteNet|native|66.354|129.417|0.044|109.842|180.579|603.00|603.02|
|Packet|native|100.958|178.551|0.054|164.494|250.082|603.00|603.02|
|BlinkBlox|interpreted|33.566|43.057|0.030|46.799|72.016|602.00|602.02|
|Blink|interpreted|33.572|46.553|0.036|104.513|140.276|603.00|603.02|
|zap|interpreted|84.095|117.433|0.038|116.580|163.320|603.00|603.02|
|ByteNet|interpreted|109.575|151.287|0.046|110.153|188.604|603.00|603.02|
|Packet|interpreted|101.190|158.409|0.053|162.931|256.776|603.00|603.02|

#### Tiny

|Tool|Code|Fire median|Fire p99|Flush median|Decode median|Decode p99|Bytes/event|zstd bytes/event|
|---|---|---|---|---|---|---|---|---|
|BlinkBlox|native|0.088|0.120|0.001|0.245|0.333|2.00|0.02|
|BlinkBlox|interpreted|0.409|0.747|0.002|0.699|1.295|2.00|0.02|

## Sending to a crowd, unreliable events and Instances

`luneblox run Rivals` runs the paths the benchmark above never does, on every tool, all loaded the same way so each pays for
the same mocks, each flushing on its own Heartbeat. The events are in `definitions/Scenarios.blink`, declared for each tool
in `definitions/Scenarios.zap`, `definitions/Scenarios.upstream.blink` and `runtime/rivals/modes`. Times are
milliseconds a frame; `Remote calls/frame` and `Bytes/frame` are summed over every player a frame reached.

- `Broadcast`: the server fires 100 reliable structs a frame to 50 players with `FireAll`.
- `UnreliableInput`: a client fires 8 small unreliable inputs a frame.
- `Instances`: a client fires 100 reliable events a frame, each carrying a part.
- `WorldState`: the server sends 16 units a frame to 50 players, unreliable, to everyone at once.
- `SelfState`: the server sends each of 50 players their own unit a frame, unreliable.

Packet has no unreliable channel, so it runs only the reliable scenarios. ByteNet's release prints its instance list
on every Instance it writes; the harness sends `print` nowhere, so the terminal is not what is timed.

#### Broadcast

|Tool|Code|Fire median|Flush median|Decode median|Remote calls/frame|Bytes/frame|
|---|---|---|---|---|---|---|
|BlinkBlox|native|0.037|0.002|0.024|1.0|85000.0|
|Blink|native|2.097|0.028|0.081|50.0|90000.0|
|zap|native|2.455|0.027|0.077|50.0|85000.0|
|ByteNet|native|0.099|0.005|0.268|1.0|90000.0|
|Packet|native|0.209|0.004|0.452|1.0|90000.0|
|BlinkBlox|interpreted|0.099|0.002|0.092|1.0|85000.0|
|Blink|interpreted|4.402|0.046|0.145|50.0|90000.0|
|zap|interpreted|5.621|0.069|0.153|50.0|85000.0|
|ByteNet|interpreted|0.210|0.011|0.290|1.0|90000.0|
|Packet|interpreted|0.212|0.004|0.454|1.0|90000.0|

#### UnreliableInput

|Tool|Code|Fire median|Flush median|Decode median|Remote calls/frame|Bytes/frame|
|---|---|---|---|---|---|---|
|BlinkBlox|native|0.006|0.000|0.010|8.0|40.0|
|Blink|native|0.009|0.000|0.009|8.0|48.0|
|zap|native|0.006|0.000|0.006|8.0|32.0|
|ByteNet|native|0.006|0.001|0.019|1.0|48.0|
|BlinkBlox|interpreted|0.013|0.000|0.022|8.0|40.0|
|Blink|interpreted|0.011|0.000|0.013|8.0|48.0|
|zap|interpreted|0.013|0.000|0.009|8.0|32.0|
|ByteNet|interpreted|0.012|0.001|0.022|1.0|48.0|

#### Instances

|Tool|Code|Fire median|Flush median|Decode median|Remote calls/frame|Bytes/frame|
|---|---|---|---|---|---|---|
|BlinkBlox|native|0.012|0.001|0.037|1.0|200.0|
|Blink|native|0.011|0.001|0.014|1.0|200.0|
|zap|native|0.023|0.002|0.042|1.0|200.0|
|ByteNet|native|0.064|0.002|0.219|1.0|300.0|
|Packet|native|0.094|0.003|0.333|1.0|200.0|
|BlinkBlox|interpreted|0.042|0.001|0.073|1.0|200.0|
|Blink|interpreted|0.031|0.003|0.048|1.0|200.0|
|zap|interpreted|0.039|0.001|0.061|1.0|200.0|
|ByteNet|interpreted|0.130|0.002|0.248|1.0|300.0|
|Packet|interpreted|0.095|0.003|0.335|1.0|200.0|

#### WorldState

|Tool|Code|Fire median|Flush median|Decode median|Remote calls/frame|Bytes/frame|
|---|---|---|---|---|---|---|
|BlinkBlox|native|0.003|0.001|0.002|1.0|12900.0|
|Blink|native|0.008|0.000|0.016|1.0|13700.0|
|zap|native|0.013|0.000|0.017|1.0|12850.0|
|ByteNet|native|0.017|0.004|0.023|1.0|13750.0|
|BlinkBlox|interpreted|0.009|0.001|0.010|1.0|12900.0|
|Blink|interpreted|0.016|0.000|0.024|1.0|13700.0|
|zap|interpreted|0.025|0.000|0.024|1.0|12850.0|
|ByteNet|interpreted|0.023|0.010|0.023|1.0|13750.0|

#### SelfState

|Tool|Code|Fire median|Flush median|Decode median|Remote calls/frame|Bytes/frame|
|---|---|---|---|---|---|---|
|BlinkBlox|native|0.045|0.001|0.001|50.0|850.0|
|Blink|native|0.043|0.000|0.001|50.0|900.0|
|zap|native|0.039|0.000|0.001|50.0|800.0|
|ByteNet|native|0.065|0.026|0.004|50.0|900.0|
|BlinkBlox|interpreted|0.075|0.001|0.002|50.0|850.0|
|Blink|interpreted|0.058|0.000|0.002|50.0|900.0|
|zap|interpreted|0.110|0.000|0.002|50.0|800.0|
|ByteNet|interpreted|0.104|0.040|0.004|50.0|900.0|

BlinkBlox with `option BatchUnreliable`, which gathers a frame's unreliable events into as few packets as fit:

#### Broadcast

|Tool|Code|Fire median|Flush median|Decode median|Remote calls/frame|Bytes/frame|
|---|---|---|---|---|---|---|
|BlinkBlox|native|0.037|0.002|0.025|1.0|85000.0|
|BlinkBlox|interpreted|0.094|0.002|0.086|1.0|85000.0|

#### UnreliableInput

|Tool|Code|Fire median|Flush median|Decode median|Remote calls/frame|Bytes/frame|
|---|---|---|---|---|---|---|
|BlinkBlox|native|0.004|0.001|0.004|1.0|40.0|
|BlinkBlox|interpreted|0.011|0.001|0.009|1.0|40.0|

#### Instances

|Tool|Code|Fire median|Flush median|Decode median|Remote calls/frame|Bytes/frame|
|---|---|---|---|---|---|---|
|BlinkBlox|native|0.012|0.001|0.034|1.0|200.0|
|BlinkBlox|interpreted|0.042|0.001|0.071|1.0|200.0|

#### WorldState

|Tool|Code|Fire median|Flush median|Decode median|Remote calls/frame|Bytes/frame|
|---|---|---|---|---|---|---|
|BlinkBlox|native|0.005|0.001|0.005|1.0|12900.0|
|BlinkBlox|interpreted|0.010|0.002|0.012|1.0|12900.0|

#### SelfState

|Tool|Code|Fire median|Flush median|Decode median|Remote calls/frame|Bytes/frame|
|---|---|---|---|---|---|---|
|BlinkBlox|native|0.021|0.020|0.001|50.0|850.0|
|BlinkBlox|interpreted|0.060|0.031|0.002|50.0|850.0|

## Streams

`luneblox run Scenarios` runs the same paths for BlinkBlox alone, with streams in place of the unreliable events: a stream
of 16 units to 50 players (`StreamWorld`), and one held per player (`StreamPerPlayer`). The streams to everyone due in
a frame share one `FireAllClients`.

|Scenario|Code|Fire median|Flush median|Decode median|Remote calls/frame|Bytes/frame|
|---|---|---|---|---|---|---|
|Broadcast|native|0.036|0.002|0.025|1.0|85000.0|
|UnreliableInput|native|0.006|0.000|0.007|8.0|40.0|
|Instances|native|0.011|0.001|0.027|1.0|200.0|
|StreamWorld|native|0.001|0.016|0.002|1.0|13050.0|
|StreamPerPlayer|native|0.008|0.084|0.001|50.0|1000.0|
|Broadcast|interpreted|0.094|0.002|0.088|1.0|85000.0|
|UnreliableInput|interpreted|0.010|0.000|0.016|8.0|40.0|
|Instances|interpreted|0.042|0.001|0.065|1.0|200.0|
|StreamWorld|interpreted|0.001|0.034|0.010|1.0|13050.0|
|StreamPerPlayer|interpreted|0.019|0.197|0.002|50.0|1000.0|

With `--batch`:

|Scenario|Code|Fire median|Flush median|Decode median|Remote calls/frame|Bytes/frame|
|---|---|---|---|---|---|---|
|Broadcast|native|0.035|0.002|0.025|1.0|85000.0|
|UnreliableInput|native|0.004|0.001|0.003|1.0|40.0|
|Instances|native|0.011|0.001|0.027|1.0|200.0|
|StreamWorld|native|0.001|0.016|0.002|1.0|13050.0|
|StreamPerPlayer|native|0.008|0.090|0.001|50.0|1000.0|
|Broadcast|interpreted|0.094|0.002|0.088|1.0|85000.0|
|UnreliableInput|interpreted|0.010|0.001|0.008|1.0|40.0|
|Instances|interpreted|0.042|0.001|0.066|1.0|200.0|
|StreamWorld|interpreted|0.001|0.034|0.010|1.0|13050.0|
|StreamPerPlayer|interpreted|0.019|0.219|0.002|50.0|1000.0|

## Many events

`luneblox run Scenarios -- ManyEvents` sends 100 reliable events a frame spread over the 128 `Many` declarations of
`definitions/Scenarios.blink`, and times the client decoding them. Run 2026-09-28, interpreted, medians of three runs
taken alternately with both versions' modules loaded from files:

|Scenario|0.40.0 decode|0.41.0 decode|
|---|---|---|
|ManyEvents|0.086|**0.053**|
|Broadcast, index 0 of the same channel|**0.090**|0.093|

Both native rows equal the interpreted ones on Lune 0.10.5: its Luau leaves a whole module interpreted once one function
is too large, and a module's top-level function grows with every declaration -- about 70 events on the server, 85 on
the client. Current Luau leaves only that function interpreted; see the docs' Benchmarks page.

## Results

`P[NUMBER]` = [NUMBER] Percentile  
*The tables below were automatically generated by this [script](https://github.com/XopoIII/BlinkBlox/blob/main/benchmark/generate.luau).*
## Last Updated 2026-09-25 04:25:35 UTC
## Tool Versions
BlinkBlox: v0.36.2, compiled from this repository  
Blink: v0.18.9  
zap: v0.6.29  
ByteNet: v0.4.3  
Packet: 1.7.0  
## Computer Specs
Processor: `Apple M1`  
Memory: `16GB`  
## [Booleans](https://github.com/XopoIII/BlinkBlox/blob/main/benchmark/src/shared/benches/Booleans.luau)
|Tool (FPS)|Median|P0|P80|P90|P95|P100|Loss (%)|
|---|---|---|---|---|---|---|---|
|Roblox remotes|16.00|17.00|15.00|15.00|15.00|15.00|0%|
|BlinkBlox|60.00|60.00|60.00|60.00|60.00|60.00|0%|
|Blink|53.00|60.00|49.00|48.00|48.00|46.00|0%|
|zap|35.00|38.00|31.00|31.00|31.00|26.00|0%|
|ByteNet|17.00|18.00|17.00|16.00|16.00|15.00|0%|
|Packet|15.00|16.00|15.00|15.00|15.00|15.00|0%|

|Tool (Fire ms)|Median|P0|P80|P90|P95|P100|Loss (%)|
|---|---|---|---|---|---|---|---|
|Roblox remotes|29.22|25.91|32.53|39.12|42.18|62.07|0%|
|BlinkBlox|4.22|4.21|4.25|4.77|5.49|11.78|0%|
|Blink|8.42|6.77|10.34|11.54|13.09|17.80|0%|
|zap|25.89|24.95|29.23|33.90|39.18|51.25|0%|
|ByteNet|41.28|40.94|46.58|46.84|50.75|75.61|0%|
|Packet|67.34|67.11|76.18|81.43|89.54|117.47|0%|

|Tool|Bytes/event|Drain (s)|Loss (%)|
|---|---|---|---|
|Roblox remotes|3815.29|5.7|0%|
|BlinkBlox|0.04|2.4|0%|
|Blink|0.13|3.3|0%|
|zap|0.13|3.0|0%|
|ByteNet|0.12|3.3|0%|
|Packet|0.12|3.4|0%|
## [Entities](https://github.com/XopoIII/BlinkBlox/blob/main/benchmark/src/shared/benches/Entities.luau)
|Tool (FPS)|Median|P0|P80|P90|P95|P100|Loss (%)|
|---|---|---|---|---|---|---|---|
|Roblox remotes|16.00|16.00|15.00|15.00|15.00|15.00|0%|
|BlinkBlox|56.00|60.00|55.00|50.00|50.00|48.00|0%|
|Blink|22.00|23.00|21.00|21.00|21.00|19.00|0%|
|zap|22.00|23.00|22.00|20.00|20.00|20.00|0%|
|ByteNet|18.00|19.00|16.00|16.00|16.00|15.00|0%|
|Packet|15.00|16.00|15.00|15.00|15.00|15.00|0%|

|Tool (Fire ms)|Median|P0|P80|P90|P95|P100|Loss (%)|
|---|---|---|---|---|---|---|---|
|Roblox remotes|110.11|108.57|111.13|117.82|128.11|171.32|0%|
|BlinkBlox|4.03|4.02|4.06|4.56|5.25|10.74|0%|
|Blink|4.56|4.07|4.65|4.76|4.85|8.64|0%|
|zap|20.48|19.96|20.73|22.75|26.31|38.57|0%|
|ByteNet|37.79|37.55|42.73|49.09|57.49|80.53|0%|
|Packet|50.25|50.02|56.91|67.60|79.11|109.32|0%|

|Tool|Bytes/event|Drain (s)|Loss (%)|
|---|---|---|---|
|Roblox remotes|41919.47|7.6|0%|
|BlinkBlox|0.69|4.9|0%|
|Blink|0.69|5.0|0%|
|zap|0.69|4.8|0%|
|ByteNet|0.69|4.6|0%|
|Packet|0.69|4.4|0%|
## [BooleansRandom](https://github.com/XopoIII/BlinkBlox/blob/main/benchmark/src/shared/benches/BooleansRandom.luau)
|Tool (FPS)|Median|P0|P80|P90|P95|P100|Loss (%)|
|---|---|---|---|---|---|---|---|
|Roblox remotes|16.00|16.00|15.00|15.00|15.00|15.00|0%|
|BlinkBlox|60.00|61.00|59.00|59.00|59.00|59.00|0%|
|Blink|36.00|40.00|33.00|32.00|32.00|31.00|0%|
|zap|26.00|27.00|25.00|25.00|25.00|22.00|0%|
|ByteNet|15.00|17.00|15.00|15.00|15.00|15.00|0%|
|Packet|15.00|16.00|15.00|15.00|15.00|15.00|0%|

|Tool (Fire ms)|Median|P0|P80|P90|P95|P100|Loss (%)|
|---|---|---|---|---|---|---|---|
|Roblox remotes|29.40|25.90|34.03|39.38|44.43|60.96|0%|
|BlinkBlox|8.73|8.63|8.92|10.10|11.70|16.90|0%|
|Blink|20.52|17.82|24.43|28.35|30.24|44.16|0%|
|zap|34.42|33.73|34.61|34.77|36.99|51.85|0%|
|ByteNet|44.71|44.00|44.96|46.44|50.42|68.11|0%|
|Packet|77.52|77.18|87.49|90.63|95.45|166.63|0%|

|Tool|Bytes/event|Drain (s)|Loss (%)|
|---|---|---|---|
|Roblox remotes|3849.91|5.5|0%|
|BlinkBlox|128.53|9.4|0%|
|Blink|193.10|9.1|0%|
|zap|193.19|9.8|0%|
|ByteNet|193.37|9.4|0%|
|Packet|192.13|9.6|0%|
## [EntitiesRandom](https://github.com/XopoIII/BlinkBlox/blob/main/benchmark/src/shared/benches/EntitiesRandom.luau)
|Tool (FPS)|Median|P0|P80|P90|P95|P100|Loss (%)|
|---|---|---|---|---|---|---|---|
|Roblox remotes|15.00|15.00|15.00|15.00|15.00|15.00|0%|
|BlinkBlox|51.00|60.00|43.00|40.00|40.00|39.00|0%|
|Blink|22.00|24.00|21.00|21.00|21.00|19.00|0%|
|zap|22.00|24.00|22.00|22.00|22.00|20.00|0%|
|ByteNet|17.00|18.00|17.00|16.00|16.00|15.00|0%|
|Packet|15.00|17.00|15.00|15.00|15.00|15.00|0%|

|Tool (Fire ms)|Median|P0|P80|P90|P95|P100|Loss (%)|
|---|---|---|---|---|---|---|---|
|Roblox remotes|115.57|108.85|129.64|137.93|146.34|247.82|0%|
|BlinkBlox|5.07|4.46|5.78|6.70|8.01|15.93|0%|
|Blink|5.00|4.49|5.13|5.23|5.55|9.45|0%|
|zap|20.35|19.85|20.60|23.01|23.62|32.57|0%|
|ByteNet|38.31|37.84|45.09|53.32|59.93|90.11|0%|
|Packet|53.06|50.20|57.22|72.46|80.23|118.69|0%|

|Tool|Bytes/event|Drain (s)|Loss (%)|
|---|---|---|---|
|Roblox remotes|40205.11|7.2|0%|
|BlinkBlox|603.90|10.5|0%|
|Blink|604.18|10.5|0%|
|zap|602.58|10.7|0%|
|ByteNet|603.79|10.6|0%|
|Packet|606.75|10.0|0%|