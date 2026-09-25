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

`lune run Runtime` in this directory times every tool above on Lune, where Studio cannot: interpreted, as most
players' clients run code, and decoding on the server, which Studio does not time. It loads zap's and Blink's
generated modules, ByteNet and Packet from the same files Studio runs (after `lune run build --download`) with just
enough of Roblox mocked around them, and times a frame's thousand fires, the flush into packets, and the server decoding those packets
and calling its listener. `Bytes/event` is the encoder's output; `zstd` is that output compressed as Roblox would.

The run below was made on 2026-09-25 on an Apple M1 with 16 GB of memory, Lune 0.10.5, with this repository's
compiler (0.36.2). Times are milliseconds per frame of 1000 events, medians
and 99th percentiles over 200 frames. `native` is what a Roblox server runs; `interpreted` is what most clients run.
Packet declares `--!native` nowhere, so both its rows are interpreted. `Tiny` is BlinkBlox's alone.

#### Booleans

|Tool|Code|Fire median|Fire p99|Flush median|Decode median|Decode p99|Bytes/event|zstd bytes/event|
|---|---|---|---|---|---|---|---|---|
|BlinkBlox|native|3.730|3.822|0.007|4.433|4.657|128.00|0.02|
|Blink|native|6.639|7.533|0.051|12.067|13.866|1003.00|0.10|
|zap|native|35.133|36.167|0.057|13.380|14.103|1003.00|0.10|
|ByteNet|native|53.247|63.351|0.056|122.215|135.946|1003.00|0.10|
|Packet|native|124.100|140.106|0.076|116.053|131.249|1003.00|0.10|
|BlinkBlox|interpreted|38.224|43.624|0.013|45.221|50.281|128.00|0.02|
|Blink|interpreted|68.844|78.352|0.057|83.002|94.046|1003.00|0.10|
|zap|interpreted|173.990|194.819|0.064|106.448|118.360|1003.00|0.10|
|ByteNet|interpreted|126.572|141.999|0.057|122.554|135.134|1003.00|0.10|
|Packet|interpreted|124.761|141.614|0.073|116.014|131.993|1003.00|0.10|

#### Entities

|Tool|Code|Fire median|Fire p99|Flush median|Decode median|Decode p99|Bytes/event|zstd bytes/event|
|---|---|---|---|---|---|---|---|---|
|BlinkBlox|native|3.190|3.621|0.024|12.646|15.369|603.00|0.67|
|Blink|native|3.184|3.657|0.033|73.317|85.431|603.00|0.67|
|zap|native|21.101|27.808|0.036|73.783|103.226|603.00|0.67|
|ByteNet|native|65.744|78.125|0.045|111.369|126.105|603.00|0.67|
|Packet|native|100.632|114.709|0.062|163.198|189.757|603.00|0.67|
|BlinkBlox|interpreted|33.462|38.419|0.030|54.643|63.705|603.00|0.67|
|Blink|interpreted|33.428|43.821|0.037|105.073|124.361|603.00|0.67|
|zap|interpreted|83.796|95.099|0.040|116.428|133.022|603.00|0.67|
|ByteNet|interpreted|109.145|123.715|0.045|109.455|132.305|603.00|0.67|
|Packet|interpreted|100.545|114.499|0.052|161.560|185.752|603.00|0.67|

#### BooleansRandom

|Tool|Code|Fire median|Fire p99|Flush median|Decode median|Decode p99|Bytes/event|zstd bytes/event|
|---|---|---|---|---|---|---|---|---|
|BlinkBlox|native|8.603|10.100|0.011|4.858|6.320|128.00|125.82|
|Blink|native|17.665|18.267|0.051|11.783|13.773|1003.00|135.63|
|zap|native|43.722|47.076|0.056|13.066|15.188|1003.00|135.63|
|ByteNet|native|56.588|64.394|0.054|129.687|144.415|1003.00|135.63|
|Packet|native|132.209|147.543|0.077|125.308|140.097|1003.00|135.63|
|BlinkBlox|interpreted|40.404|46.300|0.013|45.703|50.233|128.00|125.82|
|Blink|interpreted|73.655|82.209|0.058|90.165|99.858|1003.00|135.63|
|zap|interpreted|173.195|225.333|0.062|105.908|128.760|1003.00|135.63|
|ByteNet|interpreted|134.530|152.486|0.058|129.566|143.746|1003.00|135.63|
|Packet|interpreted|132.146|154.951|0.077|124.877|148.931|1003.00|135.63|

#### EntitiesRandom

|Tool|Code|Fire median|Fire p99|Flush median|Decode median|Decode p99|Bytes/event|zstd bytes/event|
|---|---|---|---|---|---|---|---|---|
|BlinkBlox|native|3.714|4.220|0.026|10.807|31.836|603.00|603.02|
|Blink|native|3.694|4.177|0.034|73.808|95.024|603.00|603.02|
|zap|native|21.079|23.874|0.033|73.772|90.191|603.00|603.02|
|ByteNet|native|66.553|76.176|0.043|109.404|129.746|603.00|603.02|
|Packet|native|100.905|114.676|0.060|163.567|191.919|603.00|603.02|
|BlinkBlox|interpreted|33.582|39.490|0.030|52.834|77.052|603.00|603.02|
|Blink|interpreted|33.608|38.094|0.037|105.068|125.047|603.00|603.02|
|zap|interpreted|84.126|99.354|0.038|117.083|136.647|603.00|603.02|
|ByteNet|interpreted|109.450|123.829|0.044|109.389|122.792|603.00|603.02|
|Packet|interpreted|100.892|114.602|0.060|162.335|208.556|603.00|603.02|

#### Tiny

|Tool|Code|Fire median|Fire p99|Flush median|Decode median|Decode p99|Bytes/event|zstd bytes/event|
|---|---|---|---|---|---|---|---|---|
|BlinkBlox|native|0.135|0.143|0.001|0.382|0.397|2.00|0.02|
|BlinkBlox|interpreted|0.345|0.362|0.001|0.636|0.659|2.00|0.02|

Source code can be found [here](https://github.com/XopoIII/BlinkBlox/blob/main/benchmark/src).  
Data used for benchmarks can be found [here](https://github.com/XopoIII/BlinkBlox/blob/main/benchmark/src/shared/benches).   
Definition files used for benchmarks can be found [here](https://github.com/XopoIII/BlinkBlox/blob/main/benchmark/definitions).  
 
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